#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="4.0"
HY2_PORT="443"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

echo "===== HY2 IOTA Stable Installer v${SCRIPT_VERSION} ====="
echo "默认协议端口：UDP ${HY2_PORT}"
echo "===== 安装前检查 ====="
if [ -f /etc/hysteria/config.yaml ] || [ -f /etc/hysteria/config.yml ]; then
  echo "❌ 检测到这台 VPS 已存在 HY2 配置。"
  echo "为避免覆盖现有密码、证书和 Clash 订阅，本脚本只允许在全新 VPS 使用。"
  exit 1
fi

. /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  echo "❌ 仅支持 Ubuntu，当前系统：${PRETTY_NAME:-未知}"
  exit 1
fi

echo "===== 安装基础依赖 ====="
apt-get update
apt-get install -y ca-certificates curl cron iproute2 openssl procps util-linux
systemctl enable --now cron

if ss -Hlunp "sport = :${HY2_PORT}" 2>/dev/null | grep -q .; then
  echo "❌ UDP ${HY2_PORT} 已被其他程序占用："
  ss -Hlunp "sport = :${HY2_PORT}" || true
  echo "请先处理端口冲突后再安装。"
  exit 1
fi

echo "===== 低内存 VPS 自动配置 Swap ====="
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$MEM_KB" -lt 1572864 ] && ! swapon --show --noheadings | grep -q .; then
  if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "✅ 已配置 1GB Swap"
else
  echo "✅ 内存或现有 Swap 已满足要求"
fi

# 固定到已检查的 GitHub 提交，避免远程分支后续变化
COMMIT="ced2592cd44ae634a18fe5dae3df1b414fb8aa99"
SOURCE_URL="https://raw.githubusercontent.com/zhangc536/ritual-ubuntn/${COMMIT}/hy2.sh"
TMP_SCRIPT="$(mktemp /tmp/hy2-pinned.XXXXXX.sh)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

echo "===== 下载固定版本 HY2 脚本 ====="
curl --proto '=https' --tlsv1.2 -fL --connect-timeout 15 --max-time 120 "$SOURCE_URL" -o "$TMP_SCRIPT"
chmod 700 "$TMP_SCRIPT"

grep -q 'setup_auto_reboot_cron' "$TMP_SCRIPT"
grep -q 'hysteria-server.service' "$TMP_SCRIPT"
grep -q 'generate_self_signed_cert' "$TMP_SCRIPT"
grep -q -- '-days 365 ' "$TMP_SCRIPT"

# 新安装证书由365天改为3650天
sed -i 's/-days 365 /-days 3650 /g' "$TMP_SCRIPT"

echo "===== 删除可能存在的自动重启任务 ====="
STAMP="$(date +%Y%m%d_%H%M%S)"
CRON_BACKUP="/root/crontab_before_hy2_install_${STAMP}.txt"
CRON_TMP="$(mktemp)"
crontab -l 2>/dev/null > "$CRON_BACKUP" || true
awk '
{
  line=$0
  if (line ~ /\/proc\/sys\/vm\/drop_caches/ &&
      (line ~ /shutdown[[:space:]].*-r/ || line ~ /reboot/)) next
  print
}
' "$CRON_BACKUP" > "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

echo "===== 安装 HY2：禁用每日重启 ====="
SCRIPT_MODE=1 ENABLE_AUTO_REBOOT_CACHE=0 bash "$TMP_SCRIPT"

echo "===== 固定 HY2 为 UDP ${HY2_PORT} 并同步 Clash 订阅 ====="
SERVER_CONFIG="/etc/hysteria/config.yaml"
CLASH_SUBSCRIPTION="/etc/hysteria/clash_subscription.yaml"

if [ ! -f "$SERVER_CONFIG" ] || [ ! -f "$CLASH_SUBSCRIPTION" ]; then
  echo "❌ 上游安装脚本没有生成预期配置文件，停止修改。"
  echo "服务端配置：$SERVER_CONFIG"
  echo "Clash订阅：$CLASH_SUBSCRIPTION"
  exit 1
fi

if ! grep -Eq '^[[:space:]]*auth:' "$SERVER_CONFIG" ||
   ! grep -Eq '^[[:space:]]*obfs:' "$SERVER_CONFIG"; then
  echo "❌ 服务端配置缺少认证或混淆设置，为避免部署开放代理，停止安装。"
  exit 1
