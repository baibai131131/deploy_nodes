#!/usr/bin/env bash
set -Eeuo pipefail

# VLESS + REALITY + TCP + XTLS-Vision installer for a dedicated VPS.
# Safety rule: this script refuses to install on a VPS that already runs Hysteria/HY2.

readonly SCRIPT_VERSION="1.0.0"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly STATE_DIR="/etc/vless-reality-iota"
readonly INFO_FILE="/root/VLESS_REALITY_INFO.txt"
readonly CLASH_FILE="/root/VLESS_REALITY_CLASH.yaml"
readonly INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

log() { printf '[信息] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行。"
}

check_system() {
  command -v systemctl >/dev/null 2>&1 || die "仅支持使用 systemd 的 VPS。"
  [[ -r /etc/os-release ]] || die "无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "当前仅支持 Ubuntu/Debian；检测到：${ID:-unknown}" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "不支持的CPU架构：$(uname -m)" ;;
  esac
}

refuse_hy2_vps() {
  local found=0
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -Eqi '(^|[[:space:]])(hysteria|hy2)'; then
    found=1
  fi
  if pgrep -af '(^|/)(hysteria)([[:space:]]|$)' >/dev/null 2>&1; then
    found=1
  fi
  if [[ -d /etc/hysteria ]]; then
    found=1
  fi
  if (( found )); then
    die "检测到本机存在 HY2/Hysteria。按一台VPS只运行一种协议的要求，本脚本拒绝安装。请换一台全新VPS。"
  fi
}

refuse_existing_xray() {
  if [[ -e "$XRAY_CONFIG" || -d "$STATE_DIR" ]]; then
    die "检测到已有 Xray/VLESS 配置。为避免覆盖现有节点，本脚本已停止。"
  fi
}

tcp_port_free() {
  local port=$1
  ! ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
}

choose_port() {
  local requested=${VLESS_PORT:-443}
  [[ $requested =~ ^[0-9]+$ ]] || die "VLESS_PORT 必须是数字。"
  (( requested >= 1 && requested <= 65535 )) || die "VLESS_PORT 必须在 1-65535 之间。"
  tcp_port_free "$requested" || die "TCP端口 $requested 已被占用。请使用全新VPS，或运行 VLESS_PORT=其他端口 再安装。"
  printf '%s' "$requested"
}

install_dependencies() {
  log "安装基础依赖……"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl openssl iproute2
}

install_xray() {
  local temp_dir installer
  temp_dir=$(mktemp -d)
  installer="$temp_dir/install-release.sh"
  trap 'rm -rf -- "$temp_dir"' RETURN
  curl -fL --retry 3 --connect-timeout 10 "$INSTALLER_URL" -o "$installer"
  bash "$installer" install
  [[ -x /usr/local/bin/xray ]] || die "Xray官方安装程序执行后未找到主程序。"
  trap - RETURN
  rm -rf -- "$temp_dir"
}

get_public_ip() {
  local ip=''
  ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  fi
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "无法自动获取VPS公网IPv4。"
  printf '%s' "$ip"
}

generate_keys() {
  local output private public
  output=$(/usr/local/bin/xray x25519)
  private=$(awk -F': *' '/Private[Kk]ey|Private key/ {print $2; exit}' <<<"$output")
  public=$(awk -F': *' '/Public[Kk]ey|Public key|Password/ {print $2; exit}' <<<"$output")
  [[ -n $private && -n $public ]] || die "无法解析 Xray REALITY 密钥。"
  printf '%s\n%s\n' "$private" "$public"
}

write_config() {
  local port=$1 uuid=$2 private_key=$3 short_id=$4 target=$5 sni=$6
  install -d -m 700 "$STATE_DIR"
  install -d -m 755 "$(dirname "$XRAY_CONFIG")"

  cat >"$XRAY_CONFIG" <<JSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-iota",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision",
            "email": "iota"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${target}",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "minClientVer": "1.8.2",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
JSON
  chmod 600 "$XRAY_CONFIG"
}

enable_bbr() {
  if modprobe tcp_bbr >/dev/null 2>&1 || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    cat >/etc/sysctl.d/99-vless-reality-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
    sysctl -q -p /etc/sysctl.d/99-vless-reality-bbr.conf || warn "BBR参数未完全生效，但不影响VLESS运行。"
  else
    warn "当前内核不支持BBR，将继续使用系统默认TCP拥塞控制。"
  fi
}

open_firewall() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null
    log "已在UFW放行 TCP ${port}。"
  fi
}

write_client_files() {
  local ip=$1 port=$2 uuid=$3 public_key=$4 short_id=$5 sni=$6
  local name="IOTA-VLESS-REALITY"
  local uri="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${name}"

  cat >"$CLASH_FILE" <<YAML
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
tcp-concurrent: true

proxies:
  - name: "${name}"
    type: vless
    server: ${ip}
    port: ${port}
    uuid: ${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}

proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - "${name}"

rules:
  - MATCH,节点选择
YAML

  cat >"$INFO_FILE" <<INFO
VLESS + REALITY + TCP + XTLS-Vision
节点名称：${name}
服务器：${ip}
端口：${port}/TCP
SNI：${sni}

VLESS导入链接：
${uri}

Clash/Mihomo配置文件：
${CLASH_FILE}

查看服务：systemctl status xray --no-pager -l
查看日志：journalctl -u xray -f
INFO

  chmod 600 "$CLASH_FILE" "$INFO_FILE"
  cp "$INFO_FILE" "$STATE_DIR/info.txt"
  chmod 600 "$STATE_DIR/info.txt"
}

main() {
  require_root
  check_system
  refuse_hy2_vps
  refuse_existing_xray

  local port target sni ip uuid short_id private_key public_key
  local -a keys
  port=$(choose_port)
  target=${REALITY_TARGET:-www.microsoft.com:443}
  sni=${REALITY_SNI:-${target%:*}}

  [[ $target == *:* ]] || die "REALITY_TARGET 格式应为 域名:443。"
  [[ $sni =~ ^[A-Za-z0-9.-]+$ ]] || die "REALITY_SNI 格式不正确。"

  log "专用VLESS VPS安装器 v${SCRIPT_VERSION}"
  log "检测到任何HY2时会自动停止，本脚本不会与HY2共存。"
  install_dependencies
  install_xray

  ip=$(get_public_ip)
  uuid=$(/usr/local/bin/xray uuid)
  short_id=$(openssl rand -hex 8)
  mapfile -t keys < <(generate_keys)
  private_key=${keys[0]}
  public_key=${keys[1]}

  write_config "$port" "$uuid" "$private_key" "$short_id" "$target" "$sni"
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG"
  enable_bbr
  open_firewall "$port"

  systemctl enable xray >/dev/null
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 80 --no-pager >&2
    die "Xray启动失败，请保留上方日志。"
  }

  write_client_files "$ip" "$port" "$uuid" "$public_key" "$short_id" "$sni"

  printf '\n===== 安装成功 =====\n'
  /usr/local/bin/xray version | head -1
  printf '协议：VLESS + REALITY + TCP + XTLS-Vision\n'
  printf '端口：%s/TCP\n' "$port"
  printf 'Clash配置：%s\n' "$CLASH_FILE"
  printf '节点信息：%s\n\n' "$INFO_FILE"
  cat "$INFO_FILE"
  printf '\n重要：请妥善保管以上链接和配置，里面含有节点凭证。\n'
}

main "$@"
