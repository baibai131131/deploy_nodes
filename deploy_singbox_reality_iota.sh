#!/usr/bin/env bash
set -Eeuo pipefail

# Dedicated, single-protocol VPS installer for IOTA traffic.
# Transport: VLESS + REALITY + TCP + XTLS-Vision (sing-box core).

readonly SCRIPT_VERSION="1.0.0"
readonly SING_BOX_VERSION="1.13.21"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_DIR="/etc/iota-singbox-reality"
readonly INFO_FILE="/root/IOTA_SINGBOX_REALITY_INFO.txt"
readonly CLASH_FILE="/root/IOTA_SINGBOX_REALITY_CLASH.yaml"
readonly SUB_DIR="/var/lib/iota-singbox-subscription"
readonly SUB_SERVER="/usr/local/sbin/iota-singbox-subscription.py"
readonly SUB_SERVICE="/etc/systemd/system/iota-singbox-subscription.service"
readonly INSTALL_URL="https://sing-box.app/install.sh"

VLESS_PORT=${VLESS_PORT:-443}
SUB_PORT=${SUB_PORT:-18080}
REALITY_SNI=${REALITY_SNI:-www.apple.com}
REALITY_TARGET=${REALITY_TARGET:-www.apple.com}

log()  { printf '[信息] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$? line=${1:-unknown}
  printf '\n[错误] 安装在第 %s 行停止，退出码：%s\n' "$line" "$rc" >&2
  if systemctl list-unit-files sing-box.service >/dev/null 2>&1; then
    printf '[诊断] sing-box 最近日志：\n' >&2
    journalctl -u sing-box -n 60 --no-pager >&2 || true
  fi
  printf '[提示] 保留以上完整输出，下次运行同一命令可安全重新安装。\n' >&2
}
trap 'on_error "$LINENO"' ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行。"
}

validate_number() {
  local name=$1 value=$2
  [[ $value =~ ^[0-9]+$ ]] || die "${name} 必须是数字。"
  (( value >= 1 && value <= 65535 )) || die "${name} 必须在 1-65535 之间。"
}

check_system() {
  command -v systemctl >/dev/null 2>&1 || die "仅支持 systemd 系统。"
  [[ -r /etc/os-release ]] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "仅支持 Ubuntu/Debian；检测到 ${ID:-unknown}。" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "不支持的 CPU 架构：$(uname -m)。" ;;
  esac
  validate_number VLESS_PORT "$VLESS_PORT"
  validate_number SUB_PORT "$SUB_PORT"
  (( VLESS_PORT != SUB_PORT )) || die "VLESS_PORT 与 SUB_PORT 不能相同。"
  [[ $REALITY_SNI =~ ^[A-Za-z0-9.-]+$ ]] || die "REALITY_SNI 格式不正确。"
  [[ $REALITY_TARGET =~ ^[A-Za-z0-9.-]+$ ]] || die "REALITY_TARGET 格式不正确。"
}

refuse_conflicting_proxy() {
  if [[ -d /etc/hysteria ]] || pgrep -af '(^|/)(hysteria|xray)([[:space:]]|$)' >/dev/null 2>&1; then
    die "检测到 HY2/Hysteria 或 Xray 正在运行。此脚本只用于全新、单协议 VPS。"
  fi
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null \
      | grep -Eqi '(^|[[:space:]])(hysteria|xray)(@|\.|[[:space:]])'; then
    die "检测到 HY2/Hysteria 或 Xray 服务。请使用全新重装的 VPS。"
  fi
  if [[ -e "$CONFIG_FILE" && ! -d "$STATE_DIR" ]]; then
    die "检测到其他 sing-box 配置，为避免覆盖已停止安装。"
  fi
  if [[ -f "$STATE_DIR/complete" ]]; then
    log "本脚本管理的节点已经安装完成。"
    systemctl is-active --quiet sing-box || die "sing-box 当前未运行。"
    [[ -s "$INFO_FILE" ]] || die "节点信息文件缺失。"
    cat "$INFO_FILE"
    exit 0
  fi
}

