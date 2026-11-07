#!/usr/bin/env bash
# HY2 IOTA VPS Test Installer v5.0
# Target: a fresh Ubuntu 22.04/24.04 VPS with a public IPv4 address.

set -Eeuo pipefail

readonly SCRIPT_VERSION="5.0"
readonly HY2_VERSION="v2.13.0"
readonly HY2_PORT="443"
readonly HY2_SNI="www.cloudflare.com"
readonly HY2_CONFIG="/etc/hysteria/config.yaml"
readonly HY2_RESULT="/root/HY2-IOTA-TEST.txt"
readonly HY2_SYSCTL="/etc/sysctl.d/99-hy2-iota-test.conf"
readonly HY2_SERVICE="hysteria-server.service"

TEMP_INSTALLER=""

cleanup() {
  if [[ -n "${TEMP_INSTALLER}" && -f "${TEMP_INSTALLER}" ]]; then
    rm -f "${TEMP_INSTALLER}"
  fi
}
trap cleanup EXIT

fail() {
  printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

step() {
  printf '\n\033[36m[%s]\033[0m %s\n' "$1" "$2"
}

if [[ "${EUID}" -ne 0 ]]; then
  fail "Run this installer as root: sudo bash deploy_hy2_iota_test_v5.sh"
fi

if [[ ! -r /etc/os-release ]]; then
  fail "Cannot detect the operating system."
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  fail "This test installer supports Ubuntu 22.04/24.04 only. Detected: ${PRETTY_NAME:-unknown}"
fi

case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  *) fail "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Use Ubuntu 22.04 or 24.04." ;;
esac

if [[ -e "${HY2_CONFIG}" ]] || systemctl list-unit-files "${HY2_SERVICE}" --no-legend 2>/dev/null | grep -q '^hysteria-server'; then
  fail "An existing Hysteria installation was detected. This test script will not overwrite it. Use a fresh VPS."
fi

if ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)443$'; then
  fail "UDP port 443 is already in use. Use a fresh VPS or free UDP/443 first."
fi

step "1/8" "Installing required packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl openssl iproute2 procps

