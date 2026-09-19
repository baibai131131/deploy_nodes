#!/usr/bin/env bash
set -Eeuo pipefail

# Stable dual-stack proxy installer for Ubuntu/Debian VPS.
# Primary: VLESS + REALITY + TCP/443 (survives networks that block UDP/QUIC)
# Backup:  Hysteria2 + UDP/443
# One sing-box process serves both protocols; Clash/Mihomo uses automatic fallback.

readonly SCRIPT_VERSION="1.0.1"
readonly SING_BOX_VERSION="1.13.21"
readonly INSTALL_URL="https://sing-box.app/install.sh"
readonly STATE_DIR="/etc/stable-proxy"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="/root/STABLE_PROXY_INFO.txt"
readonly CLASH_FILE="/root/STABLE_PROXY_CLASH.yaml"
readonly URI_FILE="/root/STABLE_PROXY_LINKS.txt"
readonly SUB_DIR="/var/lib/stable-proxy-subscription"
readonly SUB_SERVER="/usr/local/sbin/stable-proxy-subscription.py"
readonly SUB_SERVICE="/etc/systemd/system/stable-proxy-subscription.service"
readonly MANAGER="/usr/local/sbin/stable-proxy"
readonly HEALTH_SCRIPT="/usr/local/sbin/stable-proxy-health-check"

PROXY_PORT=${PROXY_PORT:-443}
SUB_PORT=${SUB_PORT:-18080}
REALITY_TARGET=${REALITY_TARGET:-swdist.apple.com}
REALITY_SNI=${REALITY_SNI:-swdist.apple.com}
FORCE_REINSTALL=${FORCE_REINSTALL:-0}

log()  { printf '[信息] %s\n' "$*"; }
ok()   { printf '[成功] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$? line=${1:-unknown}
  printf '\n[错误] 安装在第 %s 行停止（退出码 %s）。\n' "$line" "$rc" >&2
  if systemctl list-unit-files sing-box.service >/dev/null 2>&1; then
    printf '[诊断] sing-box 最近日志：\n' >&2
    journalctl -u sing-box -n 60 --no-pager >&2 || true
  fi
  printf '[提示] 请保留完整输出；再次运行同一命令不会覆盖已完成的安装。\n' >&2
}
trap 'on_error "$LINENO"' ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行。"
}

validate_port() {
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
    *) die "仅支持 Ubuntu/Debian；当前为 ${PRETTY_NAME:-unknown}。" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "不支持的 CPU 架构：$(uname -m)。" ;;
  esac
  validate_port PROXY_PORT "$PROXY_PORT"
  validate_port SUB_PORT "$SUB_PORT"
  (( PROXY_PORT != SUB_PORT )) || die "PROXY_PORT 与 SUB_PORT 不能相同。"
  [[ $REALITY_TARGET =~ ^[A-Za-z0-9.-]+$ ]] || die "REALITY_TARGET 格式不正确。"
  [[ $REALITY_SNI =~ ^[A-Za-z0-9.-]+$ ]] || die "REALITY_SNI 格式不正确。"
}

already_installed() {
  # This function is called under `set -e`; a fresh installation is a normal
  # state and must not be reported as a command failure.
  [[ -f "$STATE_DIR/complete" ]] || return 0
  [[ $FORCE_REINSTALL == 1 ]] && return 0
  local version
  version=$(tr -d '[:space:]' <"$STATE_DIR/complete" 2>/dev/null || true)
  if [[ $version == "$SCRIPT_VERSION" ]] && \
     systemctl is-active --quiet sing-box && \
     ss -lntH "sport = :${PROXY_PORT}" 2>/dev/null | grep -q . && \
     ss -lunH "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
    ok "稳定双协议节点已经安装并正常运行。"
    cat "$INFO_FILE"
    exit 0
  fi
  warn "检测到旧版或不完整安装，将备份后修复。"
}

install_dependencies() {
  log "安装基础依赖……"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssl iproute2 python3 procps
}