prepare_resume() {
  install -d -o root -g root -m 700 "$STATE_DIR"
  printf '%s\n' "$SCRIPT_VERSION" >"$STATE_DIR/installing"
  systemctl stop sing-box 2>/dev/null || true
  systemctl stop iota-singbox-subscription 2>/dev/null || true
}

port_free() {
  local port=$1
  ! ss -lntH "sport = :${port}" 2>/dev/null | grep -q .
}

check_ports() {
  port_free "$VLESS_PORT" || die "TCP ${VLESS_PORT} 已被其他程序占用。"
  port_free "$SUB_PORT" || die "TCP ${SUB_PORT} 已被其他程序占用。"
}

install_dependencies() {
  log "安装基础依赖……"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssl iproute2 python3
}

check_reality_target() {
  log "检查 REALITY 目标站点 ${REALITY_TARGET}:443……"
  local result
  result=$(timeout 12 openssl s_client \
    -connect "${REALITY_TARGET}:443" \
    -servername "$REALITY_SNI" </dev/null 2>&1 || true)
  grep -q 'CONNECTED' <<<"$result" || die "VPS 无法连接 REALITY 目标站点。"
  grep -Eq 'Verify return code: 0 \(ok\)' <<<"$result" \
    || die "REALITY 目标站点证书校验失败。"
}

install_sing_box() {
  local temp_dir installer installed
  temp_dir=$(mktemp -d)
  installer="$temp_dir/install.sh"
  curl -fL --retry 3 --connect-timeout 15 "$INSTALL_URL" -o "$installer"
  sh "$installer" --version "$SING_BOX_VERSION"
  rm -rf -- "$temp_dir"
  command -v sing-box >/dev/null 2>&1 || die "官方安装程序完成后未找到 sing-box。"
  installed=$(sing-box version 2>&1 | awk 'NR==1 {print $3}')
  [[ $installed == "$SING_BOX_VERSION" ]] \
    || die "sing-box 版本不符合预期：需要 ${SING_BOX_VERSION}，实际 ${installed:-unknown}。"
  log "sing-box ${installed} 安装完成。"
}

