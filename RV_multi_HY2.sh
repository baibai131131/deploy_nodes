#!/usr/bin/env bash
# RV_multi_HY2.sh - safe VLESS TCP REALITY + Hysteria2 dual-entry installer
# Original implementation. It uses the official XTLS installer to obtain Xray-core.

set -Eeuo pipefail
umask 077

readonly APP_NAME="rv-multi-hy2"
readonly APP_DIR="/etc/${APP_NAME}"
readonly CONFIG_FILE="${APP_DIR}/config.json"
readonly STATE_FILE="${APP_DIR}/state.env"
readonly SHARE_FILE="${APP_DIR}/share.txt"
readonly CERT_DIR="${APP_DIR}/tls"
readonly UNIT_FILE="/etc/systemd/system/${APP_NAME}.service"
readonly HY2_CONFIG_FILE="${APP_DIR}/hysteria.yaml"
readonly HY2_UNIT_FILE="/etc/systemd/system/${APP_NAME}-hy2.service"
readonly SUB_DIR="${APP_DIR}/subscriptions"
readonly SUB_SERVER_FILE="${APP_DIR}/subscription_server.py"
readonly SUB_UNIT_FILE="/etc/systemd/system/${APP_NAME}-subscriptions.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-${APP_NAME}.conf"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly HYSTERIA_BIN="/usr/local/bin/hysteria"
readonly OFFICIAL_INSTALLER="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
readonly HYSTERIA_RELEASE_BASE="https://github.com/HyNetworks/hysteria/releases/download/app"
readonly DEFAULT_XRAY_VERSION="v26.6.27"
readonly DEFAULT_HYSTERIA_VERSION="2.12.3"

ACTION="${1:-install}"
[[ "$ACTION" == --* ]] && ACTION="${ACTION#--}"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行：sudo bash $0 $ACTION"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

install_dependencies() {
  local missing=() cmd
  for cmd in curl unzip openssl ip ss python3 sysctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) && return 0

  info "安装依赖：${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl unzip openssl iproute2 python3 procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl unzip openssl iproute python3 procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl unzip openssl iproute python3 procps-ng
  else
    die "仅自动支持 apt/dnf/yum；请先安装 curl、unzip、openssl、iproute2、python3、procps"
  fi
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state() {
  {
    printf 'UUID=%q\n' "$UUID"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"
    printf 'HY2_OBFS_PASSWORD=%q\n' "$HY2_OBFS_PASSWORD"
    printf 'HY2_OBFS_MODE=%q\n' "$HY2_OBFS_MODE"
    printf 'HY2_MASQUERADE_URL=%q\n' "$HY2_MASQUERADE_URL"
    printf 'HYSTERIA_VERSION=%q\n' "$HYSTERIA_VERSION"
    printf 'HY2_PIN_SHA256=%q\n' "$HY2_PIN_SHA256"
    printf 'HY2_CERT_FINGERPRINT=%q\n' "$HY2_CERT_FINGERPRINT"
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
    printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
    printf 'HY2_SNI=%q\n' "$HY2_SNI"
    printf 'SERVER_ADDR=%q\n' "$SERVER_ADDR"
    printf 'CERT_KIND=%q\n' "$CERT_KIND"
    printf 'CORE_MANAGED=%q\n' "$CORE_MANAGED"
    printf 'UFW_TCP_ADDED=%q\n' "$UFW_TCP_ADDED"
    printf 'UFW_UDP_ADDED=%q\n' "$UFW_UDP_ADDED"
    printf 'FIREWALLD_TCP_ADDED=%q\n' "$FIREWALLD_TCP_ADDED"
    printf 'FIREWALLD_UDP_ADDED=%q\n' "$FIREWALLD_UDP_ADDED"
    printf 'SUB_TOKEN=%q\n' "$SUB_TOKEN"
    printf 'SUB_PORT=%q\n' "$SUB_PORT"
    printf 'CLASH_MIXED_PORT=%q\n' "$CLASH_MIXED_PORT"
    printf 'SUB_ENABLED=%q\n' "$SUB_ENABLED"
    printf 'SUB_SCHEME=%q\n' "$SUB_SCHEME"
    printf 'SUB_HOST=%q\n' "$SUB_HOST"
    printf 'SUB_UFW_ADDED=%q\n' "$SUB_UFW_ADDED"
    printf 'SUB_FIREWALLD_ADDED=%q\n' "$SUB_FIREWALLD_ADDED"
    printf 'ENABLE_BBR=%q\n' "$ENABLE_BBR"
    printf 'TUNING_MANAGED=%q\n' "$TUNING_MANAGED"
    printf 'PREV_QDISC=%q\n' "$PREV_QDISC"
    printf 'PREV_CC=%q\n' "$PREV_CC"
    printf 'PREV_RMEM=%q\n' "$PREV_RMEM"
    printf 'PREV_WMEM=%q\n' "$PREV_WMEM"
  } >"${STATE_FILE}.new"
  mv -f "${STATE_FILE}.new" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

detect_server_addr() {
  local value=""
  value="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  printf '%s' "$value"
}

configure_network_tuning() {
  [[ "$ENABLE_BBR" == 1 ]] || {
    info "已按 ENABLE_BBR=0 跳过内核网络调优；HY2 仍使用自身的拥塞控制"
    return 0
  }

  local available current_qdisc current_cc current_rmem current_wmem bbr_available=0
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  fi
  grep -qw bbr <<<"$available" && bbr_available=1

  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || true)"
  current_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || true)"
  if [[ "$TUNING_MANAGED" != 1 ]]; then
    PREV_QDISC="${PREV_QDISC:-$current_qdisc}"
    PREV_CC="${PREV_CC:-$current_cc}"
    PREV_RMEM="${PREV_RMEM:-$current_rmem}"
    PREV_WMEM="${PREV_WMEM:-$current_wmem}"
  fi

  cat >"${SYSCTL_FILE}.new" <<'EOF'