backup_existing() {
  local stamp backup
  stamp=$(date +%Y%m%d_%H%M%S)
  backup="/root/stable-proxy-backup-${stamp}"
  install -d -m 700 "$backup"
  for path in \
    /etc/sing-box \
    /etc/hysteria \
    /root/VLESS_REALITY_INFO.txt \
    /root/VLESS_REALITY_CLASH.yaml \
    /root/STABLE_PROXY_INFO.txt \
    /root/STABLE_PROXY_CLASH.yaml; do
    [[ -e $path ]] && cp -a "$path" "$backup/" || true
  done
  printf '%s\n' "$backup" >"$STATE_DIR/last-backup"
  log "旧配置已备份到 ${backup}。"
}

stop_known_old_services() {
  log "停止会占用端口的旧版代理服务……"
  local unit
  for unit in \
    hysteria-server.service hysteria.service \
    sing-box.service vless-reality-subscription.service \
    stable-proxy-subscription.service \
    hy2-health-check.timer hy2-health-check.service \
    stable-proxy-health-check.timer stable-proxy-health-check.service; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  systemctl daemon-reload
  sleep 1
}

check_ports_free() {
  local failure=0
  if ss -lntH "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
    warn "TCP ${PROXY_PORT} 仍被其他程序占用："
    ss -lntp "sport = :${PROXY_PORT}" >&2 || true
    failure=1
  fi
  if ss -lunH "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
    warn "UDP ${PROXY_PORT} 仍被其他程序占用："
    ss -lunp "sport = :${PROXY_PORT}" >&2 || true
    failure=1
  fi
  if ss -lntH "sport = :${SUB_PORT}" 2>/dev/null | grep -q .; then
    warn "TCP ${SUB_PORT} 仍被其他程序占用："
    ss -lntp "sport = :${SUB_PORT}" >&2 || true
    failure=1
  fi
  (( failure == 0 )) || die "请先处理以上端口冲突，再重新运行脚本。"
}

install_sing_box() {
  local temp_dir installer installed
  temp_dir=$(mktemp -d)
  installer="${temp_dir}/install.sh"
  log "从 sing-box 官方源安装固定版本 ${SING_BOX_VERSION}……"
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    --connect-timeout 15 --max-time 180 "$INSTALL_URL" -o "$installer"
  sh "$installer" --version "$SING_BOX_VERSION"
  rm -rf -- "$temp_dir"
  command -v sing-box >/dev/null 2>&1 || die "官方安装完成后未找到 sing-box。"
  installed=$(sing-box version 2>&1 | awk 'NR==1 {print $3}')
  [[ $installed == "$SING_BOX_VERSION" ]] \
    || die "核心版本不符合预期：需要 ${SING_BOX_VERSION}，实际 ${installed:-unknown}。"
  ok "sing-box ${installed} 安装完成。"
}