step "2/8" "Detecting the VPS public IPv4 address"
PUBLIC_IP="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
if [[ ! "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  PUBLIC_IP="$(curl -4fsS --connect-timeout 5 --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)"
fi
if [[ ! "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  fail "A public IPv4 address could not be detected."
fi
printf 'Public IPv4: %s\n' "${PUBLIC_IP}"

step "3/8" "Installing Hysteria ${HY2_VERSION} from the official installer"
TEMP_INSTALLER="$(mktemp /tmp/hy2-official-installer.XXXXXX.sh)"
curl -fsSL --proto '=https' --tlsv1.2 https://get.hy2.sh/ -o "${TEMP_INSTALLER}"
chmod 700 "${TEMP_INSTALLER}"
HYSTERIA_USER=root bash "${TEMP_INSTALLER}" --version "${HY2_VERSION}"

command -v hysteria >/dev/null 2>&1 || fail "Hysteria binary was not installed."

step "4/8" "Creating a stable IOTA-oriented server configuration"
install -d -m 700 /etc/hysteria
AUTH_PASSWORD="$(openssl rand -hex 24)"
OBFS_PASSWORD="$(openssl rand -hex 24)"

openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout /etc/hysteria/private.key \
  -out /etc/hysteria/cert.crt \
  -subj "/CN=${HY2_SNI}" \
  -addext "subjectAltName=DNS:${HY2_SNI}" >/dev/null 2>&1
chmod 600 /etc/hysteria/private.key /etc/hysteria/cert.crt

cat >"${HY2_CONFIG}" <<EOF
listen: :${HY2_PORT}

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/private.key

auth:
  type: password
  password: ${AUTH_PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}

# Force Hysteria's non-Brutal BBR path. Client up/down claims are ignored.
ignoreClientBandwidth: true
congestion:
  type: bbr
  bbrProfile: conservative

# IOTA's Iroh P2P traffic needs working UDP. Keep idle UDP sessions longer.
disableUDP: false
udpIdleTimeout: 300s

quic:
  maxIdleTimeout: 60s
EOF
chmod 600 "${HY2_CONFIG}"

step "5/8" "Applying conservative UDP buffer tuning"
cat >"${HY2_SYSCTL}" <<'EOF'
# HY2 IOTA test: conservative UDP/QUIC host tuning
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 65536
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF
sysctl -p "${HY2_SYSCTL}" >/dev/null || fail "Failed to apply UDP sysctl settings."

install -d -m 755 "/etc/systemd/system/${HY2_SERVICE}.d"
cat >"/etc/systemd/system/${HY2_SERVICE}.d/iota-stability.conf" <<'EOF'
[Service]
User=root
Group=root
Restart=always
RestartSec=3s
LimitNOFILE=1048576
OOMScoreAdjust=-500
EOF

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${HY2_PORT}/udp" comment 'HY2 IOTA test' >/dev/null
fi

step "6/8" "Starting Hysteria and checking UDP/443"
systemctl daemon-reload
systemctl enable --now "${HY2_SERVICE}" >/dev/null
sleep 3

if ! systemctl is-active --quiet "${HY2_SERVICE}"; then
  journalctl -u "${HY2_SERVICE}" --no-pager -n 80 >&2 || true
  fail "Hysteria did not start. See the log above."
fi

if ! ss -H -lunp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)'; then
  journalctl -u "${HY2_SERVICE}" --no-pager -n 80 >&2 || true
  fail "Hysteria is active, but UDP port 443 is not listening."
fi

step "7/8" "Installing status and uninstall commands"
cat >/usr/local/sbin/hy2-iota-status <<'EOF'
#!/usr/bin/env bash
set -u
echo "===== HY2 IOTA TEST STATUS ====="
date
echo
echo "Version:"
hysteria version 2>/dev/null || true
echo
echo "Service:"
systemctl --no-pager --full status hysteria-server.service 2>/dev/null | sed -n '1,12p'
echo
echo "UDP/443 listener:"
ss -lunp 2>/dev/null | grep -E '(^|:)443([[:space:]]|$)' || echo "NOT LISTENING"
echo
echo "Recent log:"
journalctl -u hysteria-server.service --since '-15 minutes' --no-pager -n 60 2>/dev/null
EOF
chmod 755 /usr/local/sbin/hy2-iota-status

cat >/usr/local/sbin/hy2-iota-uninstall <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run: sudo hy2-iota-uninstall" >&2
  exit 1
fi
read -r -p "Type REMOVE to uninstall this HY2 test server: " answer
if [[ "${answer}" != "REMOVE" ]]; then
  echo "Cancelled."
  exit 0
fi
systemctl disable --now hysteria-server.service 2>/dev/null || true
tmp_installer="$(mktemp /tmp/hy2-remove.XXXXXX.sh)"
if curl -fsSL --proto '=https' --tlsv1.2 https://get.hy2.sh/ -o "${tmp_installer}"; then
  HYSTERIA_USER=root bash "${tmp_installer}" --remove || true
fi
rm -f "${tmp_installer}"
rm -rf /etc/systemd/system/hysteria-server.service.d
rm -rf /etc/hysteria
rm -f /etc/sysctl.d/99-hy2-iota-test.conf
rm -f /root/HY2-IOTA-TEST.txt
rm -f /usr/local/sbin/hy2-iota-status
rm -f /usr/local/sbin/hy2-iota-uninstall
systemctl daemon-reload
echo "HY2 IOTA test server removed. Reboot once to clear the temporary sysctl values."
EOF
chmod 755 /usr/local/sbin/hy2-iota-uninstall

step "8/8" "Generating the Mihomo/Clash test profile"
cat >"${HY2_RESULT}" <<EOF
============================================================
HY2 IOTA VPS TEST v${SCRIPT_VERSION}
============================================================

VPS IPv4: ${PUBLIC_IP}
Protocol: Hysteria2 / QUIC / UDP
Server UDP port: ${HY2_PORT}
Mode: non-Brutal BBR, conservative profile

IMPORTANT:
1. Open inbound UDP ${HY2_PORT} in the VPS provider security group/firewall.
2. Do not add up/down bandwidth values to this node.
3. Test with only 1-2 Macs first; do not migrate all machines yet.
4. Enable TUN mode and UDP in Mihomo/Clash.

---------------- Clash/Mihomo node ----------------
proxies:
  - name: HY2-IOTA-TEST
    type: hysteria2
    server: ${PUBLIC_IP}
    port: ${HY2_PORT}
    password: ${AUTH_PASSWORD}
    obfs: salamander
    obfs-password: ${OBFS_PASSWORD}
    sni: ${HY2_SNI}
    skip-cert-verify: true
    bbr-profile: conservative

---------------- Hysteria2 URI ----------------
hysteria2://${AUTH_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?insecure=1&sni=${HY2_SNI}&obfs=salamander&obfs-password=${OBFS_PASSWORD}#HY2-IOTA-TEST

---------------- VPS commands ----------------
Status:    sudo hy2-iota-status
Live log:  sudo journalctl -u hysteria-server -f
Restart:   sudo systemctl restart hysteria-server
Uninstall: sudo hy2-iota-uninstall
Profile:   ${HY2_RESULT}
============================================================
EOF
chmod 600 "${HY2_RESULT}"

printf '\n\033[32mHY2 IOTA test VPS installation completed successfully.\033[0m\n'
printf 'Hysteria version: %s\n' "$(hysteria version 2>/dev/null | head -n 1 || echo installed)"
printf 'Server: %s:%s/UDP\n' "${PUBLIC_IP}" "${HY2_PORT}"
printf 'Saved profile: %s\n\n' "${HY2_RESULT}"
cat "${HY2_RESULT}"

