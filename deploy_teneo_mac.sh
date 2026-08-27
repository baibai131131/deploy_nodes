#!/bin/bash
# Teneo Beacon Mac installer v1.0.0 -- M1/M2/M3/M4, Bash 3.2 compatible.
# Fixed, checksum-verified official release. No Clash/proxy/route changes.
set -Eeuo pipefail
umask 077

fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }
info() { printf '[信息] %s\n' "$*"; }
[[ $(uname -s) == Darwin ]] || fail '这是 Mac 版本，请勿在 Ubuntu 上运行。'
(( EUID != 0 )) || fail '请用当前 Mac 登录用户运行，不要在整条命令前加 sudo。'
machine=$(uname -m)
arm_support=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)
[[ "$machine" == arm64 || "$arm_support" == 1 ]] || fail '此安装器面向 Apple M 系列 Mac。'

label=pro.teneo.beacon
domain="gui/$(id -u)"
service="$domain/$label"
binary=/usr/local/bin/teneo-beacon
agent="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/teneo-beacon.log"
release=cli-v0.5.1
expected=ebb8dad9777a51aa849a4d3a7ed5db386c3305266fb43d5a46e92c2df6795a8c
url="https://github.com/TeneoProtocolAI/teneo-beacon-cli/releases/download/$release/teneo-beacon-macos"

case "${1:-install}" in
  --logs) exec /usr/bin/tail -n 50 -F "$logfile" ;;
  --status) exec /bin/launchctl print "$service" ;;
  install) ;;
  *) fail '用法：bash deploy_teneo_mac.sh [--logs|--status]' ;;
esac
/bin/launchctl print "$domain" >/dev/null 2>&1 || fail '请在已登录桌面的 Mac 终端运行。'
[[ -r /dev/tty ]] && ( : </dev/tty ) 2>/dev/null || fail '首次安装需要交互终端。'
info "Teneo Mac 安装器 v1.0.0；官方固定版本 $release。"
info '支持 M1/M2/M3/M4，不需要 Homebrew、Docker 或 Rosetta。'
info '本脚本不修改或重启 Clash，不更改代理、DNS、路由、防火墙或其他节点。'
info '现有 TUN 仍可能接管 Teneo；本脚本不绕过 IP 限制，也不保证积分。'

loaded=0
if /bin/launchctl print "$service" >/dev/null 2>&1; then loaded=1; fi
if [[ -e "$agent" ]]; then
  actual_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent")
  [[ "$actual_label" == "$label" ]] || fail '已有 Teneo 自启动文件标签异常，停止安装。'
  program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$agent" 2>/dev/null || true)
  [[ -n "$program" ]] || program=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$agent" 2>/dev/null || true)
  [[ "$program" == "$binary" ]] || fail '已有 Teneo 服务使用其他启动路径，不自动覆盖。'
elif (( loaded == 1 )); then
  fail '已有已加载的 Teneo 服务但标准配置文件不存在，请先检查，不创建第二套服务。'
fi
if (( loaded == 0 )) && /usr/bin/pgrep -x teneo-beacon >/dev/null; then
  fail '检测到前台 Teneo 正在运行，请先按 q 正常退出，再执行本脚本。'
fi

changed=0
installed_hash=''
if [[ -e "$binary" || -L "$binary" ]]; then
  [[ -f "$binary" && ! -L "$binary" ]] || fail '程序目标不是普通文件，停止覆盖。'
  installed_hash=$(/usr/bin/shasum -a 256 "$binary")
  installed_hash=${installed_hash%% *}
fi

work_dir=''
staged=''
cleanup() {
  if [[ -n "$work_dir" ]]; then
    /bin/rm -f "$work_dir/teneo-beacon-macos"
    /bin/rmdir "$work_dir" 2>/dev/null || true
  fi
  if [[ -n "$staged" ]]; then /usr/bin/sudo /bin/rm -f "$staged"; fi
}
trap cleanup EXIT
trap 'printf "[错误] 第%s行失败，请保留报错；不要删除 Teneo 账户数据。\n" "$LINENO" >&2' ERR

if [[ "$installed_hash" != "$expected" ]]; then
  if [[ -n "$installed_hash" ]]; then
    printf '本机程序与固定版本 %s 不同，替换可能是升级或降级。备份后替换？输入 y：' "$release" >/dev/tty
    read -r answer </dev/tty
    [[ "$answer" == y || "$answer" == Y ]] || { info '未替换原程序。'; exit 0; }
  fi
  work_dir=$(/usr/bin/mktemp -d /tmp/teneo-mac.XXXXXXXX)
  info '下载官方 macOS 通用程序（含 Apple Silicon 原生架构）。'
  /usr/bin/curl --proto '=https' --proto-redir '=https' -fL --retry 2 \
    --connect-timeout 15 --max-time 600 "$url" -o "$work_dir/teneo-beacon-macos"
  actual=$(/usr/bin/shasum -a 256 "$work_dir/teneo-beacon-macos")
  [[ "${actual%% *}" == "$expected" ]] || fail 'SHA-256 校验失败，未覆盖原程序。'
  if [[ -n "$installed_hash" ]]; then
    backup_root="$HOME/Library/Application Support/TeneoInstaller/backups"
    /bin/mkdir -p "$backup_root"
    backup=$(/usr/bin/mktemp -d "$backup_root/before-install.XXXXXXXX")
    /bin/cp -p "$binary" "$backup/teneo-beacon"
    [[ ! -f "$agent" ]] || /bin/cp -p "$agent" "$backup/$label.plist"
    info "旧程序备份：$backup"
  fi
  info '安装程序到 /usr/local/bin，可能需要输入 Mac 登录密码。'
  /usr/bin/sudo /bin/mkdir -p /usr/local/bin
  staged=$(/usr/bin/sudo /usr/bin/mktemp /usr/local/bin/.teneo-beacon.XXXXXXXX)
  /usr/bin/sudo /usr/bin/install -m 755 "$work_dir/teneo-beacon-macos" "$staged"
  /usr/bin/sudo /bin/mv -f "$staged" "$binary"
  staged=''
  changed=1
else
  info '已是相同的校验版本，跳过下载和覆盖。'
fi

if [[ -f "$agent" ]]; then
  if (( loaded == 0 )); then /bin/launchctl bootstrap "$domain" "$agent"; fi
  if (( changed == 1 )); then
    /bin/launchctl kickstart -k "$service"
  else
    info '沿用已有 Teneo 服务，不强制重启；若未连接，请检查下方日志。'
  fi
else
  info '即将打开 Teneo 绑定界面；在浏览器登录 Hub 后打开链接或扫码。'
  info '绑定成功后按 q 返回；不要公开配对链接或二维码。'
  "$binary" </dev/tty >/dev/tty 2>&1
  printf '绑定已完成？输入 y 设置后台自启动，其他输入退出：' >/dev/tty
  read -r answer </dev/tty
  [[ "$answer" == y || "$answer" == Y ]] || { info '程序已安装，未设置后台服务。'; exit 0; }
  "$binary" --install-service
fi
/bin/launchctl print "$service" >/dev/null 2>&1 || fail 'Teneo 后台服务尚未成功加载，请检查上述报错。'
info 'Teneo 后台服务已加载，登录后自动运行；连接及奖励资格以新日志为准。'
info '现在显示滚动日志。Ctrl+C 或关闭此终端只停止查看，不停止后台服务。'
info '以后查看：tail -n 50 -F "$HOME/Library/Logs/teneo-beacon.log"'
cleanup
work_dir=''
trap - EXIT ERR
/usr/bin/tail -n 50 -F "$logfile"