get_public_ipv4() {
  local url value
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
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

check_reality_target() {
  local output
  log "检查 REALITY 目标 ${REALITY_TARGET}:443……"
  output=$(timeout 15 openssl s_client -connect "${REALITY_TARGET}:443" \
    -servername "$REALITY_SNI" </dev/null 2>&1 || true)
  grep -q 'CONNECTED' <<<"$output" || die "VPS 无法连接 REALITY 目标站点。"
}

generate_identity() {
  local uuid key_output private_key public_key short_id hy2_password hy2_obfs
  uuid=$(sing-box generate uuid)
  key_output=$(sing-box generate reality-keypair)
  private_key=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$key_output")
  public_key=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$key_output")
  short_id=$(openssl rand -hex 8)
  hy2_password=$(openssl rand -hex 24)
  hy2_obfs=$(openssl rand -hex 24)
  [[ $uuid =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 生成失败。"
  [[ -n $private_key && -n $public_key ]] || {
    printf '%s\n' "$key_output" >&2
    die "REALITY 密钥生成或解析失败。"
  }
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$uuid" "$private_key" "$public_key" "$short_id" "$hy2_password" "$hy2_obfs"
}

generate_hy2_certificate() {
  local ip=$1
  install -d -o root -g root -m 755 "$CONFIG_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -keyout "$CONFIG_DIR/hy2-key.pem" \
    -out "$CONFIG_DIR/hy2-cert.pem" \
    -subj "/CN=stable-proxy.invalid" \
    -addext "subjectAltName=DNS:stable-proxy.invalid,IP:${ip}" \
    >/dev/null 2>&1
  chown root:root "$CONFIG_DIR/hy2-key.pem" "$CONFIG_DIR/hy2-cert.pem"
  chmod 600 "$CONFIG_DIR/hy2-key.pem"
  chmod 644 "$CONFIG_DIR/hy2-cert.pem"
}

write_server_config() {
  local uuid=$1 private_key=$2 short_id=$3 hy2_password=$4 hy2_obfs=$5 temp_file
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
      "tag": "vless-reality-tcp-in",
      "listen": "0.0.0.0",
      "listen_port": ${PROXY_PORT},
      "tcp_keep_alive": "1m",
      "tcp_keep_alive_interval": "15s",
      "users": [
        {
          "name": "default",
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
    },
    {
      "type": "hysteria2",
      "tag": "hy2-udp-in",
      "listen": "0.0.0.0",
      "listen_port": ${PROXY_PORT},
      "obfs": {
        "type": "salamander",
        "password": "${hy2_obfs}"
      },
      "users": [
        {
          "name": "default",
          "password": "${hy2_password}"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "certificate_path": "${CONFIG_DIR}/hy2-cert.pem",
        "key_path": "${CONFIG_DIR}/hy2-key.pem"
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

configure_kernel() {
  local bbr_lines=""
  modprobe tcp_bbr 2>/dev/null || true
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && \
     grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    bbr_lines=$'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr'
  fi
  cat >/etc/sysctl.d/99-stable-proxy.conf <<EOF
# Conservative TCP keepalive and adequate UDP socket buffers.
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
net.core.rmem_max=16777216
net.core.wmem_max=16777216
${bbr_lines}
EOF
  sysctl --system >/dev/null
}

configure_service() {
  install -d -o root -g root -m 755 /etc/systemd/system/sing-box.service.d
  cat >/etc/systemd/system/sing-box.service.d/10-stable-proxy.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
OOMScoreAdjust=-500
TimeoutStopSec=15
EOF
  systemctl daemon-reload
  systemctl enable sing-box.service >/dev/null
  systemctl restart sing-box.service
  sleep 2
  systemctl is-active --quiet sing-box.service || {
    journalctl -u sing-box -n 80 --no-pager >&2
    die "sing-box 服务启动失败。"
  }
  ss -lntH "sport = :${PROXY_PORT}" | grep -q . \
    || die "没有检测到 TCP ${PROXY_PORT} 监听。"
  ss -lunH "sport = :${PROXY_PORT}" | grep -q . \
    || die "没有检测到 UDP ${PROXY_PORT} 监听。"
  ok "TCP ${PROXY_PORT} 和 UDP ${PROXY_PORT} 已同时监听。"
}

create_test_client() {
  local file=$1 socks_port=$2 outbound_json=$3
  cat >"$file" <<JSON
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "socks",
      "tag": "test-socks",
      "listen": "127.0.0.1",
      "listen_port": ${socks_port}
    }
  ],
  "outbounds": [${outbound_json}],
  "route": {"final": "test-out", "auto_detect_interface": true}
}
JSON
}

run_local_proxy_test() {
  local name=$1 config=$2 socks_port=$3 pid result=""
  sing-box check -c "$config"
  sing-box run -c "$config" >"${config}.log" 2>&1 &
  pid=$!
  for _ in {1..40}; do
    ss -lntH "sport = :${socks_port}" 2>/dev/null | grep -q . && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  result=$(curl -4fsS --socks5-hostname "127.0.0.1:${socks_port}" \
    --connect-timeout 8 --max-time 20 https://api.ipify.org 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if python3 - "$result" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
PY
  then
    ok "${name} 本机完整代理测试通过，出口 ${result}。"
  else
    warn "${name} 本机完整代理测试未通过。日志如下："
    sed -n '1,80p' "${config}.log" >&2 || true
    return 1
  fi
}

self_test_protocols() {
  local uuid=$1 public_key=$2 short_id=$3 hy2_password=$4 hy2_obfs=$5
  local test_dir vless_port hy2_port vless_out hy2_out
  test_dir=$(mktemp -d)
  vless_port=$((25000 + RANDOM % 5000))
  hy2_port=$((31000 + RANDOM % 5000))
  vless_out=$(cat <<JSON
{
  "type": "vless",
  "tag": "test-out",
  "server": "127.0.0.1",
  "server_port": ${PROXY_PORT},
  "uuid": "${uuid}",
  "flow": "xtls-rprx-vision",
  "network": "tcp",
  "multiplex": {"enabled": false},
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
JSON
)
  hy2_out=$(cat <<JSON
{
  "type": "hysteria2",
  "tag": "test-out",
  "server": "127.0.0.1",
  "server_port": ${PROXY_PORT},
  "password": "${hy2_password}",
  "obfs": {"type": "salamander", "password": "${hy2_obfs}"},
  "tls": {
    "enabled": true,
    "server_name": "stable-proxy.invalid",
    "insecure": true
  }
}
JSON
)
  create_test_client "$test_dir/vless.json" "$vless_port" "$vless_out"
  create_test_client "$test_dir/hy2.json" "$hy2_port" "$hy2_out"
  run_local_proxy_test "VLESS/REALITY/TCP" "$test_dir/vless.json" "$vless_port" \
    || die "TCP 主线路自检失败，拒绝交付无效节点。"
  run_local_proxy_test "Hysteria2/UDP" "$test_dir/hy2.json" "$hy2_port" \
    || die "UDP 备用线路自检失败，拒绝交付无效节点。"
  rm -rf -- "$test_dir"
}

write_client_files() {
  local ip=$1 uuid=$2 public_key=$3 short_id=$4 hy2_password=$5 hy2_obfs=$6
  local vless_uri hy2_uri
  vless_uri="vless://${uuid}@${ip}:${PROXY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-REALITY-TCP-443"
  hy2_uri="hysteria2://${hy2_password}@${ip}:${PROXY_PORT}/?insecure=1&obfs=salamander&obfs-password=${hy2_obfs}&sni=stable-proxy.invalid#HY2-UDP-443-BACKUP"

  cat >"$CLASH_FILE" <<YAML
mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
profile:
  store-selected: true

proxies:
  - name: VLESS-REALITY-TCP-443
    type: vless
    server: ${ip}
    port: ${PROXY_PORT}
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
    smux:
      enabled: false

  - name: HY2-UDP-443-BACKUP
    type: hysteria2
    server: ${ip}
    port: ${PROXY_PORT}
    password: ${hy2_password}
    obfs: salamander
    obfs-password: ${hy2_obfs}
    sni: stable-proxy.invalid
    skip-cert-verify: true
    udp: true

proxy-groups:
  - name: 稳定自动切换
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 60
    timeout: 8000
    lazy: false
    proxies:
      - VLESS-REALITY-TCP-443
      - HY2-UDP-443-BACKUP

  - name: 节点选择
    type: select
    proxies:
      - 稳定自动切换
      - VLESS-REALITY-TCP-443
      - HY2-UDP-443-BACKUP
      - DIRECT

rules:
  # Local/LAN traffic must never leave through the VPS.
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - MATCH,节点选择
YAML

  cat >"$URI_FILE" <<EOF
VLESS 主线路（TCP 443）：
${vless_uri}

HY2 备用线路（UDP 443）：
${hy2_uri}
EOF

  cat >"$INFO_FILE" <<EOF
安装器版本：${SCRIPT_VERSION}
核心版本：sing-box ${SING_BOX_VERSION}
VPS 公网 IPv4：${ip}

主线路：VLESS + REALITY + TCP ${PROXY_PORT}
备用线路：Hysteria2 + UDP ${PROXY_PORT}
Clash 策略：优先 TCP；检测失败后自动切到 HY2

本地文件：
Clash Verge / Mihomo：${CLASH_FILE}
两个单节点链接：${URI_FILE}

管理命令：
stable-proxy status   # 查看服务、双端口和资源
stable-proxy check    # 检查配置和运行状态
stable-proxy restart  # 手动重启服务
stable-proxy logs 100 # 查看最近100行日志
stable-proxy show     # 显示本文件

重要：Clash Verge 使用“规则”模式，并开启 TUN；不要同时运行第二个代理客户端。
EOF
  chmod 600 "$CLASH_FILE" "$URI_FILE" "$INFO_FILE"
}

install_subscription_service() {
  local ip=$1 token local_content base_url
  install -d -o root -g nogroup -m 750 "$SUB_DIR"
  token=$(openssl rand -hex 24)
  printf '%s\n' "$token" >"$SUB_DIR/token"
  install -o root -g nogroup -m 640 "$CLASH_FILE" "$SUB_DIR/clash.yaml"
  install -o root -g nogroup -m 640 "$URI_FILE" "$SUB_DIR/links.txt"
  chown root:nogroup "$SUB_DIR/token"
  chmod 640 "$SUB_DIR/token"

  cat >"$SUB_SERVER" <<'PY'
#!/usr/bin/env python3
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--port", type=int, required=True)
p.add_argument("--token-file", required=True)
p.add_argument("--directory", required=True)
a = p.parse_args()
token = Path(a.token_file).read_text(encoding="utf-8").strip()
directory = Path(a.directory)
files = {
    "clash.yaml": ("clash.yaml", "text/yaml; charset=utf-8"),
    "links.txt": ("links.txt", "text/plain; charset=utf-8"),
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].strip("/")
        parts = path.split("/")
        if len(parts) != 2 or parts[0] != token or parts[1] not in files:
            self.send_error(404)
            return
        filename, content_type = files[parts[1]]
        body = (directory / filename).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()
PY
  chmod 755 "$SUB_SERVER"

  cat >"$SUB_SERVICE" <<EOF
[Unit]
Description=Stable proxy subscription service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 ${SUB_SERVER} --port ${SUB_PORT} --token-file ${SUB_DIR}/token --directory ${SUB_DIR}
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
  systemctl enable --now stable-proxy-subscription.service >/dev/null
  systemctl restart stable-proxy-subscription.service
  sleep 1
  systemctl is-active --quiet stable-proxy-subscription.service \
    || die "订阅服务启动失败。"
  local_content=$(curl -fsS --max-time 5 \
    "http://127.0.0.1:${SUB_PORT}/${token}/clash.yaml")
  grep -q 'VLESS-REALITY-TCP-443' <<<"$local_content" \
    || die "订阅中的 TCP 节点验证失败。"
  grep -q 'HY2-UDP-443-BACKUP' <<<"$local_content" \
    || die "订阅中的 HY2 节点验证失败。"
  base_url="http://${ip}:${SUB_PORT}/${token}"
  cat >>"$INFO_FILE" <<EOF

Clash Verge 订阅地址：
${base_url}/clash.yaml

两个单节点链接：
${base_url}/links.txt
EOF
  chmod 600 "$INFO_FILE"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PROXY_PORT}/tcp" >/dev/null
    ufw allow "${PROXY_PORT}/udp" >/dev/null
    ufw allow "${SUB_PORT}/tcp" >/dev/null
    log "UFW 已放行 TCP/UDP ${PROXY_PORT} 和 TCP ${SUB_PORT}。"
  fi
}

install_health_check() {
  cat >"$HEALTH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
PORT=${PROXY_PORT}
LOG=/var/log/stable-proxy-health.log
NOW=\$(date '+%F %T')
STATE=OK

if ! systemctl is-active --quiet sing-box.service; then
  STATE=SERVICE_DOWN
elif ! ss -lntH "sport = :\${PORT}" 2>/dev/null | grep -q .; then
  STATE=TCP_SOCKET_MISSING
elif ! ss -lunH "sport = :\${PORT}" 2>/dev/null | grep -q .; then
  STATE=UDP_SOCKET_MISSING
fi

if [[ \$STATE != OK ]]; then
  echo "\$NOW | \$STATE | restarting sing-box" >>"\$LOG"
  systemctl restart sing-box.service
fi
EOF
  chmod 755 "$HEALTH_SCRIPT"

  cat >/etc/systemd/system/stable-proxy-health-check.service <<EOF
[Unit]
Description=Stable proxy socket health check
After=network-online.target sing-box.service

[Service]
Type=oneshot
ExecStart=${HEALTH_SCRIPT}
EOF

  cat >/etc/systemd/system/stable-proxy-health-check.timer <<'EOF'
[Unit]
Description=Check stable proxy sockets every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat >/etc/logrotate.d/stable-proxy <<'EOF'
/var/log/stable-proxy-health.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  systemctl daemon-reload
  systemctl enable --now stable-proxy-health-check.timer >/dev/null
}

configure_log_limit() {
  install -d -m 755 /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/stable-proxy-limit.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=7day
EOF
  systemctl restart systemd-journald
}

install_manager() {
  cat >"$MANAGER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
PORT=${PROXY_PORT}
CONFIG=${CONFIG_FILE}
INFO=${INFO_FILE}

case "\${1:-status}" in
  status)
    echo "===== 时间 ====="
    date
    echo "===== sing-box ====="
    systemctl is-active sing-box.service || true
    systemctl show sing-box.service -p NRestarts -p ActiveEnterTimestamp --no-pager
    echo "===== TCP \${PORT} ====="
    ss -lntp "sport = :\${PORT}" || true
    echo "===== UDP \${PORT} ====="
    ss -lunp "sport = :\${PORT}" || true
    echo "===== 订阅服务 ====="
    systemctl is-active stable-proxy-subscription.service || true
    echo "===== 最近日志 ====="
    journalctl -u sing-box.service -n 30 --no-pager
    echo "===== 资源 ====="
    uptime
    free -h
    df -h /
    ;;
  check)
    sing-box check -c "\$CONFIG"
    systemctl is-active --quiet sing-box.service
    ss -lntH "sport = :\${PORT}" | grep -q .
    ss -lunH "sport = :\${PORT}" | grep -q .
    echo "OK: 配置、服务、TCP和UDP监听正常"
    ;;
  restart)
    systemctl restart sing-box.service
    sleep 2
    "\$0" check
    ;;
  logs)
    journalctl -u sing-box.service -n "\${2:-100}" --no-pager
    ;;
  show)
    cat "\$INFO"
    ;;
  *)
    echo "用法：stable-proxy {status|check|restart|logs [行数]|show}" >&2
    exit 2
    ;;
esac
EOF
  chmod 755 "$MANAGER"
}

