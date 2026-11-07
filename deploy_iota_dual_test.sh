#!/usr/bin/env bash
# IOTA dual-protocol test VPS: Hysteria2/UDP + VLESS-REALITY/TCP.
# No Docker, web panel, or third-party monitor. Verified HTTPS subscription.
# Fresh Ubuntu 22.04/24.04; amd64/arm64. English terminal output.
set -Eeuo pipefail
umask 077

VERSION="1.2.0"
HY_VERSION="2.13.0"
XR_VERSION="26.10.31"
CERTBOT_VERSION="5.9.0"
BASE="/opt/iota-dual"
UNIT_DIR="/etc/systemd/system"
MARKER="iota-dual-test-v1"
EXPORT_YAML="/root/IOTA-DUAL.yaml"
EXPORT_INFO="/root/IOTA-DUAL.txt"
CONTROL="/usr/local/sbin/iota-dual"
SYSCTL_FILE="/etc/sysctl.d/90-iota-dual-udp.conf"
JOURNAL_CONFIG="/etc/systemd/journald@iota-dual.conf.d/limits.conf"
TEMP_DIR=""
INSTALL_STARTED=0
INSTALL_DONE=0

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  local result=$?
  if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /tmp/iota-dual.* && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if (( INSTALL_STARTED && ! INSTALL_DONE )); then
    warn "Installation did not complete. Files were preserved for diagnosis."
    warn "Run: iota-dual status ; iota-dual uninstall"
  fi
  return "$result"
}
trap cleanup EXIT

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this command as root (sudo bash script.sh)."
}

managed_install() {
  [[ ! -L "$BASE" && -f "$BASE/managed-by" ]] &&
    [[ "$(<"$BASE/managed-by")" == "$MARKER" ]]
}

port_in_use() {
  local protocol=$1 port=$2
  if [[ "$protocol" == tcp ]]; then
    [[ -n "$(ss -H -ltn "sport = :$port")" ]]
  else
    [[ -n "$(ss -H -lun "sport = :$port")" ]]
  fi
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

is_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    sys.exit(0 if ip.version == 4 and ip.is_global else 1)
except ValueError:
    sys.exit(1)
PY
}

download_checked() {
  local url=$1 destination=$2 expected=$3
  curl -fLsS --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 300 "$url" -o "$destination"
  printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status ||
    die "SHA256 verification failed: $url"
}

detect_ip() {
  local nic_ip external_ip
  if [[ -n "${VPS_IP:-}" ]]; then
    is_public_ipv4 "$VPS_IP" || die "VPS_IP must be a public IPv4 address."
    PUBLIC_IP=$VPS_IP
    return
  fi
  nic_ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
  if is_public_ipv4 "$nic_ip"; then
    PUBLIC_IP=$nic_ip
    return
  fi
  external_ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
  if ! is_public_ipv4 "$external_ip"; then
    external_ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://ifconfig.me/ip || true)
  fi
  is_public_ipv4 "$external_ip" || die "Cannot detect a public IPv4; set VPS_IP explicitly."
  PUBLIC_IP=$external_ip
  warn "NAT may be present. Provider inbound port mapping is required."
}

check_fresh_server() {
  local candidate
  for candidate in "$BASE" "$CONTROL" "$EXPORT_YAML" "$EXPORT_INFO" "$SYSCTL_FILE" \
    "$UNIT_DIR/iota-dual-hy2.service" "$UNIT_DIR/iota-dual-reality.service" \
    "$UNIT_DIR/iota-dual-subscription.service" "$UNIT_DIR/iota-dual-maintain.service" \
    "$UNIT_DIR/iota-dual-maintain.timer" "$UNIT_DIR/iota-dual-renew.service" \
    "$UNIT_DIR/iota-dual-renew.timer" "$JOURNAL_CONFIG"; do
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || die "Existing file: $candidate. No files were overwritten."
  done
  # Do not stop, remove, or overwrite an existing proxy/panel.
  for candidate in /etc/hysteria /usr/local/etc/xray /etc/xray /etc/sing-box /usr/local/x-ui /etc/x-ui; do
    [[ ! -e "$candidate" ]] || die "Existing proxy installation: $candidate. Use a fresh VPS."
  done
  port_in_use udp "$HY_PORT" && die "UDP/$HY_PORT is occupied; no services were stopped."
  port_in_use tcp "$REALITY_PORT" && die "TCP/$REALITY_PORT is occupied; no services were stopped."
  port_in_use tcp "$SUB_PORT" && die "TCP/$SUB_PORT is occupied; subscription port is not available."
  port_in_use tcp 80 && die "TCP/80 is occupied. IP certificate validation needs this port; nothing was stopped."
  if getent passwd iota-dual >/dev/null || getent group iota-dual >/dev/null; then
    die "The iota-dual account/group already exists. Refusing to reuse it."
  fi
  if getent passwd iota-dual-sub >/dev/null || getent group iota-dual-sub >/dev/null; then
    die "The iota-dual-sub account/group already exists. Refusing to reuse it."
  fi
  return 0
}