fi

GENERATED_BACKUP="/root/hy2_generated_config_before_v${SCRIPT_VERSION}_${STAMP}"
mkdir -p "$GENERATED_BACKUP"
cp -a "$SERVER_CONFIG" "$CLASH_SUBSCRIPTION" "$GENERATED_BACKUP/"

# 只修改明确的 YAML 字段，避免误改密码、证书或其他数字。
sed -Ei "s|^([[:space:]]*listen:[[:space:]]*):?[0-9]+[[:space:]]*$|\1:${HY2_PORT}|" "$SERVER_CONFIG"
sed -Ei "s|^([[:space:]]*port:[[:space:]]*)[0-9]+[[:space:]]*$|\1${HY2_PORT}|" "$CLASH_SUBSCRIPTION"
sed -Ei 's|^([[:space:]]*- name:[[:space:]]*)"?[0-9]+"?[[:space:]]*$|\1"HY2-UDP-443"|' "$CLASH_SUBSCRIPTION"
sed -Ei 's|^([[:space:]]*-[[:space:]]*)"8443"[[:space:]]*$|\1"HY2-UDP-443"|' "$CLASH_SUBSCRIPTION"

if ! grep -Eq "^[[:space:]]*listen:[[:space:]]*:${HY2_PORT}[[:space:]]*$" "$SERVER_CONFIG"; then
  echo "❌ 服务端端口修改失败，正在恢复原配置。"
  cp -a "$GENERATED_BACKUP/config.yaml" "$SERVER_CONFIG"
  cp -a "$GENERATED_BACKUP/clash_subscription.yaml" "$CLASH_SUBSCRIPTION"
  exit 1
fi
if ! grep -Eq "^[[:space:]]*port:[[:space:]]*${HY2_PORT}[[:space:]]*$" "$CLASH_SUBSCRIPTION"; then
  echo "❌ Clash订阅端口修改失败，正在恢复原配置。"
  cp -a "$GENERATED_BACKUP/config.yaml" "$SERVER_CONFIG"
  cp -a "$GENERATED_BACKUP/clash_subscription.yaml" "$CLASH_SUBSCRIPTION"
  exit 1
fi

# 只在 UFW 已启用时添加规则；云厂商安全组仍需在控制台放行 UDP 443。
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${HY2_PORT}/udp" >/dev/null
fi

echo "===== 再次确保没有自动重启任务 ====="
CRON_TMP="$(mktemp)"
crontab -l 2>/dev/null | awk '
{
  line=$0
  if (line ~ /\/proc\/sys\/vm\/drop_caches/ &&
      (line ~ /shutdown[[:space:]].*-r/ || line ~ /reboot/)) next
  print
}
' > "$CRON_TMP" || true
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

echo "===== 禁止 Ubuntu 自动重启 ====="
cat > /etc/apt/apt.conf.d/99-iota-no-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo "===== 配置 HY2 网络参数和异常自动恢复 ====="
cat > /etc/sysctl.d/99-hysteria-iota.conf <<'EOF'
# Hysteria 官方性能建议：UDP 收发缓冲区 16MB
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system >/dev/null

mkdir -p /etc/systemd/system/hysteria-server.service.d
cat > /etc/systemd/system/hysteria-server.service.d/10-iota-stability.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=3
Nice=-5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
OOMScoreAdjust=-500
TimeoutStopSec=15
EOF

mkdir -p /etc/systemd/system/hysteria-server@.service.d
cat > /etc/systemd/system/hysteria-server@.service.d/10-iota-stability.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
Nice=-5
LimitNOFILE=1048576
EOF

echo "===== 安装 HY2 健康检查 ====="
cat > /usr/local/sbin/hy2_health_check.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

LOG=/var/log/hy2_health_check.log
NOW=$(date '+%Y-%m-%d %H:%M:%S')
PORT=443
RESTARTED=0

if ! systemctl is-active --quiet hysteria-server; then
  echo "$NOW | 服务不在运行，尝试启动" >> "$LOG"
  systemctl restart hysteria-server
  sleep 3
  RESTARTED=1
fi