final_check() {
  sing-box check -c "$CONFIG_FILE"
  systemctl is-active --quiet sing-box.service
  systemctl is-active --quiet stable-proxy-subscription.service
  systemctl is-active --quiet stable-proxy-health-check.timer
  ss -lntH "sport = :${PROXY_PORT}" | grep -q .
  ss -lunH "sport = :${PROXY_PORT}" | grep -q .
  ss -lntH "sport = :${SUB_PORT}" | grep -q .
}

main() {
  require_root
  check_system
  install -d -o root -g root -m 700 "$STATE_DIR"
  already_installed

  printf '%s\n' "$SCRIPT_VERSION" >"$STATE_DIR/installing"
  install_dependencies
  backup_existing
  stop_known_old_services
  check_ports_free
  install_sing_box
  check_reality_target

  local public_ip identity uuid private_key public_key short_id hy2_password hy2_obfs
  public_ip=$(get_public_ipv4)
  mapfile -t identity < <(generate_identity)
  uuid=${identity[0]}
  private_key=${identity[1]}
  public_key=${identity[2]}
  short_id=${identity[3]}
  hy2_password=${identity[4]}
  hy2_obfs=${identity[5]}

  generate_hy2_certificate "$public_ip"
  write_server_config "$uuid" "$private_key" "$short_id" "$hy2_password" "$hy2_obfs"
  configure_kernel
  configure_service
  open_firewall
  self_test_protocols "$uuid" "$public_key" "$short_id" "$hy2_password" "$hy2_obfs"
  write_client_files "$public_ip" "$uuid" "$public_key" "$short_id" "$hy2_password" "$hy2_obfs"
  install_subscription_service "$public_ip"
  install_health_check
  configure_log_limit
  install_manager
  final_check

  printf '%s\n' "$SCRIPT_VERSION" >"$STATE_DIR/complete"
  rm -f "$STATE_DIR/installing"
  chmod 600 "$STATE_DIR/complete"

  printf '\n'
  ok "稳定双协议节点安装完成。"
  printf '\n'
  cat "$INFO_FILE"
  printf '\n'
  warn "请在 VPS 商家防火墙同时放行：TCP ${PROXY_PORT}、UDP ${PROXY_PORT}、TCP ${SUB_PORT}。"
  warn "有线网络若限制 UDP，Clash 会保持使用 TCP 主线路；HY2 只作为备用。"
  warn "没有任何脚本能保证上游线路、VPS IP 或 IOTA 服务绝对不故障。"
}

main "$@"