# Managed by rv-multi-hy2. Hysteria recommends 16 MiB UDP socket buffers.
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  if [[ "$bbr_available" == 1 ]]; then
    cat >>"${SYSCTL_FILE}.new" <<'EOF'
# Applies to TCP only; Hysteria2/QUIC has its own BBR controller.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  fi
  mv -f "${SYSCTL_FILE}.new" "$SYSCTL_FILE"
  if sysctl -p "$SYSCTL_FILE" >/dev/null; then
    TUNING_MANAGED=1
    ok "已启用 HY2 16 MiB UDP 缓冲调优"
    if [[ "$bbr_available" == 1 ]]; then
      ok "已启用内核原生 TCP BBR + fq（未更换内核）"
    else
      warn "当前内核未提供原生 BBR，保持系统原有 TCP 拥塞控制；不会安装旧内核或第三方魔改模块"
    fi
  else
    rm -f "$SYSCTL_FILE"
    [[ -n "$current_qdisc" ]] && sysctl -w "net.core.default_qdisc=$current_qdisc" >/dev/null 2>&1 || true
    [[ -n "$current_cc" ]] && sysctl -w "net.ipv4.tcp_congestion_control=$current_cc" >/dev/null 2>&1 || true
    [[ -n "$current_rmem" ]] && sysctl -w "net.core.rmem_max=$current_rmem" >/dev/null 2>&1 || true
    [[ -n "$current_wmem" ]] && sysctl -w "net.core.wmem_max=$current_wmem" >/dev/null 2>&1 || true
    warn "无法应用网络调优，已恢复原有系统设置"
  fi
}

restore_network_tuning() {
  [[ "${TUNING_MANAGED:-0}" == 1 ]] || return 0
  rm -f "$SYSCTL_FILE"
  if [[ -n "${PREV_QDISC:-}" ]]; then
    sysctl -w "net.core.default_qdisc=${PREV_QDISC}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PREV_CC:-}" ]]; then
    sysctl -w "net.ipv4.tcp_congestion_control=${PREV_CC}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PREV_RMEM:-}" ]]; then
    sysctl -w "net.core.rmem_max=${PREV_RMEM}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PREV_WMEM:-}" ]]; then
    sysctl -w "net.core.wmem_max=${PREV_WMEM}" >/dev/null 2>&1 || true
  fi
  ok "已移除本脚本的网络调优并尝试恢复原设置"
}

install_xray() {
  local tmp had_service=0 current_version
  XRAY_VERSION="${XRAY_VERSION:-$DEFAULT_XRAY_VERSION}"
  [[ -f /etc/systemd/system/xray.service || -f /usr/lib/systemd/system/xray.service ]] && had_service=1
  if [[ -x "$XRAY_BIN" && "${FORCE_CORE_UPDATE:-0}" != 1 ]]; then
    current_version="v$($XRAY_BIN version | awk 'NR==1 {gsub(/^v/,"",$2); print $2}')"
    if [[ "$current_version" == "$XRAY_VERSION" ]]; then
      CORE_MANAGED="${CORE_MANAGED:-0}"
      ok "复用兼容 Mihomo 的 Xray：$($XRAY_BIN version | head -n1)"
      return 0
    fi
    warn "现有 Xray ${current_version} 与 Mihomo REALITY 兼容目标 ${XRAY_VERSION} 不同，将安装指定版本"
  fi

  tmp="$(mktemp)"
  trap 'rm -f "${tmp:-}"' RETURN
  info "从 XTLS 官方安装器获取并校验 Xray-core"
  curl -fsSL --proto '=https' --tlsv1.2 "$OFFICIAL_INSTALLER" -o "$tmp"
  bash "$tmp" install --version "$XRAY_VERSION" --without-geodata
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装失败"
  if (( had_service == 0 )); then
    systemctl disable --now xray.service >/dev/null 2>&1 || true
    CORE_MANAGED=1
  else
    CORE_MANAGED="${CORE_MANAGED:-0}"
    warn "检测到原有 xray.service，未修改它；请确认端口不冲突"
  fi
  trap - RETURN
  rm -f "$tmp"
  ok "已安装：$($XRAY_BIN version | head -n1)"
}

install_hysteria() {
  local machine asset tmp hashes release_url expected actual current_version
  HYSTERIA_VERSION="${HYSTERIA_VERSION:-$DEFAULT_HYSTERIA_VERSION}"
  [[ "$HYSTERIA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "HYSTERIA_VERSION 格式无效：$HYSTERIA_VERSION"
  if [[ -x "$HYSTERIA_BIN" && "${FORCE_CORE_UPDATE:-0}" != 1 ]]; then
    current_version="$($HYSTERIA_BIN version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//' || true)"
    if [[ "$current_version" == "$HYSTERIA_VERSION" ]]; then
      ok "复用已校验版本 Hysteria：v${current_version}"
      return 0
    fi
    warn "现有 Hysteria ${current_version:-未知版本} 与目标 v${HYSTERIA_VERSION} 不同，将安装指定版本"
  fi

  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) asset="hysteria-linux-amd64" ;;
    aarch64|arm64) asset="hysteria-linux-arm64" ;;
    armv7l|armv7|armhf) asset="hysteria-linux-armv7" ;;
    i386|i486|i586|i686) asset="hysteria-linux-386" ;;
    ppc64le) asset="hysteria-linux-ppc64le" ;;
    riscv64) asset="hysteria-linux-riscv64" ;;
    s390x) asset="hysteria-linux-s390x" ;;
    *) die "Hysteria 不支持的架构：$machine" ;;
  esac
  tmp="$(mktemp)"
  hashes="$(mktemp)"
  trap 'rm -f "${tmp:-}" "${hashes:-}"' RETURN
  release_url="${HYSTERIA_RELEASE_BASE}/v${HYSTERIA_VERSION}"
  info "从 Hysteria 官方发布页获取并校验 ${asset} v${HYSTERIA_VERSION}"
  curl -fL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 \
    "${release_url}/${asset}" -o "$tmp"
  curl -fL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
    "${release_url}/hashes.txt" -o "$hashes"
  expected="$(awk -v name="$asset" '{file=$NF; sub(/^\*/, "", file); sub(/^.*\//, "", file); if (file==name) {print $1; exit}}' "$hashes")"
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ -n "$expected" && "$actual" == "$expected" ]] || die "Hysteria SHA256 校验失败"
  chmod 755 "$tmp"
  "$tmp" version >/dev/null 2>&1 || "$tmp" --version >/dev/null 2>&1 || die "Hysteria 二进制校验失败"
  install -m 755 "$tmp" "$HYSTERIA_BIN"
  trap - RETURN
  rm -f "$tmp" "$hashes"
  ok "已安装并校验 Hysteria：$($HYSTERIA_BIN version 2>&1 | head -n1 || true)"
}

