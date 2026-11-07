#!/usr/bin/env bash
# IOTA dual-protocol test VPS: Hysteria2/UDP + VLESS-REALITY/TCP.
# No Docker, web panel, public subscription server, or third-party monitor.
# Fresh Ubuntu 22.04/24.04; amd64/arm64. English terminal output.
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
HY_VERSION="2.13.0"
XR_VERSION="26.10.31"
BASE="/opt/iota-dual"
UNIT_DIR="/etc/systemd/system"
MARKER="iota-dual-test-v1"
EXPORT_YAML="/root/IOTA-DUAL.yaml"
EXPORT_INFO="/root/IOTA-DUAL.txt"
CONTROL="/usr/local/sbin/iota-dual"
SYSCTL_FILE="/etc/sysctl.d/90-iota-dual-udp.conf"
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
    "$UNIT_DIR/iota-dual-hy2.service" "$UNIT_DIR/iota-dual-reality.service"; do
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || die "Existing file: $candidate. No files were overwritten."
  done
  # Do not stop, remove, or overwrite an existing proxy/panel.
  for candidate in /etc/hysteria /usr/local/etc/xray /etc/xray /etc/sing-box /usr/local/x-ui /etc/x-ui; do
    [[ ! -e "$candidate" ]] || die "Existing proxy installation: $candidate. Use a fresh VPS."
  done
  port_in_use udp "$HY_PORT" && die "UDP/$HY_PORT is occupied; no services were stopped."
  port_in_use tcp "$REALITY_PORT" && die "TCP/$REALITY_PORT is occupied; no services were stopped."
  if getent passwd iota-dual >/dev/null || getent group iota-dual >/dev/null; then
    die "The iota-dual account/group already exists. Refusing to reuse it."
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

Clash/Mihomo: download ${EXPORT_YAML} over SSH/SFTP and import as a local profile.
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
HY2 log:     journalctl -u iota-dual-hy2 -f
REALITY log: journalctl -u iota-dual-reality -f
Uninstall:   iota-dual uninstall
EOF
  chmod 600 "$EXPORT_YAML" "$EXPORT_INFO"
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
    log "Already installed. Existing credentials/configuration were NOT changed."
    show_config
    return
  fi
  HY_PORT=${HY2_PORT:-443}
  REALITY_PORT=${VLESS_PORT:-443}
  valid_port "$HY_PORT" && valid_port "$REALITY_PORT" || die "Invalid port number."
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
  apt-get install -y --no-install-recommends ca-certificates curl openssl iproute2 python3 unzip passwd
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
    journalctl -u iota-dual-hy2 -u iota-dual-reality -n 60 --no-pager >&2 || true
    die "One or both services failed. Configuration was preserved."
  fi
  printf '%s\n' "$VERSION" >"$BASE/complete"
  INSTALL_DONE=1
  log "Both local services/listeners are running. End-to-end IOTA testing is still required."
  show_config
}

show_config() {
  require_root
  managed_install || die "No managed IOTA dual test installation found."
  [[ -f "$EXPORT_INFO" && -f "$EXPORT_YAML" ]] || die "Client files are missing; installation may be incomplete."
  cat "$EXPORT_INFO"
  printf '\n----- BEGIN PRIVATE CLASH YAML -----\n'
  cat "$EXPORT_YAML"
  printf '\n----- END PRIVATE CLASH YAML -----\n'
}

status_server() {
  require_root
  log "IOTA dual test status (no credentials printed)"
  date -Is
  for service in iota-dual-hy2 iota-dual-reality; do
    printf '\n%s\n' "$service"
    systemctl show "$service" -p ActiveState -p SubState -p NRestarts -p ExecMainStatus || true
  done
  printf '\nListeners owned by test services:\n'
  ss -lntup | grep -E 'hysteria|xray' || true
  printf '\nRecent service logs (review IP addresses before sharing):\n'
  journalctl -u iota-dual-hy2 -u iota-dual-reality --since '-15 min' --no-pager -n 60 || true
}

uninstall_server() {
  local answer backup candidate old_value current installed
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
    "$UNIT_DIR/iota-dual-hy2.service" "$UNIT_DIR/iota-dual-reality.service"; do
    [[ ! -f "$candidate" ]] || cp -a "$candidate" "$backup/"
  done
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
  rm -f -- "$SYSCTL_FILE" "$EXPORT_YAML" "$EXPORT_INFO" "$CONTROL"
  rm -rf -- /opt/iota-dual
  systemctl daemon-reload
  if getent passwd iota-dual >/dev/null; then
    userdel iota-dual || warn "The service account could not be removed."
  fi
  if getent group iota-dual >/dev/null; then
    groupdel iota-dual || warn "The service group could not be removed."
  fi
  log "Removed this test installation. Recoverable backup: $backup"
  warn "The private backup contains credentials. Keep it private or remove it after verification."
}

main() {
  case "${1:-install}" in
    install) install_server ;;
    status) status_server ;;
    show) show_config ;;
    uninstall) uninstall_server ;;
    *) die 'Usage: iota-dual [install|status|show|uninstall]' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
