#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

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
apt-get install -y ca-certificates curl cron iproute2 procps util-linux openssl coreutils
systemctl enable --now cron

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
SOURCE_SHA256="f661186a42cc504a56870c73fa73b0dd40c18991be100fa03d0df9f7f3dc37f5"
TMP_SCRIPT="$(mktemp /tmp/hy2-pinned.XXXXXX.sh)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

echo "===== 下载固定版本 HY2 脚本 ====="
curl -fL --connect-timeout 15 --max-time 120 "$SOURCE_URL" -o "$TMP_SCRIPT"
chmod 700 "$TMP_SCRIPT"

ACTUAL_SOURCE_SHA256="$(sha256sum "$TMP_SCRIPT" | awk '{print $1}')"
if [ "$ACTUAL_SOURCE_SHA256" != "$SOURCE_SHA256" ]; then
  echo "❌ 第三方安装脚本完整性校验失败，已停止安装。"
  exit 1
fi
echo "✅ 第三方安装脚本 SHA-256 校验通过"

grep -q 'setup_auto_reboot_cron' "$TMP_SCRIPT"
grep -q 'hysteria-server.service' "$TMP_SCRIPT"
grep -q 'generate_self_signed_cert' "$TMP_SCRIPT"

case "$(uname -m)" in
  x86_64|amd64) HY2_ASSET="hysteria-linux-amd64" ;;
  aarch64|arm64) HY2_ASSET="hysteria-linux-arm64" ;;
  armv7l|armv7|armhf) HY2_ASSET="hysteria-linux-armv7" ;;
  i386|i486|i586|i686) HY2_ASSET="hysteria-linux-386" ;;
  ppc64le) HY2_ASSET="hysteria-linux-ppc64le" ;;
  riscv64) HY2_ASSET="hysteria-linux-riscv64" ;;
  s390x) HY2_ASSET="hysteria-linux-s390x" ;;
  *) echo "❌ 不支持的 CPU 架构：$(uname -m)"; exit 1 ;;
esac

HASHES_TMP="$(mktemp /tmp/hy2-hashes.XXXXXX.txt)"
curl -fL --connect-timeout 15 --max-time 120 \
  "https://github.com/apernet/hysteria/releases/latest/download/hashes.txt" \
  -o "$HASHES_TMP"
HY2_EXPECTED_SHA256="$(awk -v asset="$HY2_ASSET" '$2 == "build/" asset {print $1; exit}' "$HASHES_TMP")"
rm -f "$HASHES_TMP"
if ! printf '%s' "$HY2_EXPECTED_SHA256" | grep -Eq '^[a-fA-F0-9]{64}$'; then
  echo "❌ 无法从官方 hashes.txt 获取 ${HY2_ASSET} 校验值"
  exit 1
fi

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

HY2_ACTUAL_SHA256="$(sha256sum /usr/local/bin/hysteria | awk '{print $1}')"
if [ "$HY2_ACTUAL_SHA256" != "$HY2_EXPECTED_SHA256" ]; then
  systemctl stop hysteria-server 2>/dev/null || true
  echo "❌ Hysteria 官方二进制 SHA-256 校验失败，服务已停止。"
  exit 1
fi
HY2_VERSION="$(/usr/local/bin/hysteria version 2>/dev/null | head -n1 || /usr/local/bin/hysteria --version 2>/dev/null | head -n1 || true)"
echo "✅ Hysteria 官方二进制校验通过：${HY2_VERSION:-版本信息未知}"

echo "===== 加固 Clash 订阅地址 ====="
SUB_TOKEN="$(openssl rand -hex 20)"
SUB_NAME="sub-${SUB_TOKEN}.yaml"
SUB_FILE="/etc/hysteria/${SUB_NAME}"
if [ ! -s /etc/hysteria/clash_subscription.yaml ]; then
  echo "❌ 未找到上游脚本生成的 Clash 订阅文件"
  exit 1
fi
mv /etc/hysteria/clash_subscription.yaml "$SUB_FILE"
chmod 644 "$SUB_FILE"
cat > /etc/nginx/sites-available/clash.conf <<EOF
server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    server_tokens off;

    location = /${SUB_NAME} {
        alias ${SUB_FILE};
        default_type application/x-yaml;
        add_header Cache-Control "no-store" always;
        access_log off;
    }

    location / {
        return 404;
    }
}
EOF
printf 'http://%s:8080/%s\n' "$(ip -4 addr show scope global | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)" "$SUB_NAME" \
  > /root/hy2_subscription_url.txt
chmod 600 /root/hy2_subscription_url.txt
nginx -t
systemctl restart nginx

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
set -u

LOG=/var/log/hy2_health_check.log
NOW=$(date '+%Y-%m-%d %H:%M:%S')

if ! systemctl is-active --quiet hysteria-server; then
  echo "$NOW | 服务不在运行，尝试启动" >> "$LOG"
  systemctl restart hysteria-server
  sleep 3
fi

if systemctl is-active --quiet hysteria-server; then
  if ss -Hlunp 2>/dev/null | grep -q 'hysteria'; then
    STATE="OK"
  else
    STATE="ACTIVE_BUT_NO_UDP_SOCKET"
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

systemctl daemon-reload
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

if ! ss -Hlunp 2>/dev/null | grep -q 'hysteria'; then
  echo "❌ HY2 服务虽显示 active，但没有检测到 UDP 监听端口"
  journalctl -u hysteria-server -n 50 --no-pager || true
  exit 1
fi
echo "✅ HY2 服务 active，UDP 端口正在监听"

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
echo "✅ 已校验安装器和 Hysteria 官方二进制 SHA-256"
echo "✅ HY2 版本：${HY2_VERSION:-未知}"
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
echo "✅ Clash 订阅已改为随机私密地址："
cat /root/hy2_subscription_url.txt
echo
echo "⚠️ 本脚本可降低因服务退出、内存紧张、日志满盘造成的中断，"
echo "⚠️ 但无法保证绝对不断网：VPS线路丢包、UDP封锁、IP被封、上游故障、"
echo "⚠️ 本地宽带/Clash异常和 IOTA 服务端问题仍可能造成中断。"