choose_reality_target() {
  local host output
  local -a targets=(www.apple.com www.microsoft.com www.cloudflare.com)
  if [[ -n "${REALITY_SNI:-}" ]]; then
    [[ "$REALITY_SNI" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Invalid REALITY_SNI."
    targets=("$REALITY_SNI")
  fi
  for host in "${targets[@]}"; do
    output=$(timeout 12 openssl s_client -connect "$host:443" -servername "$host" \
      -tls1_3 -alpn h2 -verify_hostname "$host" -verify_return_error </dev/null 2>&1 || true)
    if [[ "$output" == *"ALPN protocol: h2"* && "$output" == *"Verify return code: 0 (ok)"* ]]; then
      SNI=$host
      return
    fi
  done
  die "No candidate REALITY target passed TLS 1.3 + h2 checks from this VPS. No services started."
}

write_server_configs() {
  cat >"$BASE/config/hy2.yaml" <<EOF
listen: 0.0.0.0:${HY_PORT}
tls:
  cert: ${BASE}/config/hy2.crt
  key: ${BASE}/config/hy2.key
auth:
  type: password
  password: ${HY_PASSWORD}
obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}
ignoreClientBandwidth: true
congestion:
  type: bbr
  bbrProfile: conservative
disableUDP: false
udpIdleTimeout: 300s
EOF

  # Deliberately omit Vision flow to avoid the reported Vision+concurrent-XUDP
  # bug in Xray 26.10.31 (#7336). REALITY still provides transport security.
  # No sniffing/transparent proxy/NAT rules or automatic connection cleanup.
  cat >"$BASE/config/reality.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "iota-reality-tcp",
    "listen": "0.0.0.0",
    "port": ${REALITY_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_UUID}", "email": "iota-test"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "${SNI}:443",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [{
      "type": "field",
      "ip": ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"],
      "outboundTag": "block"
    }]
  }
}
EOF
  chown root:iota-dual "$BASE/config/"*
  chmod 640 "$BASE/config/"*
}

write_units() {
  local service executable arguments
  for service in hy2 reality; do
    if [[ "$service" == hy2 ]]; then
      executable=hysteria
      arguments="server -c $BASE/config/hy2.yaml"
    else
      executable=xray
      arguments="run -c $BASE/config/reality.json"
    fi
    cat >"$UNIT_DIR/iota-dual-${service}.service" <<EOF
[Unit]
Description=IOTA dual test ${service}
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
User=iota-dual
Group=iota-dual
WorkingDirectory=${BASE}
ExecStart=${BASE}/bin/${executable} ${arguments}
Restart=on-failure
RestartSec=5
LimitNOFILE=262144
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
RestrictSUIDSGID=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=30s
LogRateLimitBurst=150

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT_DIR/iota-dual-${service}.service"
  done
}

write_client_files() {
  # No DNS/TUN/routing changes are made on any Mac. Import is a user action.
  # The leaf certificate is pinned rather than blindly skipping verification.
  cat >"$EXPORT_YAML" <<EOF
# IOTA dual test v${VERSION}; contains PRIVATE node credentials.
# Keep your existing Clash DNS/TUN setup. Test one or two Macs first.
mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: IOTA-HY2-UDP
    type: hysteria2
    server: ${PUBLIC_IP}
    port: ${HY_PORT}
    password: "${HY_PASSWORD}"
    obfs: salamander
    obfs-password: "${OBFS_PASSWORD}"
    sni: iota-hy2.local
    skip-cert-verify: false
    fingerprint: "${CERT_PIN}"
    bbr-profile: conservative
  - name: IOTA-REALITY-TCP
    type: vless
    server: ${PUBLIC_IP}
    port: ${REALITY_PORT}
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
    udp: true
    packet-encoding: xudp
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    smux:
      enabled: false
proxy-groups:
  - name: IOTA-SELECT
    type: select
    proxies:
      - IOTA-HY2-UDP
      - IOTA-REALITY-TCP
rules:
  - MATCH,IOTA-SELECT
EOF
  cat >"$EXPORT_INFO" <<EOF
IOTA DUAL TEST ${VERSION}
Hysteria ${HY_VERSION}; Xray ${XR_VERSION}
Server: ${PUBLIC_IP}
HY2: UDP/${HY_PORT}; REALITY: TCP/${REALITY_PORT}

Clash/Mihomo: copy the temporary subscription URL printed below.
Or download ${EXPORT_YAML} over SSH/SFTP and import as a local profile.
Preserve your working DNS/TUN settings or merge only the two proxies.
Use a recent Clash Verge Rev/Mihomo core (1.19.20+ for certificate pin support).
Select IOTA-HY2-UDP normally; select IOTA-REALITY-TCP if HY2 is unreachable.
Switching protocols closes old connections and may cause IOTA to requeue.
No automatic switching or load balancing is enabled.

REALITY sharing URI (no Vision flow):
vless://${VLESS_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#IOTA-REALITY-TCP

HY2 sharing URI (use the pinned YAML profile for Mihomo):
hysteria2://${HY_PASSWORD}@${PUBLIC_IP}:${HY_PORT}/?sni=iota-hy2.local&insecure=1&pinSHA256=${CERT_PIN}&obfs=salamander&obfs-password=${OBFS_PASSWORD}#IOTA-HY2-UDP

Provider firewall: allow inbound UDP/${HY_PORT} AND TCP/${REALITY_PORT}.
This installer does not disable UFW, flush firewall rules, or alter SSH.
A listening service does NOT prove the China-to-VPS path or IOTA P2P works.
Two protocols on one VPS do NOT protect against VPS/IP/network outages.

Status:      iota-dual status
Show config: iota-dual show
New URL:     iota-dual subscribe
Diagnose:    iota-dual diagnose
HY2 log:     journalctl --namespace='*' -u iota-dual-hy2 -f
REALITY log: journalctl --namespace='*' -u iota-dual-reality -f
Uninstall:   iota-dual uninstall
EOF
  chmod 600 "$EXPORT_YAML" "$EXPORT_INFO"
}

