#!/bin/bash

# OptimAI macOS 全新安装 / 升级脚本
# 新电脑可自动安装官方 Docker Desktop 和 OptimAI CLI。
# 重复运行不会删除 OptimAI 登录、节点配置或 Docker 数据。

set -u

SCRIPT_VERSION="1.1.0"
CLI_URL="https://cli-node.optimai.network/optimai_cli_darwin_universal2"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/optimai-cli"
MIN_CLI_BYTES=1000000
DOCKER_MIN_BYTES=100000000

TMP_CLI=""
TMP_DMG=""
MOUNT_DIR=""
DOCKER_MOUNTED=0

info() { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ "$DOCKER_MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  [ -z "$TMP_CLI" ] || rm -f "$TMP_CLI"
  [ -z "$TMP_DMG" ] || rm -f "$TMP_DMG"
  if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

printf '%s\n' "========================================"
printf '%s\n' " OptimAI Mac 全新安装 / 升级 v${SCRIPT_VERSION}"
printf '%s\n' "========================================"

[ "$(uname -s)" = "Darwin" ] || fail "此脚本仅支持 macOS。"
command -v curl >/dev/null 2>&1 || fail "系统找不到 curl。"

MAC_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
case "$MAC_MAJOR" in
  ''|*[!0-9]*) fail "无法读取 macOS 版本。" ;;
esac
[ "$MAC_MAJOR" -ge 12 ] || fail "OptimAI要求 macOS 12 或更高版本。"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)
    DOCKER_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
    ;;
  x86_64)
    DOCKER_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    ;;
  *)
    fail "不支持的Mac架构：$ARCH"
    ;;
esac

install_docker() {
  info ""
  info "📥 新电脑未安装 Docker Desktop，正在从 Docker 官方下载……"
  TMP_DMG="$(mktemp "${TMPDIR:-/tmp}/Docker.XXXXXX.dmg")" || fail "无法创建Docker临时文件。"

  curl --fail --location --retry 3 --connect-timeout 20 \
    --progress-bar "$DOCKER_URL" -o "$TMP_DMG" || fail "Docker下载失败，请检查网络或代理。"

  DOCKER_BYTES="$(wc -c < "$TMP_DMG" | tr -d ' ')"
  case "$DOCKER_BYTES" in
    ''|*[!0-9]*) fail "无法验证Docker安装包大小。" ;;
  esac
  [ "$DOCKER_BYTES" -ge "$DOCKER_MIN_BYTES" ] || fail "Docker安装包异常：文件过小。"

  MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/docker-mount.XXXXXX")" || fail "无法创建Docker挂载目录。"
  hdiutil attach "$TMP_DMG" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null \
    || fail "无法打开Docker官方安装包。"
  DOCKER_MOUNTED=1

  DOCKER_APP="$MOUNT_DIR/Docker.app"
  [ -d "$DOCKER_APP" ] || fail "Docker安装包中未找到Docker.app。"
  codesign --verify --deep --strict "$DOCKER_APP" >/dev/null 2>&1 \
    || fail "Docker官方程序签名验证失败，已停止安装。"

  TEAM_ID="$(codesign -dv --verbose=4 "$DOCKER_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  [ "$TEAM_ID" = "9BNSXJN65R" ] || fail "Docker开发者签名不正确，已停止安装。"

  info "📦 正在安装Docker Desktop，需要输入这台Mac的登录密码……"
  sudo "$DOCKER_APP/Contents/MacOS/install" --user "$USER" \
    || fail "Docker Desktop安装失败。"

  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  DOCKER_MOUNTED=0
  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  MOUNT_DIR=""
  info "✅ Docker Desktop安装完成"
}

if [ ! -d "/Applications/Docker.app" ]; then
  install_docker
else
  info "✅ 已检测到Docker Desktop，保留现有Docker数据。"
fi

export PATH="/usr/local/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"

info ""
info "🐳 正在启动Docker Desktop……"
open -a Docker >/dev/null 2>&1 || fail "无法启动Docker Desktop。"
info "首次安装时请在弹出的Docker窗口完成协议确认；脚本会继续等待。"

WAITED=0
while [ "$WAITED" -lt 300 ]; do
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    break
  fi
  sleep 3
  WAITED=$((WAITED + 3))
done

command -v docker >/dev/null 2>&1 || fail "系统仍找不到Docker命令，请打开Docker Desktop完成首次设置后重新运行脚本。"
docker info >/dev/null 2>&1 || fail "等待Docker启动超时，请完成Docker首次设置后重新运行脚本。"
info "✅ Docker运行正常"