if systemctl is-active --quiet hysteria-server; then
  if ss -Hlunp "sport = :${PORT}" 2>/dev/null | grep -q 'hysteria'; then
    STATE="OK"
  else
    STATE="ACTIVE_BUT_NO_UDP_SOCKET"
    if [ "$RESTARTED" -eq 0 ]; then
      echo "$NOW | 服务假活或UDP ${PORT}监听丢失，尝试重启" >> "$LOG"
      systemctl restart hysteria-server
      sleep 3
      if systemctl is-active --quiet hysteria-server &&
         ss -Hlunp "sport = :${PORT}" 2>/dev/null | grep -q 'hysteria'; then
        STATE="RECOVERED"
      else
        STATE="FAILED_NO_UDP_${PORT}"
      fi
    fi
  fi
else
  STATE="FAILED"
fi

LAST=""
[ -f /run/hy2-health-last ] && LAST=$(cat /run/hy2-health-last)
if [ "$STATE" != "$LAST" ]; then
  echo "$NOW | $STATE" >> "$LOG"
  echo "$STATE" > /run/hy2-health-last
fi
EOF
chmod +x /usr/local/sbin/hy2_health_check.sh

cat > /etc/systemd/system/hy2-health-check.service <<'EOF'
[Unit]
Description=Hysteria 2 Health Check
After=network-online.target hysteria-server.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2_health_check.sh
EOF

cat > /etc/systemd/system/hy2-health-check.timer <<'EOF'
[Unit]
Description=Check Hysteria 2 Every Minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/logrotate.d/iota-vps-guards <<'EOF'
/var/log/disk_guard.log /var/log/hy2_health_check.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF

echo "===== 配置日志上限 ====="
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/disk-limit.conf <<'EOF'
[Journal]
SystemMaxUse=150M
RuntimeMaxUse=50M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald

echo "===== 安装磁盘80%自动清理 ====="
cat > /usr/local/sbin/disk_guard.sh <<'EOF'
#!/usr/bin/env bash
set -u

LIMIT=80
WARNING_LIMIT=90
LOGFILE="/var/log/disk_guard.log"

USAGE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
FREE=$(df -h / | awk 'NR==2 {print $4}')
NOW=$(date '+%Y-%m-%d %H:%M:%S')

echo "$NOW | 检查：使用率 ${USAGE}% | 剩余 ${FREE}" >> "$LOGFILE"

if [ "$USAGE" -lt "$LIMIT" ]; then
  exit 0
fi

logger -t disk-guard "磁盘使用率达到 ${USAGE}%，开始安全清理"

journalctl --vacuum-time=7d >/dev/null 2>&1 || true
journalctl --vacuum-size=150M >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true

find /var/log -type f \( -name '*.gz' -o -name '*.old' \) -mtime +7 -delete 2>/dev/null || true

USAGE_AFTER=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
FREE_AFTER=$(df -h / | awk 'NR==2 {print $4}')

echo "$NOW | 清理后：使用率 ${USAGE_AFTER}% | 剩余 ${FREE_AFTER}" >> "$LOGFILE"
logger -t disk-guard "清理完成：清理前 ${USAGE}%，清理后 ${USAGE_AFTER}%"

if [ "$USAGE_AFTER" -ge "$WARNING_LIMIT" ]; then
  cat > /root/DISK_SPACE_WARNING.txt <<EOT
警告时间：$NOW
根目录磁盘使用率：${USAGE_AFTER}%
请人工检查大文件。
本脚本没有重启 VPS，也没有停止 HY2。
EOT
  logger -p daemon.err -t disk-guard "磁盘仍高于90%：${USAGE_AFTER}%"
fi
EOF
chmod +x /usr/local/sbin/disk_guard.sh

cat > /etc/systemd/system/disk-guard.service <<'EOF'
[Unit]
Description=VPS Disk Space Guard

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disk_guard.sh
EOF

cat > /etc/systemd/system/disk-guard.timer <<'EOF'
[Unit]
Description=Check Disk Space Every 10 Minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /usr/local/sbin/hy2-status <<'EOF'
#!/usr/bin/env bash
set -u

echo "===== 时间 ====="
date
echo "===== 服务 ====="
systemctl is-active hysteria-server || true
systemctl show hysteria-server -p NRestarts -p ActiveEnterTimestamp --no-pager || true
echo "===== UDP 443监听 ====="
ss -Hlunp "sport = :443" 2>/dev/null || true
echo "===== 最近日志 ====="
journalctl -u hysteria-server -n 30 --no-pager || true
echo "===== 资源 ====="
uptime
free -h
df -h /
EOF
chmod +x /usr/local/sbin/hy2-status