make_keys() {
  UUID="${UUID:-$($XRAY_BIN uuid)}"
  HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -hex 18)}"
  HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-$(openssl rand -hex 16)}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    local pair
    pair="$($XRAY_BIN x25519)"
    REALITY_PRIVATE_KEY="$(awk -F': *' '/PrivateKey/{print $2; exit}' <<<"$pair")"
    REALITY_PUBLIC_KEY="$(awk -F': *' '/PublicKey|Password/{print $2; exit}' <<<"$pair")"
  else
    local expected_public_key
    expected_public_key="$($XRAY_BIN x25519 -i "$REALITY_PRIVATE_KEY" | \
      awk -F': *' '$1 == "Password (PublicKey)" || $1 == "Password" || $1 == "PublicKey" {print $2; exit}')"
    [[ -n "$expected_public_key" && "$expected_public_key" == "$REALITY_PUBLIC_KEY" ]] || \
      die "现有 REALITY 密钥对不匹配；已停止安装，避免生成无法连接的节点"
  fi
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "无法生成 REALITY 密钥"
}

make_certificate() {
  mkdir -p "$CERT_DIR"
  if [[ -n "${HY2_CERT_FILE:-}" || -n "${HY2_KEY_FILE:-}" ]]; then
    [[ -f "${HY2_CERT_FILE:-}" && -f "${HY2_KEY_FILE:-}" ]] || die "HY2_CERT_FILE 与 HY2_KEY_FILE 必须同时存在"
    local cert_source key_source
    cert_source="$(cd "$(dirname "$HY2_CERT_FILE")" && pwd -P)/$(basename "$HY2_CERT_FILE")"
    key_source="$(cd "$(dirname "$HY2_KEY_FILE")" && pwd -P)/$(basename "$HY2_KEY_FILE")"
    ln -sfn "$cert_source" "$CERT_DIR/server.crt"
    ln -sfn "$key_source" "$CERT_DIR/server.key"
    CERT_KIND="provided"
  elif [[ ! -s "$CERT_DIR/server.crt" || ! -s "$CERT_DIR/server.key" ]]; then
    local san="DNS:${HY2_SNI}"
    [[ "$HY2_SNI" =~ ^[0-9.]+$ || "$HY2_SNI" == *:* ]] && san="IP:${HY2_SNI}"
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
      -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
      -subj "/CN=${HY2_SNI}" -addext "subjectAltName=${san}" >/dev/null 2>&1
    CERT_KIND="self-signed"
  else
    CERT_KIND="${CERT_KIND:-self-signed}"
  fi
  if [[ "$CERT_KIND" == "self-signed" ]]; then
    chmod 600 "$CERT_DIR/server.crt" "$CERT_DIR/server.key"
  fi
  HY2_CERT_FINGERPRINT="$(openssl x509 -noout -fingerprint -sha256 -in "$CERT_DIR/server.crt" | cut -d= -f2)"
  HY2_PIN_SHA256="$HY2_CERT_FINGERPRINT"
  [[ -n "$HY2_PIN_SHA256" ]] || die "无法计算 HY2 证书指纹"
  [[ -n "$HY2_CERT_FINGERPRINT" ]] || die "无法计算 Mihomo 证书指纹"
}

check_reality_target() {
  if ! timeout 5 bash -c "</dev/tcp/${REALITY_SNI}/443" 2>/dev/null; then
    warn "本机无法连接 REALITY 目标 ${REALITY_SNI}:443；配置仍会生成，但建议更换可直连且支持 TLS 1.3 的域名"
  fi
}

write_config() {
  # Xray detects the configuration format from the final file extension.
  # Keep `.json` as the suffix while validating the candidate configuration.
  local candidate_config="${CONFIG_FILE%.json}.new.json"
  cat >"$candidate_config" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "vless-reality-tcp",
      "listen": "::",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision", "email": "primary"}],
        "decryption": "none"
      },
      "streamSettings": {
        "method": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "${REALITY_SNI}:443",
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
          "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
          "224.0.0.0/4", "240.0.0.0/4",
          "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
        ],
        "outboundTag": "block"
      },
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
    ]
  }
}
EOF
  "$XRAY_BIN" run -test -config "$candidate_config" || die "Xray 配置校验失败；旧配置未被覆盖"
  mv -f "$candidate_config" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