write_subscription_program() {
  cat >"$BASE/subscription_server.py" <<'PY'
#!/usr/bin/env python3
"""Serve exactly one token-protected YAML file over TLS until fixed expiry.

TLS is mandatory; a certificate failure never falls back to plaintext HTTP.
No directory listing, arbitrary file paths, access logs, uploads, or redirects.
"""
import argparse
import hmac
import json
from pathlib import Path
import re
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def serve(directory, bind):
    root = Path(directory)
    state = json.loads((root / "state.json").read_text(encoding="utf-8"))
    token = state["token"]
    expires_at = int(state["expires_at"])
    port = int(state["port"])
    if not re.fullmatch(r"[0-9a-f]{64}", token) or not 1024 <= port <= 65535:
        raise ValueError("Invalid subscription settings")
    if time.time() >= expires_at:
        return
    payload = (root / "clash.yaml").read_bytes()
    if not payload or len(payload) > 262144:
        raise ValueError("Invalid subscription file size")
    expected = f"/{token}/clash.yaml"

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "IOTA-Subscription"
        sys_version = ""

        def log_message(self, *_args):
            pass  # Never store request paths or bearer tokens in access logs.

        def handle_request(self, head=False):
            path = urlsplit(self.path).path
            valid = hmac.compare_digest(path.encode("utf-8"), expected.encode("ascii"))
            valid = valid and time.time() < expires_at
            body = payload if valid else b"Not found\n"
            self.send_response(200 if valid else 404)
            self.send_header("Content-Type", "application/yaml; charset=utf-8" if valid else "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            if valid:
                self.send_header("Content-Disposition", 'inline; filename="IOTA-DUAL.yaml"')
            self.end_headers()
            if not head:
                self.wfile.write(body)
            self.close_connection = True

        def do_GET(self):
            self.handle_request()

        def do_HEAD(self):
            self.handle_request(head=True)

    class Server(ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = True
        request_queue_size = 32

        def __init__(self, *args, **kwargs):
            self.slots = threading.BoundedSemaphore(16)
            super().__init__(*args, **kwargs)

        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address

        def process_request(self, request, client_address):
            if not self.slots.acquire(blocking=False):
                self.shutdown_request(request)
                return
            try:
                super().process_request(request, client_address)
            except BaseException:
                self.slots.release()
                raise

        def process_request_thread(self, request, client_address):
            try:
                super().process_request_thread(request, client_address)
            finally:
                self.slots.release()

        def handle_error(self, _request, _client_address):
            pass  # Do not log request context or tokens on malformed requests.

    with Server((bind, port), Handler) as server:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.crt", root / "server.key")
        # Defer per-client handshakes to workers; never block the accept loop.
        server.socket = context.wrap_socket(server.socket, server_side=True,
                                            do_handshake_on_connect=False)
        server.timeout = 1
        while time.time() < expires_at:
            server.handle_request()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--bind", default="0.0.0.0")
    args = parser.parse_args()
    serve(args.directory, args.bind)
PY
  chmod 644 "$BASE/subscription_server.py"
}

write_subscription_unit() {
  cat >"$UNIT_DIR/iota-dual-subscription.service" <<EOF
[Unit]
Description=IOTA short-lived verified HTTPS subscription
After=network-online.target
Wants=network-online.target

[Service]
User=iota-dual-sub
Group=iota-dual-sub
ExecStart=/usr/bin/python3 ${BASE}/subscription_server.py ${BASE}/subscription
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
StandardOutput=null
StandardError=journal
LogNamespace=iota-dual
EOF
  chmod 644 "$UNIT_DIR/iota-dual-subscription.service"
}

show_subscription_link() {
  [[ -f "$BASE/subscription/state.json" ]] || return 0
  python3 - "$BASE/subscription/state.json" <<'PY'
import datetime, json, sys, time
state = json.load(open(sys.argv[1], encoding="utf-8"))
if state.get("scheme") != "https":
    print("Legacy HTTP URL disabled. Upgrade and run: iota-dual subscribe")
elif time.time() >= state["expires_at"]:
    print("Subscription URL expired. Run: iota-dual subscribe")
else:
    print("\n===== COPY THIS CLASH SUBSCRIPTION URL =====")
    print(f'https://{state["public_ip"]}:{state["port"]}/{state["token"]}/clash.yaml')
    expiry = datetime.datetime.fromtimestamp(state["expires_at"], datetime.timezone.utc)
    print("Expires:", expiry.isoformat())
    print("HTTPS with a publicly trusted IP certificate. Never disable client certificate verification.")
    print("Keep this bearer URL private. Possession of it permits downloading node credentials.")
    print("Imported proxy nodes continue working after the subscription URL expires.")
PY
}

open_managed_ufw_port() {
  local specification=$1
  if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
    if ! LC_ALL=C ufw status | awk '{print $1, $2}' | grep -Fxq "$specification ALLOW"; then
      ufw allow "$specification" comment 'iota-dual-test'
      printf '%s\n' "$specification" >>"$BASE/ufw-added"
    fi
  fi
}

copy_subscription_certificate() {
  require_root
  managed_install || die "No managed installation found."
  local source_dir="$BASE/acme/config/live/iota-dual-ip"
  [[ -f "$source_dir/fullchain.pem" && -f "$source_dir/privkey.pem" ]] || die "Subscription certificate missing."
  [[ -d "$BASE/subscription" && ! -L "$BASE/subscription" ]] || die "Subscription directory missing or invalid."
  install -m 640 -o root -g iota-dual-sub "$source_dir/fullchain.pem" "$BASE/subscription/server.crt"
  install -m 640 -o root -g iota-dual-sub "$source_dir/privkey.pem" "$BASE/subscription/server.key"
  # Reload only the download server if it is currently in its active TTL window.
  if systemctl is-active --quiet iota-dual-subscription.service; then
    systemctl restart iota-dual-subscription.service
  fi
}

ensure_subscription_certificate() {
  local live="$BASE/acme/config/live/iota-dual-ip" certbot="$BASE/acme-venv/bin/certbot"
  if [[ -f "$live/cert.pem" ]] &&
     openssl x509 -in "$live/cert.pem" -noout -checkip "$PUBLIC_IP" >/dev/null 2>&1 &&
     openssl x509 -in "$live/cert.pem" -noout -checkend 86400 >/dev/null 2>&1; then
    copy_subscription_certificate
    return
  fi
  port_in_use tcp 80 && die "TCP/80 is occupied. Certificate validation cannot start; no HTTP fallback will be opened."
  open_managed_ufw_port 80/tcp
  if [[ ! -x "$certbot" ]]; then
    log "Install isolated official Certbot ${CERTBOT_VERSION}; no pip cache or system Certbot changes."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv
    python3 -m venv "$BASE/acme-venv"
    "$BASE/acme-venv/bin/python" -m pip install --no-cache-dir --index-url https://pypi.org/simple "certbot==${CERTBOT_VERSION}"
  fi
  install -d -m 700 "$BASE/acme" "$BASE/acme/config" "$BASE/acme/work" "$BASE/acme/logs"
  log "Request a trusted Let's Encrypt IP certificate. Inbound TCP/80 must reach this VPS."
  log "This registers an ACME account and accepts the Let's Encrypt subscriber agreement."
  if ! "$certbot" certonly --standalone --preferred-challenges http --http-01-address 0.0.0.0 \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --server https://acme-v02.api.letsencrypt.org/directory \
    --required-profile shortlived --ip-address "$PUBLIC_IP" \
    --cert-name iota-dual-ip --keep-until-expiring --key-type ecdsa \
    --config-dir "$BASE/acme/config" --work-dir "$BASE/acme/work" \
    --logs-dir "$BASE/acme/logs" --max-log-backups 7; then
    die "IP certificate issuance failed. Proxy services were not stopped. No plaintext subscription was opened; check TCP/80 and retry iota-dual subscribe."
  fi
  openssl x509 -in "$live/cert.pem" -noout -checkip "$PUBLIC_IP" >/dev/null || die "Certificate IP mismatch."
  openssl x509 -in "$live/cert.pem" -noout -checkend 7200 >/dev/null || die "Certificate validity is too short."
  copy_subscription_certificate
}

write_renewal_units() {
  cat >"$UNIT_DIR/iota-dual-renew.service" <<EOF
[Unit]
Description=Renew only the IOTA subscription IP certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CONTROL} renew-cert
LogNamespace=iota-dual
EOF
  cat >"$UNIT_DIR/iota-dual-renew.timer" <<'EOF'
[Unit]
Description=Check the IOTA subscription certificate twice daily

[Timer]
OnBootSec=15min
OnUnitActiveSec=12h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$UNIT_DIR/iota-dual-renew.service" "$UNIT_DIR/iota-dual-renew.timer"
}

renew_subscription_certificate() {
  require_root
  managed_install || die "No managed installation found."
  [[ -x "$BASE/acme-venv/bin/certbot" && -f "$BASE/acme/config/renewal/iota-dual-ip.conf" ]] || return 0
  # Certbot's own lock prevents overlapping renewals. Do not touch system Certbot.
  "$BASE/acme-venv/bin/certbot" renew --quiet --cert-name iota-dual-ip \
    --config-dir "$BASE/acme/config" --work-dir "$BASE/acme/work" \
    --logs-dir "$BASE/acme/logs" --max-log-backups 7 \
    --deploy-hook "$CONTROL deploy-cert"
}

setup_maintenance() {
  local unit directory
  install -d -m 755 "$(dirname "$JOURNAL_CONFIG")"
  cat >"$JOURNAL_CONFIG" <<'EOF'
# Managed by iota-dual-test-v1; applies ONLY to its journal namespace.
[Journal]
Storage=persistent
SystemMaxUse=100M
RuntimeMaxUse=50M
SystemMaxFileSize=16M
SystemKeepFree=256M
MaxRetentionSec=7day
MaxFileSec=1day
EOF
  chmod 644 "$JOURNAL_CONFIG"
  for unit in iota-dual-hy2 iota-dual-reality; do
    [[ -f "$UNIT_DIR/$unit.service" ]] || continue
    directory="$UNIT_DIR/$unit.service.d"
    install -d -m 755 "$directory"
    cat >"$directory/20-iota-journal.conf" <<'EOF'
# Managed by iota-dual-test-v1
[Service]
LogNamespace=iota-dual
EOF
    chmod 644 "$directory/20-iota-journal.conf"
  done
  cat >"$UNIT_DIR/iota-dual-maintain.service" <<EOF
[Unit]
Description=Rotate only IOTA dual namespace logs, without touching network connections

[Service]
Type=oneshot
ExecStart=${CONTROL} maintain
Nice=19
IOSchedulingClass=idle
LogNamespace=iota-dual
EOF
  cat >"$UNIT_DIR/iota-dual-maintain.timer" <<'EOF'
[Unit]
Description=Daily bounded IOTA proxy log retention

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$UNIT_DIR/iota-dual-maintain.service" "$UNIT_DIR/iota-dual-maintain.timer"
  systemctl daemon-reload
  systemctl enable --now iota-dual-maintain.timer
  log "Own logs: approximately 100 MB / 7 days, daily rotation. No memory-cache, conntrack, DNS or network flushing."
  log "On upgrade, proxy log isolation takes effect at the next planned service start; no proxy restart was forced."
}

maintain_server() {
  require_root
  managed_install || die "No managed installation found."
  log "Rotate/vacuum only the iota-dual journal namespace; old archived logs may be removed."
  journalctl --namespace=iota-dual --rotate
  journalctl --namespace=iota-dual --vacuum-size=100M --vacuum-time=7d
  log "Done. No system-wide logs, active connections or memory caches were cleared."
}

diagnose_server() {
  require_root
  log "Read-only network/resource snapshot; not a diagnosis or a P2P stability test."
  date -Is
  printf '\nMemory (look at available, not just free/cache):\n'
  free -h
  printf '\nDisk space and inodes:\n'
  df -h /
  df -i /
  printf '\nSocket summary:\n'
  ss -s
  printf '\nConntrack capacity, if present (not a packet-loss measure):\n'
  sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max 2>/dev/null || true
  printf '\nCumulative UDP counters (compare TWO snapshots; these are not percentages):\n'
  nstat -az UdpInErrors UdpRcvbufErrors UdpSndbufErrors UdpNoPorts IpReasmFails 2>/dev/null || true
  printf '\nRecent OOM/conntrack-full kernel events:\n'
  journalctl -k --since '-2 hours' --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process|nf_conntrack.*(full|drop)' | tail -n 30 || true
  printf '\nOwn journal usage:\n'
  journalctl --namespace=iota-dual --disk-usage 2>/dev/null || true
  printf '\nOwn log-retention and certificate timers:\n'
  systemctl list-timers --all --no-pager 'iota-dual-*' || true
}

make_subscription() {
  local ttl old_port token probe attempt
  require_root
  managed_install || die "No managed dual installation found."
  [[ -f "$BASE/complete" && -f "$EXPORT_YAML" ]] || die "Finish proxy installation before creating a subscription."
  [[ ! -L "$BASE/subscription" ]] || die "Unexpected subscription directory symlink."
  SUB_PORT=${SUB_PORT:-18080}
  ttl=${SUB_TTL_MINUTES:-30}
  valid_port "$SUB_PORT" && (( SUB_PORT >= 1024 )) || die "SUB_PORT must be 1024-65535."
  [[ "$ttl" =~ ^[1-9][0-9]?$ ]] && (( ttl >= 5 && ttl <= 60 )) || die "SUB_TTL_MINUTES must be 5-60."
  if port_in_use tcp "$SUB_PORT"; then
    old_port=0
    if [[ -f "$BASE/subscription/state.json" ]]; then
      old_port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$BASE/subscription/state.json")
    fi
    [[ "$old_port" == "$SUB_PORT" ]] && systemctl is-active --quiet iota-dual-subscription.service ||
      die "TCP/$SUB_PORT is occupied by another service. Set SUB_PORT to a free port."
  fi
  # Read only the known generated server lines; no eval and no wallet access.
  PUBLIC_IP=$(python3 - "$EXPORT_YAML" <<'PY'
import ipaddress, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
hosts = re.findall(r"^    server: ([0-9.]+)$", text, re.M)
if len(hosts) != 2 or len(set(hosts)) != 1:
    raise SystemExit("Expected two generated nodes on one IPv4 server")
ip = ipaddress.ip_address(hosts[0])
if ip.version != 4 or not ip.is_global:
    raise SystemExit("Expected public IPv4")
print(ip)
PY
)
  if [[ ! -f "$BASE/subscription-account-created" ]]; then
    if getent passwd iota-dual-sub >/dev/null || getent group iota-dual-sub >/dev/null; then
      die "Unmanaged subscription account/group exists. Refusing to reuse it."
    fi
    groupadd --system iota-dual-sub
    touch "$BASE/subscription-account-created"
  fi
  if ! getent passwd iota-dual-sub >/dev/null; then
    useradd --system --gid iota-dual-sub --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin iota-dual-sub
  fi
  install -d -m 750 -o root -g iota-dual-sub "$BASE/subscription"
  # Close any legacy plaintext listener before validation; never reopen HTTP.
  if [[ -f "$UNIT_DIR/iota-dual-subscription.service" ]]; then
    systemctl stop iota-dual-subscription.service
  fi
  ensure_subscription_certificate
  install -m 640 -o root -g iota-dual-sub "$EXPORT_YAML" "$BASE/subscription/clash.yaml"
  token=$(openssl rand -hex 32)
  IOTA_SUB_TOKEN="$token" python3 - "$BASE/subscription/state.json" "$PUBLIC_IP" "$SUB_PORT" "$ttl" <<'PY'
import json, os, sys, time
path, ip, port, ttl = sys.argv[1:]
token = os.environ["IOTA_SUB_TOKEN"]
state = {"scheme": "https", "public_ip": ip, "port": int(port), "token": token,
         "expires_at": int(time.time()) + int(ttl) * 60}
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(state, f)
os.replace(path + ".tmp", path)
PY
  chown root:iota-dual-sub "$BASE/subscription/state.json"
  chmod 640 "$BASE/subscription/state.json"
  write_subscription_program
  write_subscription_unit
  write_renewal_units
  open_managed_ufw_port "$SUB_PORT/tcp"
  systemctl daemon-reload
  systemctl enable --now iota-dual-renew.timer
  # Do not restart either proxy. A subscription refresh only restarts this server.
  systemctl restart iota-dual-subscription.service
  probe=$(mktemp /tmp/iota-dual-sub-check.XXXXXXXX)
  for attempt in {1..5}; do
    # Pass the bearer URL through stdin, not the process argument list.
    if curl --noproxy '*' -fsS --max-time 3 --connect-to "$PUBLIC_IP:$SUB_PORT:127.0.0.1:$SUB_PORT" --config - -o "$probe" 2>/dev/null <<EOF
url = "https://$PUBLIC_IP:$SUB_PORT/$token/clash.yaml"
EOF
    then
      break
    fi
    sleep 1
  done
  if ! cmp -s "$EXPORT_YAML" "$probe"; then
    rm -f -- "$probe"
    die "Proxy services were not changed, but subscription self-check failed. Run iota-dual status."
  fi
  rm -f -- "$probe"
  log "Subscription passed HTTPS certificate/IP verification and content comparison. Provider firewall must allow TCP/$SUB_PORT and TCP/80 for certificate renewal."
  show_subscription_link
}

install_server() {
  local candidate arch hy_asset hy_hash xr_asset xr_hash key_output actual
  require_root
  [[ -d /run/systemd/system ]] || die "A systemd-based Ubuntu VPS is required."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die "Use a fresh Ubuntu 22.04 or 24.04 VPS."
  [[ "${VERSION_ID:-}" == 22.04 || "${VERSION_ID:-}" == 24.04 ]] || die "Supported: Ubuntu 22.04/24.04."
  [[ -f "${BASH_SOURCE[0]}" ]] || die "Download this script to a regular file first (curl -o), then run bash on that file."
  if managed_install; then
    [[ -f "$BASE/complete" ]] || die "An incomplete installation exists. Run iota-dual status / uninstall."
    log "Proxy services already installed. Updating HTTPS/maintenance modules; no proxy restart or password change."
    if [[ ! "${BASH_SOURCE[0]}" -ef "$CONTROL" ]]; then
      install -m 700 -- "${BASH_SOURCE[0]}" "$CONTROL"
    fi
    setup_maintenance
    make_subscription
    return
  fi
  HY_PORT=${HY2_PORT:-443}
  REALITY_PORT=${VLESS_PORT:-443}
  SUB_PORT=${SUB_PORT:-18080}
  valid_port "$HY_PORT" && valid_port "$REALITY_PORT" && valid_port "$SUB_PORT" || die "Invalid port number."
  (( SUB_PORT >= 1024 )) && [[ "$SUB_PORT" != "$REALITY_PORT" && "$REALITY_PORT" != 80 ]] || die "Subscription needs its own TCP port (1024+); TCP/80 is reserved for certificate validation."
  command -v ss >/dev/null || die "Missing iproute2; install it with: apt-get update && apt-get install -y iproute2"
  check_fresh_server

  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      hy_asset=hysteria-linux-amd64
      hy_hash=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691
      xr_asset=Xray-linux-64.zip
      xr_hash=e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214 ;;
    aarch64|arm64)
      hy_asset=hysteria-linux-arm64
      hy_hash=a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7
      xr_asset=Xray-linux-arm64-v8a.zip
      xr_hash=1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d ;;
    *) die "Unsupported architecture: $arch" ;;
  esac

  log "1/7 Install dependencies (no Docker or panel)."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl openssl iproute2 procps python3 unzip passwd
  TEMP_DIR=$(mktemp -d /tmp/iota-dual.XXXXXXXX)
  detect_ip
  log "2/7 Check a REALITY TLS 1.3/h2 target."
  choose_reality_target

  log "3/7 Download pinned official binaries and verify SHA256."
  download_checked "https://github.com/HyNetworks/hysteria/releases/download/app/v${HY_VERSION}/${hy_asset}" "$TEMP_DIR/hysteria" "$hy_hash"
  download_checked "https://github.com/XTLS/Xray-core/releases/download/v${XR_VERSION}/${xr_asset}" "$TEMP_DIR/xray.zip" "$xr_hash"
  unzip -q "$TEMP_DIR/xray.zip" xray -d "$TEMP_DIR"
  chmod 755 "$TEMP_DIR/hysteria" "$TEMP_DIR/xray"
  actual=$("$TEMP_DIR/xray" version | sed -n '1p')
  [[ "$actual" == "Xray ${XR_VERSION} "* ]] || die "Unexpected Xray binary version."
  key_output=$("$TEMP_DIR/xray" x25519)
  PRIVATE_KEY=$(awk -F': *' '/^Private[Kk]ey:|^Private key:/{print $2;exit}' <<<"$key_output")
  PUBLIC_KEY=$(awk -F': *' '/^Public[Kk]ey:|^Public key:|^Password:/{print $2;exit}' <<<"$key_output")
  [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ && "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Could not parse REALITY key pair."
  HY_PASSWORD=$(openssl rand -hex 24)
  OBFS_PASSWORD=$(openssl rand -hex 24)
  VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 8)

  log "4/7 Create dedicated non-root services and private configurations."
  install -d -m 755 "$BASE" "$BASE/bin"
  printf '%s\n' "$MARKER" >"$BASE/managed-by"
  INSTALL_STARTED=1
  # Keep the exact invoked script locally for offline status/uninstall.
  install -m 700 -- "${BASH_SOURCE[0]}" "$CONTROL"
  groupadd --system iota-dual
  useradd --system --gid iota-dual --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin iota-dual
  install -d -m 750 -o root -g iota-dual "$BASE/config"
  install -m 755 "$TEMP_DIR/hysteria" "$BASE/bin/hysteria"
  install -m 755 "$TEMP_DIR/xray" "$BASE/bin/xray"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 825 \
    -keyout "$BASE/config/hy2.key" -out "$BASE/config/hy2.crt" \
    -subj '/CN=iota-hy2.local' -addext 'subjectAltName=DNS:iota-hy2.local' >/dev/null 2>&1
  CERT_PIN=$(openssl x509 -in "$BASE/config/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
  write_server_configs
  "$BASE/bin/xray" run -test -c "$BASE/config/reality.json"
  write_units
  write_client_files
  setup_maintenance

  log "5/7 Raise UDP buffer maximums only (never reduce existing values)."
  : >"$BASE/previous-sysctl"
  : >"$SYSCTL_FILE"
  for candidate in net.core.rmem_max net.core.wmem_max; do
    actual=$(sysctl -n "$candidate")
    printf '%s = %s\n' "$candidate" "$actual" >>"$BASE/previous-sysctl"
    (( actual >= 16777216 )) || actual=16777216
    printf '%s = %s\n' "$candidate" "$actual" >>"$SYSCTL_FILE"
  done
  chmod 644 "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" || warn "Host denied UDP tuning; services can still run."

  log "6/7 Add narrowly scoped UFW rules only if UFW is already active."
  if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
    for candidate in "$HY_PORT/udp" "$REALITY_PORT/tcp"; do
      # Track only rules this installer added, so uninstall preserves older rules.
      if ! LC_ALL=C ufw status | awk '{print $1, $2}' | grep -Fxq "$candidate ALLOW"; then
        if ufw allow "$candidate" comment 'iota-dual-test'; then
          printf '%s\n' "$candidate" >>"$BASE/ufw-added"
        else
          warn "UFW rule failed: $candidate. Open this port manually."
        fi
      fi
    done
  fi

  log "7/7 Start both services and verify local listeners."
  systemctl daemon-reload
  systemctl enable --now iota-dual-hy2.service iota-dual-reality.service
  sleep 3
  if ! systemctl is-active --quiet iota-dual-hy2.service ||
     ! systemctl is-active --quiet iota-dual-reality.service ||
     ! port_in_use udp "$HY_PORT" || ! port_in_use tcp "$REALITY_PORT"; then
    journalctl --namespace='*' -u iota-dual-hy2 -u iota-dual-reality -n 60 --no-pager >&2 || true
    die "One or both services failed. Configuration was preserved."
  fi
  printf '%s\n' "$VERSION" >"$BASE/complete"
  INSTALL_DONE=1
  log "Both local services/listeners are running. End-to-end IOTA testing is still required."
  make_subscription
}