systemctl daemon-reload

if ! systemctl restart hysteria-server ||
   ! systemctl is-active --quiet hysteria-server ||
   ! ss -Hlunp "sport = :${HY2_PORT}" 2>/dev/null | grep -q 'hysteria'; then
  echo "❌ HY2 无法在 UDP ${HY2_PORT} 启动，正在恢复原配置。"
  journalctl -u hysteria-server -n 50 --no-pager || true
  cp -a "$GENERATED_BACKUP/config.yaml" "$SERVER_CONFIG"
  cp -a "$GENERATED_BACKUP/clash_subscription.yaml" "$CLASH_SUBSCRIPTION"
  systemctl restart hysteria-server || true
  exit 1
fi

systemctl enable --now disk-guard.timer
systemctl enable --now hy2-health-check.timer
/usr/local/sbin/disk_guard.sh || true
/usr/local/sbin/hy2_health_check.sh || true

echo
echo "===== 最终检查 ====="
echo "--- HY2 服务 ---"
HY2_STATE=$(systemctl is-active hysteria-server 2>/dev/null || true)
echo "$HY2_STATE"
if [ "$HY2_STATE" != "active" ]; then
  echo "❌ HY2 服务未正常启动，请不要把订阅加入 IOTA 电脑"
  journalctl -u hysteria-server -n 50 --no-pager || true
  exit 1
fi

if ! ss -Hlunp "sport = :${HY2_PORT}" 2>/dev/null | grep -q 'hysteria'; then
  echo "❌ HY2 服务虽显示 active，但没有检测到 UDP ${HY2_PORT} 监听端口"
  journalctl -u hysteria-server -n 50 --no-pager || true
  echo "正在恢复上游安装脚本生成的原配置……"
  cp -a "$GENERATED_BACKUP/config.yaml" "$SERVER_CONFIG"
  cp -a "$GENERATED_BACKUP/clash_subscription.yaml" "$CLASH_SUBSCRIPTION"
  systemctl restart hysteria-server || true
  exit 1
fi
echo "✅ HY2 服务 active，UDP ${HY2_PORT} 正在监听"

echo "--- 自动重启任务 ---"
if crontab -l 2>/dev/null | grep -E 'drop_caches.*(shutdown|reboot)' ; then
  echo "❌ 仍发现自动重启任务"
  exit 1
else
  echo "✅ 没有每天清缓存并重启的任务"
fi

echo "--- 磁盘与健康保护 ---"
systemctl is-active disk-guard.timer
systemctl is-enabled disk-guard.timer
systemctl is-active hy2-health-check.timer
systemctl is-enabled hy2-health-check.timer
df -h /
free -h
swapon --show || true

echo
echo "✅ 已固定 HY2 安装脚本版本"
echo "✅ 已禁用每日03:00重启"
echo "✅ 已禁止 Ubuntu 自动重启"
echo "✅ HY2 异常退出后约3秒自动恢复"
echo "✅ 新证书有效期改为3650天"
echo "✅ 磁盘达到80%自动清理"
echo "✅ 每10分钟检查一次磁盘"
echo "✅ 磁盘保护不会重启 VPS"
echo "✅ 每分钟检查 HY2 服务，进程异常时自动拉起"
echo "✅ 已应用官方建议的 16MB UDP 缓冲区"
echo "✅ 低内存 VPS 自动配置 1GB Swap"
echo "✅ 服务端和 Clash 订阅已统一使用 UDP ${HY2_PORT}"
echo "✅ 健康检查可识别进程假活和 UDP ${HY2_PORT} 监听丢失"
echo "✅ 随时运行 hy2-status 可查看服务、端口、日志和资源"
echo "✅ 原始生成配置备份：${GENERATED_BACKUP}"
echo
echo "⚠️ 请在 VPS 商家安全组/防火墙中放行 UDP ${HY2_PORT}。"
echo "⚠️ 安装完成后请在 Clash 刷新订阅，确认节点显示 HY2-UDP-443。"
echo "⚠️ 本脚本可降低因服务退出、内存紧张、日志满盘造成的中断，"
echo "⚠️ 但无法保证绝对不断网：VPS线路丢包、UDP封锁、IP被封、上游故障、"
echo "⚠️ 本地宽带/Clash异常和 IOTA 服务端问题仍可能造成中断。"