# A successful syntax check or TCP connect does not prove that a REALITY client
# can complete its handshake. Test the actual local listener before reporting success.
tcp_local_probe() (
  local work socks_port probe_pid='' code='' url
  work="$(mktemp -d)"
  trap 'if [[ -n "$probe_pid" ]]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
  socks_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

  python3 - "$work/client.json" "$socks_port" "$REALITY_PORT" "$UUID" \
    "$REALITY_SNI" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" <<'PY'
import json
import sys

path, socks_port, server_port, uuid, sni, public_key, short_id = sys.argv[1:]
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": int(socks_port),
                  "protocol": "socks", "settings": {"auth": "noauth"}}],
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "127.0.0.1", "port": int(server_port),
                               "users": [{"id": uuid, "encryption": "none",
                                          "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {
            "method": "raw", "security": "reality",
            "realitySettings": {"serverName": sni, "fingerprint": "chrome",
                                "password": public_key, "shortId": short_id}
        }
    }]
}
with open(path, "w", encoding="utf-8") as output:
    json.dump(config, output)
PY
  "$XRAY_BIN" run -test -config "$work/client.json" >/dev/null
  "$XRAY_BIN" run -config "$work/client.json" >"$work/client.log" 2>&1 &
  probe_pid=$!

  for ((i=0; i<25; i++)); do
    ss -lnt "( sport = :${socks_port} )" | grep -q 'LISTEN' && break
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.2
  done

  for url in https://www.gstatic.com/generate_204 https://www.cloudflare.com/cdn-cgi/trace; do
    if code="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
      --connect-timeout 5 --max-time 15 -sS -o /dev/null -w '%{http_code}' \
      "$url" 2>/dev/null)" && [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      ok "TCP REALITY 本机握手及 HTTPS 出站测试通过（HTTP ${code}）"
      return 0
    fi
  done
  warn "TCP REALITY 本机握手/出站测试失败；检查目标域名、密钥和 VPS 出站网络"
  tail -n 10 "$work/client.log" >&2 || true
  return 1
)

write_hy2_config() {
  local sni_guard="strict"
  [[ "$CERT_KIND" == "self-signed" ]] && sni_guard="disable"
  {
    cat <<EOF
listen: :${HY2_PORT}
tls:
  cert: ${CERT_DIR}/server.crt
  key: ${CERT_DIR}/server.key
  sniGuard: ${sni_guard}
auth:
  type: password
  password: ${HY2_PASSWORD}
EOF
    if [[ "$HY2_OBFS_MODE" == "salamander" ]]; then
      cat <<EOF
obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASSWORD}
EOF
    fi
    cat <<EOF
congestion:
  type: bbr
  bbrProfile: standard
udpIdleTimeout: 60s
EOF
    if [[ "$HY2_OBFS_MODE" == "none" ]]; then
      cat <<EOF
masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE_URL}
    rewriteHost: true
    insecure: false
    xForwarded: false
EOF
    fi
  } >"${HY2_CONFIG_FILE}.new"
  mv -f "${HY2_CONFIG_FILE}.new" "$HY2_CONFIG_FILE"
  chmod 600 "$HY2_CONFIG_FILE"
}

clash_tcp_proxy() {
  cat <<EOF
  - name: TCP-REALITY
    type: vless
    server: "${SERVER_ADDR}"
    port: ${REALITY_PORT}
    uuid: "${UUID}"
    network: tcp
    udp: true
    flow: xtls-rprx-vision
    packet-encoding: xudp
    tls: true
    servername: "${REALITY_SNI}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${REALITY_PUBLIC_KEY}"
      short-id: "${REALITY_SHORT_ID}"
EOF
}

clash_hy2_proxy() {
  cat <<EOF
  - name: HY2
    type: hysteria2
    server: "${SERVER_ADDR}"
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    sni: "${HY2_SNI}"
    skip-cert-verify: false
    alpn:
      - h3
EOF
  if [[ "$HY2_OBFS_MODE" == "salamander" ]]; then
    printf '    obfs: salamander\n'
    printf '    obfs-password: "%s"\n' "$HY2_OBFS_PASSWORD"
  fi
  if [[ "$CERT_KIND" == "self-signed" ]]; then
    printf '    fingerprint: "%s"\n' "$HY2_CERT_FINGERPRINT"
  fi
}

clash_header() {
  cat <<EOF
mixed-port: ${CLASH_MIXED_PORT}
allow-lan: false
mode: rule
log-level: info
ipv6: true
proxies:
EOF
}