show_config() {
  require_root
  managed_install || die "No managed IOTA dual test installation found."
  [[ -f "$EXPORT_INFO" && -f "$EXPORT_YAML" ]] || die "Client files are missing; installation may be incomplete."
  cat "$EXPORT_INFO"
  show_subscription_link
}

status_server() {
  require_root
  log "IOTA dual test controller ${VERSION} status (no credentials printed)"
  date -Is
  for service in iota-dual-hy2 iota-dual-reality iota-dual-subscription; do
    printf '\n%s\n' "$service"
    systemctl show "$service" -p ActiveState -p SubState -p NRestarts -p ExecMainStatus || true
  done
  printf '\nListeners owned by test services:\n'
  ss -lntup | grep -E 'hysteria|xray' || true
  printf '\nRecent service logs (review IP addresses before sharing):\n'
  journalctl --namespace='*' -u iota-dual-hy2 -u iota-dual-reality -u iota-dual-subscription --since '-15 min' --no-pager -n 60 || true
}

uninstall_server() {
  local answer backup candidate old_value current installed unit
  require_root
  managed_install || die "Managed marker missing. Refusing to delete any files."
  [[ ! -L "$BASE/config" ]] || die "Unexpected config symlink. Refusing to delete."
  printf 'Remove ONLY this dual-protocol test installation. Other proxies/IOTA/wallets are untouched.\n'
  read -r -p 'Type REMOVE to continue: ' answer </dev/tty
  [[ "$answer" == REMOVE ]] || { log 'Cancelled.'; return; }
  backup=$(mktemp -d /root/iota-dual-backup.XXXXXXXX)
  chmod 700 "$backup"
  # Abort before stopping services if the recoverable backup cannot be made.
  cp -a "$BASE" "$backup/"
  for candidate in "$EXPORT_INFO" "$EXPORT_YAML" "$SYSCTL_FILE" "$CONTROL" \
    "$UNIT_DIR/iota-dual-hy2.service" "$UNIT_DIR/iota-dual-reality.service" \
    "$UNIT_DIR/iota-dual-renew.service" "$UNIT_DIR/iota-dual-renew.timer" \
    "$UNIT_DIR/iota-dual-maintain.service" "$UNIT_DIR/iota-dual-maintain.timer" "$JOURNAL_CONFIG"; do
    [[ ! -f "$candidate" ]] || cp -a "$candidate" "$backup/"
  done
  systemctl disable --now iota-dual-renew.timer iota-dual-maintain.timer 2>/dev/null || true
  systemctl stop iota-dual-renew.service iota-dual-maintain.service 2>/dev/null || true
  if systemctl is-active --quiet iota-dual-renew.service; then
    die "Certificate renewal is still running. Files were not deleted."
  fi
  if [[ -f "$UNIT_DIR/iota-dual-subscription.service" ]]; then
    cp -a "$UNIT_DIR/iota-dual-subscription.service" "$backup/"
    systemctl stop iota-dual-subscription.service || die "Could not stop the subscription server."
  fi
  # Missing units are expected after a partial install. Never delete files
  # while an installed unit is still active.
  systemctl disable --now iota-dual-hy2.service iota-dual-reality.service 2>/dev/null || true
  if systemctl is-active --quiet iota-dual-hy2.service || systemctl is-active --quiet iota-dual-reality.service; then
    die "Could not stop both services; files were not deleted."
  fi
  if [[ -f "$BASE/ufw-added" ]] && command -v ufw >/dev/null; then
    while IFS= read -r candidate; do
      [[ "$candidate" =~ ^[0-9]+/(tcp|udp)$ ]] || continue
      ufw --force delete allow "$candidate" || warn "Check remaining UFW rule: $candidate"
    done <"$BASE/ufw-added"
  fi
  # Restore a sysctl only when it still matches the value installed by us.
  if [[ -f "$BASE/previous-sysctl" && -f "$SYSCTL_FILE" ]]; then
    while read -r candidate _ old_value; do
      installed=$(awk -v key="$candidate" '$1 == key {print $3}' "$SYSCTL_FILE")
      current=$(sysctl -n "$candidate")
      if [[ "$current" == "$installed" ]]; then
        sysctl -w "$candidate=$old_value" || warn "Could not restore $candidate."
      fi
    done <"$BASE/previous-sysctl"
  fi
  rm -f -- "$UNIT_DIR/iota-dual-hy2.service" "$UNIT_DIR/iota-dual-reality.service"
  rm -f -- "$UNIT_DIR/iota-dual-subscription.service"
  rm -f -- "$UNIT_DIR/iota-dual-renew.service" "$UNIT_DIR/iota-dual-renew.timer"
  rm -f -- "$UNIT_DIR/iota-dual-maintain.service" "$UNIT_DIR/iota-dual-maintain.timer"
  rm -f -- "$JOURNAL_CONFIG"
  rmdir -- "$(dirname "$JOURNAL_CONFIG")" 2>/dev/null || true
  for unit in iota-dual-hy2 iota-dual-reality; do
    if [[ -f "$UNIT_DIR/$unit.service.d/20-iota-journal.conf" ]]; then
      cp -a "$UNIT_DIR/$unit.service.d/20-iota-journal.conf" "$backup/$unit-journal.conf"
      rm -f -- "$UNIT_DIR/$unit.service.d/20-iota-journal.conf"
      rmdir -- "$UNIT_DIR/$unit.service.d" 2>/dev/null || true
    fi
  done
  rm -f -- "$SYSCTL_FILE" "$EXPORT_YAML" "$EXPORT_INFO" "$CONTROL"
  rm -rf -- /opt/iota-dual
  systemctl daemon-reload
  if getent passwd iota-dual >/dev/null; then
    userdel iota-dual || warn "The service account could not be removed."
  fi
  if getent group iota-dual >/dev/null; then
    groupdel iota-dual || warn "The service group could not be removed."
  fi
  if [[ -f "$backup/iota-dual/subscription-account-created" ]]; then
    if getent passwd iota-dual-sub >/dev/null; then
      userdel iota-dual-sub || warn "The subscription account could not be removed."
    fi
    if getent group iota-dual-sub >/dev/null; then
      groupdel iota-dual-sub || warn "The subscription group could not be removed."
    fi
  fi
  log "Removed this test installation. Recoverable backup: $backup"
  warn "The private backup contains credentials. Keep it private or remove it after verification."
}

main() {
  case "${1:-install}" in
    install) install_server ;;
    status) status_server ;;
    show) show_config ;;
    subscribe) make_subscription ;;
    renew-cert) renew_subscription_certificate ;;
    deploy-cert) copy_subscription_certificate ;;
    maintain) maintain_server ;;
    diagnose) diagnose_server ;;
    uninstall) uninstall_server ;;
    *) die 'Usage: iota-dual [install|status|show|subscribe|diagnose|maintain|renew-cert|uninstall]' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
