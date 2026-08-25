#!/bin/bash

# OptimAI macOS 官方源一键安装/升级脚本
# 仅从 OptimAI 官方域名下载 CLI，不删除账号、节点配置或 Docker 数据。

set -u

CLI_URL="https://cli-node.optimai.network/optimai_cli_darwin_universal2"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/optimai-cli"
MIN_BYTES=1000000

info() { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

printf '%s\n' "========================================"
printf '%s\n' " OptimAI Mac 官方CLI安装 / 升级"
printf '%s\n' "========================================"

[ "$(uname -s)" = "Darwin" ] || fail "此脚本仅支持 macOS。"
command -v curl >/dev/null 2>&1 || fail "系统找不到 curl。"

TMP_CLI="$(mktemp "${TMPDIR:-/tmp}/optimai-cli.XXXXXX")" || fail "无法创建临时文件。"
cleanup() { rm -f "$TMP_CLI"; }
trap cleanup EXIT INT TERM

info "📥 正在从 OptimAI 官方服务器下载最新版CLI……"
curl --fail --location --retry 3 --connect-timeout 15 \
  --progress-bar "$CLI_URL" -o "$TMP_CLI" || fail "CLI下载失败，请检查网络或代理。"

FILE_BYTES="$(wc -c < "$TMP_CLI" | tr -d ' ')"
case "$FILE_BYTES" in
  ''|*[!0-9]*) fail "无法验证下载文件大小。" ;;
esac
[ "$FILE_BYTES" -ge "$MIN_BYTES" ] || fail "下载文件异常：文件过小。"

chmod 755 "$TMP_CLI" || fail "无法设置CLI执行权限。"

if command -v file >/dev/null 2>&1; then
  FILE_TYPE="$(file "$TMP_CLI" 2>/dev/null || true)"
  printf '%s' "$FILE_TYPE" | grep -q "Mach-O" || fail "下载内容不是有效的 macOS 程序。"
fi

info "📦 正在覆盖安装最新版CLI（不会清除登录和节点数据）……"
sudo mkdir -p "$INSTALL_DIR" || fail "无法创建 $INSTALL_DIR。"
sudo install -m 0755 "$TMP_CLI" "$INSTALL_PATH" || fail "CLI安装失败。"

hash -r 2>/dev/null || true
command -v optimai-cli >/dev/null 2>&1 || fail "安装完成但系统仍找不到 optimai-cli。"

info "✅ CLI安装完成"
optimai-cli --version 2>/dev/null || true

info ""
info "🔍 检查 Docker……"
if ! command -v docker >/dev/null 2>&1; then
  fail "未安装 Docker Desktop。请先安装：https://www.docker.com/products/docker-desktop/"
fi

if ! docker info >/dev/null 2>&1; then
  warn "Docker尚未运行，正在启动 Docker Desktop……"
  open -a Docker >/dev/null 2>&1 || fail "无法自动启动 Docker Desktop，请手动打开后重试。"

  WAITED=0
  while [ "$WAITED" -lt 120 ]; do
    if docker info >/dev/null 2>&1; then
      break
    fi
    sleep 3
    WAITED=$((WAITED + 3))
  done
  docker info >/dev/null 2>&1 || fail "等待 Docker 启动超时，请手动启动后重新运行脚本。"
fi
info "✅ Docker运行正常"

info ""
info "🔐 检查 OptimAI 登录状态……"
if optimai-cli auth status >/dev/null 2>&1; then
  info "✅ 已登录，保留现有账号。"
else
  info "尚未登录，即将打开官方网页完成登录。"
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
printf '%s\n' "========================================"
printf '%s\n' " OptimAI 节点启动器"
printf '%s\n' "========================================"

if ! command -v optimai-cli >/dev/null 2>&1; then
  echo "❌ 找不到 OptimAI CLI，请重新运行安装脚本。"
  read -r -p "按回车键关闭……" _
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ 未安装 Docker Desktop。"
  read -r -p "按回车键关闭……" _
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "⚠️  正在启动 Docker Desktop……"
  open -a Docker >/dev/null 2>&1 || {
    echo "❌ 无法启动 Docker Desktop。"
    read -r -p "按回车键关闭……" _
    exit 1
  }

  waited=0
  while [ "$waited" -lt 120 ]; do
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
echo "当前节点状态："
optimai-cli node status 2>&1 || true
echo ""
echo "正在启动 OptimAI 节点；运行期间请保留此窗口……"
echo ""
exec optimai-cli node start
LAUNCHER_EOF

  chmod 755 "$LAUNCHER"
  info "✅ 已创建桌面启动器：$LAUNCHER"
}

create_launcher

info ""
info "当前奖励余额："
optimai-cli rewards balance 2>&1 || warn "暂时无法读取奖励余额。"

info ""
info "当前节点状态："
optimai-cli node status 2>&1 || true

info ""
info "🚀 正在启动 OptimAI 节点……"
info "如果提示已有节点实例运行，说明旧节点仍然在线，无需重复启动。"
exec optimai-cli node start