info ""
info "📥 正在从 OptimAI 官方服务器下载最新版CLI……"
TMP_CLI="$(mktemp "${TMPDIR:-/tmp}/optimai-cli.XXXXXX")" || fail "无法创建CLI临时文件。"
curl --fail --location --retry 3 --connect-timeout 15 \
  --progress-bar "$CLI_URL" -o "$TMP_CLI" || fail "CLI下载失败，请检查网络或代理。"

FILE_BYTES="$(wc -c < "$TMP_CLI" | tr -d ' ')"
case "$FILE_BYTES" in
  ''|*[!0-9]*) fail "无法验证CLI文件大小。" ;;
esac
[ "$FILE_BYTES" -ge "$MIN_CLI_BYTES" ] || fail "CLI下载内容异常：文件过小。"
chmod 755 "$TMP_CLI" || fail "无法设置CLI执行权限。"

if command -v file >/dev/null 2>&1; then
  FILE_TYPE="$(file "$TMP_CLI" 2>/dev/null || true)"
  printf '%s' "$FILE_TYPE" | grep -q "Mach-O" || fail "下载内容不是有效的macOS程序。"
fi

info "📦 正在安装最新版OptimAI CLI（不会清除账号和节点数据）……"
sudo mkdir -p "$INSTALL_DIR" || fail "无法创建 $INSTALL_DIR。"
sudo install -m 0755 "$TMP_CLI" "$INSTALL_PATH" || fail "OptimAI CLI安装失败。"

hash -r 2>/dev/null || true
command -v optimai-cli >/dev/null 2>&1 || fail "安装完成但系统仍找不到optimai-cli。"
info "✅ OptimAI CLI安装完成"
optimai-cli --version 2>/dev/null || true

info ""
info "🔐 检查OptimAI登录状态……"
if optimai-cli auth status >/dev/null 2>&1; then
  info "✅ 已登录，保留现有账号。"
else
  info "新电脑尚未登录，即将打开OptimAI官方网页。"
  if ! optimai-cli auth login; then
    warn "网页登录未完成，改用官方兼容的邮箱/密码登录。"
    optimai-cli auth login --legacy || fail "OptimAI登录失败。"
  fi
fi

create_launcher() {
  DESKTOP_DIR="$HOME/Desktop"
  LAUNCHER="$DESKTOP_DIR/OptimAI.command"

  [ -d "$DESKTOP_DIR" ] || {
    warn "未找到桌面目录，跳过创建启动图标。"
    return 0
  }

  cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/bin/bash
clear
export PATH="/usr/local/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
printf '%s\n' "========================================"
printf '%s\n' " OptimAI 节点实时运行日志"
printf '%s\n' " 关闭窗口或按 Control+C 停止本次节点"
printf '%s\n' "========================================"

command -v optimai-cli >/dev/null 2>&1 || {
  echo "❌ 找不到OptimAI CLI，请重新运行安装脚本。"
  read -r -p "按回车键关闭……" _
  exit 1
}

if ! docker info >/dev/null 2>&1; then
  echo "⚠️  正在启动Docker Desktop……"
  open -a Docker >/dev/null 2>&1 || exit 1
  waited=0
  while [ "$waited" -lt 180 ]; do
    docker info >/dev/null 2>&1 && break
    sleep 3
    waited=$((waited + 3))
  done
fi

docker info >/dev/null 2>&1 || {
  echo "❌ Docker启动超时。"
  read -r -p "按回车键关闭……" _
  exit 1
}

optimai-cli auth status >/dev/null 2>&1 || {
  echo "❌ OptimAI账号未登录，请重新运行安装脚本。"
  read -r -p "按回车键关闭……" _
  exit 1
}

echo ""
echo "当前奖励余额："
optimai-cli rewards balance 2>&1 || true
echo ""
echo "当前节点状态："
optimai-cli node status 2>&1 || true
echo ""
echo "正在启动OptimAI节点并显示实时日志……"
echo ""
exec optimai-cli node start
LAUNCHER_EOF

  chmod 755 "$LAUNCHER" || fail "无法设置桌面启动器权限。"
  info "✅ 已创建桌面实时日志：$LAUNCHER"
}

create_launcher

info ""
info "当前奖励余额："
optimai-cli rewards balance 2>&1 || warn "暂时无法读取奖励余额。"

info ""
info "当前节点状态："
optimai-cli node status 2>&1 || true

info ""
info "🚀 正在启动OptimAI节点并显示实时日志……"
info "以后双击桌面的 OptimAI.command 也可以启动和查看。"
info "如果提示已有节点实例运行，说明节点已经在线。"
exec optimai-cli node start