write_subscription_files() {
  mkdir -p "$SUB_DIR"
  {
    clash_header
    clash_tcp_proxy
    cat <<'EOF'
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - TCP-REALITY
      - DIRECT
rules:
  - MATCH,PROXY
EOF
  } >"${SUB_DIR}/clash-tcp.yaml"

  {
    clash_header
    clash_hy2_proxy
    cat <<'EOF'
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - HY2
      - DIRECT
rules:
  - MATCH,PROXY
EOF
  } >"${SUB_DIR}/clash-hy2.yaml"

  {
    clash_header
    clash_tcp_proxy
    clash_hy2_proxy
    cat <<'EOF'
proxy-groups:
  - name: AUTO
    type: url-test
    proxies:
      - HY2
      - TCP-REALITY
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 80
    lazy: true
  - name: FAILOVER
    type: fallback
    proxies:
      - HY2
      - TCP-REALITY
    url: https://www.gstatic.com/generate_204
    interval: 60
    lazy: false
  - name: PROXY
    type: select
    proxies:
      - FAILOVER
      - AUTO
      - HY2
      - TCP-REALITY
      - DIRECT
rules:
  - MATCH,PROXY
EOF
  } >"${SUB_DIR}/clash-all.yaml"
  chmod 600 "${SUB_DIR}"/*.yaml

  SUB_TOKEN="${SUB_TOKEN:-$(openssl rand -hex 24)}"
  SUB_PORT="${SUB_PORT:-18080}"
  SUB_ENABLED="${SUB_ENABLED:-1}"
  valid_port "$SUB_PORT" || die "SUB_PORT 无效：$SUB_PORT"
  if [[ "$CERT_KIND" == "provided" ]]; then
    SUB_SCHEME="https"
    SUB_HOST="$HY2_SNI"
  else
    SUB_SCHEME="http"
    SUB_HOST="$SERVER_ADDR"
    warn "订阅服务将使用带随机路径的 HTTP；内容包含节点凭据。建议有域名后改用正式证书 HTTPS"
  fi

  cat >"$SUB_SERVER_FILE" <<'PY'
#!/usr/bin/env python3
import http.server
import os
import ssl
import sys
from urllib.parse import urlsplit

root, token, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
allowed = {"clash-tcp.yaml", "clash-hy2.yaml", "clash-all.yaml"}

class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        parts = urlsplit(self.path).path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != token or parts[1] not in allowed:
            self.send_error(404)
            return
        with open(os.path.join(root, parts[1]), "rb") as stream:
            self._send(stream.read())

    def do_HEAD(self):
        self.do_GET()

    def log_message(self, fmt, *args):
        return

server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
if len(sys.argv) == 6:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(sys.argv[4], sys.argv[5])
    server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
  chmod 700 "$SUB_SERVER_FILE"
}

write_unit() {
  local python_bin sub_exec tcp_was_active=0 hy2_was_active=0 sub_was_active=0
  systemctl is-active --quiet "${APP_NAME}.service" && tcp_was_active=1
  systemctl is-active --quiet "${APP_NAME}-hy2.service" && hy2_was_active=1
  systemctl is-active --quiet "${APP_NAME}-subscriptions.service" && sub_was_active=1
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=VLESS REALITY and Hysteria2 dual-entry service
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=read-only
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
  cat >"$HY2_UNIT_FILE" <<EOF
[Unit]
Description=Hysteria2 UDP entry for ${APP_NAME}
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_BIN} server -c ${HY2_CONFIG_FILE}
Restart=on-failure
RestartSec=3s
Nice=-5
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=read-only
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
  if [[ "$SUB_ENABLED" == 1 ]]; then
    python_bin="$(command -v python3)"
    sub_exec="${python_bin} ${SUB_SERVER_FILE} ${SUB_DIR} ${SUB_TOKEN} ${SUB_PORT}"
    if [[ "$SUB_SCHEME" == "https" ]]; then
      sub_exec+=" ${CERT_DIR}/server.crt ${CERT_DIR}/server.key"
    fi
    cat >"$SUB_UNIT_FILE" <<EOF
[Unit]
Description=Token-protected Clash subscription server for ${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${sub_exec}
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=read-only
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
  else
    systemctl disable --now "${APP_NAME}-subscriptions.service" >/dev/null 2>&1 || true
    rm -f "$SUB_UNIT_FILE"
  fi
  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}.service"
  (( tcp_was_active )) && systemctl restart "${APP_NAME}.service"
  systemctl enable --now "${APP_NAME}-hy2.service"
  (( hy2_was_active )) && systemctl restart "${APP_NAME}-hy2.service"
  if [[ "$SUB_ENABLED" == 1 ]]; then
    systemctl enable --now "${APP_NAME}-subscriptions.service"
    (( sub_was_active )) && systemctl restart "${APP_NAME}-subscriptions.service"
  fi
}

open_firewall() {
  UFW_TCP_ADDED="${UFW_TCP_ADDED:-0}"
  UFW_UDP_ADDED="${UFW_UDP_ADDED:-0}"
  FIREWALLD_TCP_ADDED="${FIREWALLD_TCP_ADDED:-0}"
  FIREWALLD_UDP_ADDED="${FIREWALLD_UDP_ADDED:-0}"
  SUB_UFW_ADDED="${SUB_UFW_ADDED:-0}"
  SUB_FIREWALLD_ADDED="${SUB_FIREWALLD_ADDED:-0}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${REALITY_PORT}/tcp([[:space:]]|$)"; then
      ufw allow "${REALITY_PORT}/tcp" comment "$APP_NAME" >/dev/null
      UFW_TCP_ADDED=1
    fi
    if ! ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${HY2_PORT}/udp([[:space:]]|$)"; then
      ufw allow "${HY2_PORT}/udp" comment "$APP_NAME" >/dev/null
      UFW_UDP_ADDED=1
    fi
    if [[ "$SUB_ENABLED" == 1 ]] && ! ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${SUB_PORT}/tcp([[:space:]]|$)"; then
      ufw allow "${SUB_PORT}/tcp" comment "$APP_NAME-subscriptions" >/dev/null
      SUB_UFW_ADDED=1
    fi
    ok "已添加 UFW 规则"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --permanent --query-port="${REALITY_PORT}/tcp" >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" >/dev/null
      FIREWALLD_TCP_ADDED=1
    fi
    if ! firewall-cmd --permanent --query-port="${HY2_PORT}/udp" >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${HY2_PORT}/udp" >/dev/null
      FIREWALLD_UDP_ADDED=1
    fi
    if [[ "$SUB_ENABLED" == 1 ]] && ! firewall-cmd --permanent --query-port="${SUB_PORT}/tcp" >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" >/dev/null
      SUB_FIREWALLD_ADDED=1
    fi
    firewall-cmd --reload >/dev/null
    ok "已添加 firewalld 规则"
  else
    warn "未检测到活动的 UFW/firewalld；请在 VPS 厂商安全组放行 TCP/${REALITY_PORT}、UDP/${HY2_PORT} 与订阅 TCP/${SUB_PORT}"
  fi
}

uri_host() {
  if [[ "$SERVER_ADDR" == *:* && "$SERVER_ADDR" != \[*\] ]]; then
    printf '[%s]' "$SERVER_ADDR"
  else
    printf '%s' "$SERVER_ADDR"
  fi
}

uri_encode() {
  local value="$1" out="" char hex i LC_ALL=C
  for ((i=0; i<${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) out+="$char" ;;
      *) printf -v hex '%%%02X' "'$char"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

write_shares() {
  local host insecure pin_arg sub_url_host obfs_arg
  host="$(uri_host)"
  insecure=0
  pin_arg=""
  obfs_arg=""
  if [[ "$CERT_KIND" == "self-signed" ]]; then
    insecure=1
    pin_arg="&pinSHA256=$(uri_encode "$HY2_PIN_SHA256")"
  fi
  if [[ "$HY2_OBFS_MODE" == "salamander" ]]; then
    obfs_arg="&obfs=salamander&obfs-password=$(uri_encode "$HY2_OBFS_PASSWORD")"
  fi
  cat >"$SHARE_FILE" <<EOF
VLESS-TCP-REALITY（主用）
vless://${UUID}@${host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#VPS-TCP-REALITY

Hysteria2（网络支持 UDP 时备用/加速）
hysteria2://${HY2_PASSWORD}@${host}:${HY2_PORT}/?sni=${HY2_SNI}&insecure=${insecure}${obfs_arg}${pin_arg}#VPS-HY2
EOF
  if [[ "$SUB_ENABLED" == 1 ]]; then
    sub_url_host="$SUB_HOST"
    [[ "$sub_url_host" == *:* && "$sub_url_host" != \[*\] ]] && sub_url_host="[$sub_url_host]"
    cat >>"$SHARE_FILE" <<EOF

Clash/Mihomo 订阅（请妥善保管随机路径）
TCP：${SUB_SCHEME}://${sub_url_host}:${SUB_PORT}/${SUB_TOKEN}/clash-tcp.yaml
HY2：${SUB_SCHEME}://${sub_url_host}:${SUB_PORT}/${SUB_TOKEN}/clash-hy2.yaml
自动选择+故障切换：${SUB_SCHEME}://${sub_url_host}:${SUB_PORT}/${SUB_TOKEN}/clash-all.yaml
EOF
  fi
  chmod 600 "$SHARE_FILE"
}

show_config() {
  require_root
  [[ -f "$STATE_FILE" && -f "$SHARE_FILE" ]] || die "尚未安装"
  load_state
  printf '\n%s\n\n' "$(cat "$SHARE_FILE")"
  printf 'TCP 服务：'; systemctl is-active "${APP_NAME}.service" || true
  printf 'HY2 服务：'; systemctl is-active "${APP_NAME}-hy2.service" || true
  if [[ "${SUB_ENABLED:-0}" == 1 ]]; then
    printf '订阅服务：'; systemctl is-active "${APP_NAME}-subscriptions.service" || true
  fi
  printf 'REALITY：TCP/%s，SNI=%s\n' "$REALITY_PORT" "$REALITY_SNI"
  printf 'HY2：UDP/%s，SNI=%s，证书=%s，混淆=%s\n' "$HY2_PORT" "$HY2_SNI" "$CERT_KIND" "$HY2_OBFS_MODE"
  printf 'TCP 拥塞控制：%s；队列：%s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
}

diagnose() {
  require_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  load_state
  echo "== service =="
  systemctl --no-pager --full status "${APP_NAME}.service" || true
  systemctl --no-pager --full status "${APP_NAME}-hy2.service" || true
  [[ "${SUB_ENABLED:-0}" == 1 ]] && systemctl --no-pager --full status "${APP_NAME}-subscriptions.service" || true
  echo "== listeners =="
  ss -lntup | awk -v tcp=":${REALITY_PORT}" -v udp=":${HY2_PORT}" 'NR==1 || index($0,tcp) || index($0,udp)'
  echo "== routes and MTU =="
  ip route show || true
  ip -br link || true
  echo "== kernel network counters =="
  if command -v nstat >/dev/null 2>&1; then
    nstat -az | grep -E 'TcpRetransSegs|TcpExtTCPTimeouts|IpInDiscards|IpOutDiscards|UdpInErrors|UdpRcvbufErrors|UdpSndbufErrors' || true
  fi
  ip -s link || true
  echo "== active TCP congestion/retransmission =="
  sysctl net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  ss -tin state established || true
  if command -v ping >/dev/null 2>&1; then
    echo "== short outbound loss sample (not the client path) =="
    ping -c 5 -W 1 1.1.1.1 || true
    ping -c 5 -W 1 8.8.8.8 || true
  fi
  echo "== config test =="
  "$XRAY_BIN" run -test -config "$CONFIG_FILE"
  echo "== recent log =="
  journalctl -u "${APP_NAME}.service" -n 30 --no-pager || true
  journalctl -u "${APP_NAME}-hy2.service" -n 30 --no-pager || true
  [[ "${SUB_ENABLED:-0}" == 1 ]] && journalctl -u "${APP_NAME}-subscriptions.service" -n 30 --no-pager || true
}

remove_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    [[ "${UFW_TCP_ADDED:-0}" == 1 ]] && ufw --force delete allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
    [[ "${UFW_UDP_ADDED:-0}" == 1 ]] && ufw --force delete allow "${HY2_PORT}/udp" >/dev/null 2>&1 || true
    [[ "${SUB_UFW_ADDED:-0}" == 1 ]] && ufw --force delete allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    [[ "${FIREWALLD_TCP_ADDED:-0}" == 1 ]] && firewall-cmd --permanent --remove-port="${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
    [[ "${FIREWALLD_UDP_ADDED:-0}" == 1 ]] && firewall-cmd --permanent --remove-port="${HY2_PORT}/udp" >/dev/null 2>&1 || true
    [[ "${SUB_FIREWALLD_ADDED:-0}" == 1 ]] && firewall-cmd --permanent --remove-port="${SUB_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

remove_old_firewall_if_ports_changed() {
  local old_tcp="$1" old_udp="$2" old_sub="${3:-}"
  if [[ -n "$old_tcp" && "$old_tcp" != "$REALITY_PORT" ]]; then
    if [[ "${UFW_TCP_ADDED:-0}" == 1 ]] && command -v ufw >/dev/null 2>&1; then
      ufw --force delete allow "${old_tcp}/tcp" >/dev/null 2>&1 || true
    fi
    if [[ "${FIREWALLD_TCP_ADDED:-0}" == 1 ]] && command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${old_tcp}/tcp" >/dev/null 2>&1 || true
    fi
    UFW_TCP_ADDED=0
    FIREWALLD_TCP_ADDED=0
  fi
  if [[ -n "$old_udp" && "$old_udp" != "$HY2_PORT" ]]; then
    if [[ "${UFW_UDP_ADDED:-0}" == 1 ]] && command -v ufw >/dev/null 2>&1; then
      ufw --force delete allow "${old_udp}/udp" >/dev/null 2>&1 || true
    fi
    if [[ "${FIREWALLD_UDP_ADDED:-0}" == 1 ]] && command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${old_udp}/udp" >/dev/null 2>&1 || true
    fi
    UFW_UDP_ADDED=0
    FIREWALLD_UDP_ADDED=0
  fi
  if [[ -n "$old_sub" && "$old_sub" != "$SUB_PORT" ]]; then
    if [[ "${SUB_UFW_ADDED:-0}" == 1 ]] && command -v ufw >/dev/null 2>&1; then
      ufw --force delete allow "${old_sub}/tcp" >/dev/null 2>&1 || true
    fi
    if [[ "${SUB_FIREWALLD_ADDED:-0}" == 1 ]] && command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${old_sub}/tcp" >/dev/null 2>&1 || true
    fi
    SUB_UFW_ADDED=0
    SUB_FIREWALLD_ADDED=0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

uninstall_app() {
  require_root
  load_state
  systemctl disable --now "${APP_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable --now "${APP_NAME}-hy2.service" >/dev/null 2>&1 || true
  systemctl disable --now "${APP_NAME}-subscriptions.service" >/dev/null 2>&1 || true
  [[ -n "${REALITY_PORT:-}" && -n "${HY2_PORT:-}" ]] && remove_firewall
  restore_network_tuning
  rm -f "$UNIT_FILE"
  rm -f "$HY2_UNIT_FILE"
  rm -f "$SUB_UNIT_FILE"
  rm -rf -- "$APP_DIR"
  systemctl daemon-reload
  ok "已移除 $APP_NAME 的服务、配置和防火墙规则；未删除可能共享的 Xray/Hysteria 核心"
}

install_app() {
  require_root
  install_dependencies
  mkdir -p "$APP_DIR"
  local https_url_re='^https://[A-Za-z0-9._:/?&=%+-]+$'
  local requested_reality_port="${REALITY_PORT-}"
  local requested_hy2_port="${HY2_PORT-}"
  local requested_reality_sni="${REALITY_SNI-}"
  local requested_hy2_sni="${HY2_SNI-}"
  local requested_hy2_obfs_mode="${HY2_OBFS_MODE-}"
  local requested_hy2_masquerade_url="${HY2_MASQUERADE_URL-}"
  local requested_hysteria_version="${HYSTERIA_VERSION-}"
  local requested_server_addr="${SERVER_ADDR-}"
  local requested_sub_port="${SUB_PORT-}"
  local requested_clash_mixed_port="${CLASH_MIXED_PORT-}"
  local requested_sub_enabled="${SUB_ENABLED-}"
  local requested_enable_bbr="${ENABLE_BBR-}"
  load_state
  local old_reality_port="${REALITY_PORT-}"
  local old_hy2_port="${HY2_PORT-}"
  local old_sub_port="${SUB_PORT-}"

  REALITY_PORT="${requested_reality_port:-${REALITY_PORT:-443}}"
  HY2_PORT="${requested_hy2_port:-${HY2_PORT:-443}}"
  REALITY_SNI="${requested_reality_sni:-${REALITY_SNI:-www.cloudflare.com}}"
  SERVER_ADDR="${requested_server_addr:-${SERVER_ADDR:-$(detect_server_addr)}}"
  HY2_SNI="${requested_hy2_sni:-${HY2_SNI:-$SERVER_ADDR}}"
  HY2_OBFS_MODE="${requested_hy2_obfs_mode:-${HY2_OBFS_MODE:-none}}"
  HY2_MASQUERADE_URL="${requested_hy2_masquerade_url:-${HY2_MASQUERADE_URL:-https://www.microsoft.com/}}"
  HYSTERIA_VERSION="${requested_hysteria_version:-${HYSTERIA_VERSION:-$DEFAULT_HYSTERIA_VERSION}}"
  SUB_PORT="${requested_sub_port:-${SUB_PORT:-18080}}"
  CLASH_MIXED_PORT="${requested_clash_mixed_port:-${CLASH_MIXED_PORT:-7897}}"
  SUB_ENABLED="${requested_sub_enabled:-${SUB_ENABLED:-1}}"
  ENABLE_BBR="${requested_enable_bbr:-${ENABLE_BBR:-1}}"
  SUB_TOKEN="${SUB_TOKEN:-$(openssl rand -hex 24)}"
  SUB_SCHEME="${SUB_SCHEME:-http}"
  SUB_HOST="${SUB_HOST:-$SERVER_ADDR}"
  CORE_MANAGED="${CORE_MANAGED:-0}"
  UFW_TCP_ADDED="${UFW_TCP_ADDED:-0}"
  UFW_UDP_ADDED="${UFW_UDP_ADDED:-0}"
  FIREWALLD_TCP_ADDED="${FIREWALLD_TCP_ADDED:-0}"
  FIREWALLD_UDP_ADDED="${FIREWALLD_UDP_ADDED:-0}"
  SUB_UFW_ADDED="${SUB_UFW_ADDED:-0}"
  SUB_FIREWALLD_ADDED="${SUB_FIREWALLD_ADDED:-0}"
  TUNING_MANAGED="${TUNING_MANAGED:-0}"
  PREV_QDISC="${PREV_QDISC:-}"
  PREV_CC="${PREV_CC:-}"
  PREV_RMEM="${PREV_RMEM:-}"
  PREV_WMEM="${PREV_WMEM:-}"

  valid_port "$REALITY_PORT" || die "REALITY_PORT 无效：$REALITY_PORT"
  valid_port "$HY2_PORT" || die "HY2_PORT 无效：$HY2_PORT"
  valid_port "$SUB_PORT" || die "SUB_PORT 无效：$SUB_PORT"
  valid_port "$CLASH_MIXED_PORT" || die "CLASH_MIXED_PORT 无效：$CLASH_MIXED_PORT"
  [[ "$SUB_ENABLED" == 0 || "$SUB_ENABLED" == 1 ]] || die "SUB_ENABLED 只能是 0 或 1"
  [[ "$ENABLE_BBR" == 0 || "$ENABLE_BBR" == 1 ]] || die "ENABLE_BBR 只能是 0 或 1"
  [[ "$HY2_OBFS_MODE" == "salamander" || "$HY2_OBFS_MODE" == "none" ]] || die "HY2_OBFS_MODE 只能是 salamander 或 none"
  [[ "$HY2_MASQUERADE_URL" =~ $https_url_re ]] || die "HY2_MASQUERADE_URL 必须是合法的 HTTPS URL"
  [[ "$REALITY_PORT" != "$HY2_PORT" ]] || info "TCP 与 UDP 共用数字端口 ${REALITY_PORT}（协议不同，不冲突）"
  valid_name "$REALITY_SNI" || die "REALITY_SNI 格式无效"
  valid_host "$HY2_SNI" || die "HY2_SNI 格式无效"
  [[ -n "$SERVER_ADDR" ]] || die "无法检测公网地址，请设置 SERVER_ADDR=你的IP或域名"
  remove_old_firewall_if_ports_changed "$old_reality_port" "$old_hy2_port" "$old_sub_port"

  install_xray
  install_hysteria
  make_keys
  make_certificate
  check_reality_target
  write_config
  write_hy2_config
  write_subscription_files
  write_unit
  open_firewall
  write_shares
  configure_network_tuning
  save_state

  systemctl is-active --quiet "${APP_NAME}.service" || {
    journalctl -u "${APP_NAME}.service" -n 30 --no-pager || true
    die "TCP REALITY 服务未能启动"
  }
  systemctl is-active --quiet "${APP_NAME}-hy2.service" || {
    journalctl -u "${APP_NAME}-hy2.service" -n 30 --no-pager || true
    die "HY2 服务未能启动"
  }
  if [[ "$SUB_ENABLED" == 1 ]]; then
    systemctl is-active --quiet "${APP_NAME}-subscriptions.service" || {
      journalctl -u "${APP_NAME}-subscriptions.service" -n 30 --no-pager || true
      die "订阅服务未能启动"
    }
  fi
  tcp_local_probe || die "TCP REALITY 实际连通性测试未通过；未将该节点标记为可用"
  ok "双入口部署完成"
  show_config
}

update_core() {
  require_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  FORCE_CORE_UPDATE=1
  install_dependencies
  load_state
  install_xray
  install_hysteria
  "$XRAY_BIN" run -test -config "$CONFIG_FILE"
  systemctl restart "${APP_NAME}.service"
  systemctl restart "${APP_NAME}-hy2.service"
  [[ "${SUB_ENABLED:-0}" == 1 ]] && systemctl restart "${APP_NAME}-subscriptions.service"
  ok "核心升级并重启完成：$($XRAY_BIN version | head -n1)；$($HYSTERIA_BIN version 2>&1 | head -n1 || true)"
}

usage() {
  cat <<'EOF'
用法：sudo bash RV_multi_HY2.sh [install|show|status|diagnose|restart|update|uninstall]

首次安装可用环境变量：
  REALITY_PORT=443 HY2_PORT=443
  REALITY_SNI=www.cloudflare.com HY2_SNI=你的HY2域名或VPS公网IP
  SERVER_ADDR=VPS公网IP或域名
  HY2_CERT_FILE=/证书/fullchain.pem HY2_KEY_FILE=/证书/privkey.pem
  HY2_OBFS_MODE=none HY2_MASQUERADE_URL=https://www.microsoft.com/
  ENABLE_BBR=1
  SUB_PORT=18080 SUB_ENABLED=1 CLASH_MIXED_PORT=7897

示例：
  sudo REALITY_PORT=443 HY2_PORT=443 bash RV_multi_HY2.sh install
EOF
}

case "$ACTION" in
  install)   install_app ;;
  show)      show_config ;;
  status)    require_root; load_state; systemctl --no-pager --full status "${APP_NAME}.service" "${APP_NAME}-hy2.service" || true; [[ "${SUB_ENABLED:-0}" == 1 ]] && systemctl --no-pager --full status "${APP_NAME}-subscriptions.service" || true ;;
  diagnose)  diagnose ;;
  restart)   require_root; load_state; systemctl restart "${APP_NAME}.service" "${APP_NAME}-hy2.service"; [[ "${SUB_ENABLED:-0}" == 1 ]] && systemctl restart "${APP_NAME}-subscriptions.service"; show_config ;;
  update)    update_core ;;
  uninstall) uninstall_app ;;
  help|-h)   usage ;;
  *)         usage; exit 2 ;;
esac