get_public_ipv4() {
  local url value
  for url in \
    https://api.ipify.org \
    https://ipv4.icanhazip.com \
    https://ifconfig.me/ip; do
    value=$(curl -4fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if python3 - "$value" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
PY
    then
      printf '%s' "$value"
      return
    fi
  done
  die "无法取得 VPS 公网 IPv4。"
}

generate_identity() {
  local key_output uuid private_key public_key short_id
  uuid=$(sing-box generate uuid)
  key_output=$(sing-box generate reality-keypair)
  private_key=$(awk -F': *' '/Private[Kk]ey|Private key/ {print $2; exit}' <<<"$key_output")
  public_key=$(awk -F': *' '/Public[Kk]ey|Public key/ {print $2; exit}' <<<"$key_output")
  short_id=$(openssl rand -hex 8)
  [[ $uuid =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 生成失败。"
  [[ -n $private_key && -n $public_key ]] || {
    printf '%s\n' "$key_output" >&2
    die "REALITY 密钥生成或解析失败。"
  }
  printf '%s\n%s\n%s\n%s\n' "$uuid" "$private_key" "$public_key" "$short_id"
}

write_server_config() {
  local uuid=$1 private_key=$2 short_id=$3 temp_file
  install -d -o root -g root -m 755 "$CONFIG_DIR"
  temp_file=$(mktemp "${CONFIG_DIR}/config.json.XXXXXX")
  cat >"$temp_file" <<JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "iota-vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_PORT},
      "tcp_keep_alive": "2m",
      "tcp_keep_alive_interval": "30s",
      "users": [
        {
          "name": "iota",
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_TARGET}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": ["${short_id}"],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "auto_detect_interface": true
  }
}
JSON
  sing-box check -c "$temp_file"
  chown root:root "$temp_file"
  chmod 600 "$temp_file"
  mv -f "$temp_file" "$CONFIG_FILE"
}

configure_service() {
  install -d -o root -g root -m 755 /etc/systemd/system/sing-box.service.d
  cat >/etc/systemd/system/sing-box.service.d/iota-stability.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || {
    journalctl -u sing-box -n 80 --no-pager >&2
    die "sing-box 服务启动失败。"
  }
  ss -lntH "sport = :${VLESS_PORT}" | grep -q . || die "sing-box 未监听 TCP ${VLESS_PORT}。"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${VLESS_PORT}/tcp" >/dev/null
    ufw allow "${SUB_PORT}/tcp" >/dev/null
    log "UFW 已放行 TCP ${VLESS_PORT} 和 ${SUB_PORT}。"
  fi
}

self_test_reality() {
  local uuid=$1 public_key=$2 short_id=$3
  local test_dir socks_port client_pid result
  test_dir=$(mktemp -d)
  for _ in {1..30}; do
    socks_port=$((20000 + RANDOM % 20000))
    port_free "$socks_port" && break
  done
  port_free "$socks_port" || die "无法找到 REALITY 自检端口。"
  cat >"$test_dir/client.json" <<JSON
{
  "log": {"level": "debug", "timestamp": true},
  "inbounds": [
    {
      "type": "socks",
      "tag": "test-socks",
      "listen": "127.0.0.1",
      "listen_port": ${socks_port}
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "test-proxy",
      "server": "127.0.0.1",
      "server_port": ${VLESS_PORT},
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "${public_key}",
          "short_id": "${short_id}"
        }
      }
    }
  ],
  "route": {
    "final": "test-proxy",
    "auto_detect_interface": true
  }
}
JSON
  sing-box check -c "$test_dir/client.json"
  sing-box run -c "$test_dir/client.json" >"$test_dir/client.log" 2>&1 &
  client_pid=$!
  for _ in {1..40}; do
    ss -lntH "sport = :${socks_port}" 2>/dev/null | grep -q . && break
    kill -0 "$client_pid" 2>/dev/null || break
    sleep 0.1
  done
  result=$(curl -4fsS --socks5-hostname "127.0.0.1:${socks_port}" \
    --connect-timeout 10 --max-time 25 https://api.ipify.org 2>/dev/null || true)
  kill "$client_pid" 2>/dev/null || true
  wait "$client_pid" 2>/dev/null || true
  if ! python3 - "$result" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
PY
  then
    warn "===== REALITY 客户端自检日志 ====="
    cat "$test_dir/client.log" >&2 || true
    warn "===== REALITY 服务端日志 ====="
    journalctl -u sing-box -n 80 --no-pager >&2 || true
    rm -rf -- "$test_dir"
    die "REALITY 真实代理出口测试失败，不会输出不可用订阅。"
  fi
  rm -rf -- "$test_dir"
  log "REALITY 真实代理出口测试通过：${result}"
}

write_client_files() {
  local ip=$1 uuid=$2 public_key=$3 short_id=$4
  local vless_link
  vless_link="vless://${uuid}@${ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#IOTA-SINGBOX-REALITY"
  cat >"$CLASH_FILE" <<YAML
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
tcp-concurrent: true
profile:
  store-selected: true

proxies:
  - name: IOTA-SINGBOX-REALITY
    type: vless
    server: ${ip}
    port: ${VLESS_PORT}
    uuid: ${uuid}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
    client-fingerprint: chrome
    packet-encoding: xudp

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - IOTA-SINGBOX-REALITY

rules:
  - MATCH,节点选择
YAML
  cat >"$INFO_FILE" <<EOF
安装器版本：${SCRIPT_VERSION}
核心版本：sing-box ${SING_BOX_VERSION}
协议：VLESS + REALITY + TCP + XTLS-Vision
VPS公网IPv4：${ip}
端口：${VLESS_PORT}/TCP
REALITY SNI：${REALITY_SNI}

VLESS分享链接：
${vless_link}

Clash配置文件：${CLASH_FILE}
EOF
  chmod 600 "$CLASH_FILE" "$INFO_FILE"
}

install_subscription_service() {
  local ip=$1 token subscription_url local_content
  install -d -o root -g www-data -m 750 "$SUB_DIR"
  token=$(openssl rand -hex 24)
  printf '%s\n' "$token" >"$SUB_DIR/token"
  install -o root -g www-data -m 640 "$CLASH_FILE" "$SUB_DIR/config.yaml"
  chown root:www-data "$SUB_DIR/token"
  chmod 640 "$SUB_DIR/token"
  cat >"$SUB_SERVER" <<'PY'
#!/usr/bin/env python3
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--port", type=int, required=True)
p.add_argument("--token-file", required=True)
p.add_argument("--config", required=True)
a = p.parse_args()
token = Path(a.token_file).read_text(encoding="utf-8").strip()
config = Path(a.config)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/" + token:
            self.send_error(404)
            return
        body = config.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()
PY
  chmod 755 "$SUB_SERVER"
  cat >"$SUB_SERVICE" <<EOF
[Unit]
Description=IOTA sing-box Clash subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/python3 ${SUB_SERVER} --port ${SUB_PORT} --token-file ${SUB_DIR}/token --config ${SUB_DIR}/config.yaml
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now iota-singbox-subscription.service >/dev/null
  systemctl restart iota-singbox-subscription.service
  sleep 1
  systemctl is-active --quiet iota-singbox-subscription.service \
    || die "Clash 订阅服务启动失败。"
  local_content=$(curl -fsS --max-time 5 "http://127.0.0.1:${SUB_PORT}/${token}")
  grep -q 'IOTA-SINGBOX-REALITY' <<<"$local_content" \
    || die "Clash 订阅内容本机验证失败。"
  subscription_url="http://${ip}:${SUB_PORT}/${token}"
  printf '\nClash Verge/Mihomo订阅链接：\n%s\n' "$subscription_url" >>"$INFO_FILE"
  chmod 600 "$INFO_FILE"
  printf '%s' "$subscription_url"
}

finish_install() {
  local subscription_url=$1
  printf '%s\n' "$SCRIPT_VERSION" >"$STATE_DIR/complete"
  rm -f "$STATE_DIR/installing"
  chmod 600 "$STATE_DIR/complete"
  printf '\n===== 全部安装与自检成功 =====\n'
  printf 'sing-box状态：active\n'
  printf '协议端口：%s/TCP\n' "$VLESS_PORT"
  printf 'Clash订阅：%s\n' "$subscription_url"
  printf '节点资料：%s\n' "$INFO_FILE"
  printf '\n请先在 Clash Verge 导入订阅并测试延迟；旧节点先不要删除。\n'
  printf '如果外部显示 Timeout，请检查 VPS 商家防火墙是否放行 TCP %s 和 %s。\n' \
    "$VLESS_PORT" "$SUB_PORT"
}

main() {
  local ip uuid private_key public_key short_id subscription_url
  local -a identity
  require_root
  check_system
  refuse_conflicting_proxy
  log "IOTA 专用 sing-box Reality 安装器 v${SCRIPT_VERSION}"
  log "仅安装一种协议，不安装 HY2、Argo、WARP、Xray 或管理面板。"
  prepare_resume
  install_dependencies
  check_ports
  check_reality_target
  install_sing_box
  systemctl stop sing-box 2>/dev/null || true
  check_ports
  ip=$(get_public_ipv4)
  mapfile -t identity < <(generate_identity)
  [[ ${#identity[@]} -eq 4 ]] || die "身份参数生成不完整。"
  uuid=${identity[0]}
  private_key=${identity[1]}
  public_key=${identity[2]}
  short_id=${identity[3]}
  write_server_config "$uuid" "$private_key" "$short_id"
  configure_service
  open_firewall
  self_test_reality "$uuid" "$public_key" "$short_id"
  write_client_files "$ip" "$uuid" "$public_key" "$short_id"
  subscription_url=$(install_subscription_service "$ip")
  finish_install "$subscription_url"
}

main "$@"
