#!/bin/bash
# Dria Compute Node one-click installer/updater for macOS.
# Source project: https://github.com/firstbatchxyz/dkn-compute-node

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.4.0"
OFFICIAL_REPO="firstbatchxyz/dkn-compute-node"
OFFICIAL_API="https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest"
RAW_SELF_URL="https://raw.githubusercontent.com/baibai131131/deploy_nodes/refs/heads/main/deploy_dria.sh"

APP_DIR="${HOME}/.dria/baibai-node"
ENV_FILE="${APP_DIR}/node.env"
RUN_FILE="${APP_DIR}/run.sh"
LOG_DIR="${HOME}/Library/Logs"
OUT_LOG="${LOG_DIR}/DriaNode.log"
PLIST="${HOME}/Library/LaunchAgents/com.baibai.dria-node.plist"
LABEL="com.baibai.dria-node"
INSTALL_DIR="${APP_DIR}/bin"
BINARY="${INSTALL_DIR}/dria-node"

green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
reset='\033[0m'

info() { printf "%b[信息]%b %s\n" "$green" "$reset" "$*" >&2; }
warn() { printf "%b[注意]%b %s\n" "$yellow" "$reset" "$*" >&2; }
die()  { printf "%b[错误]%b %s\n" "$red" "$reset" "$*" >&2; exit 1; }

cleanup_dir=""
cleanup() {
  if [ -n "$cleanup_dir" ] && [ -d "$cleanup_dir" ]; then
    rm -f -- "${cleanup_dir}/release.json" "${cleanup_dir}/dria-node"
    rmdir -- "$cleanup_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "此脚本仅支持 macOS。"
  command -v curl >/dev/null 2>&1 || die "系统缺少 curl。"
  command -v openssl >/dev/null 2>&1 || die "系统缺少 openssl。"
}

launch_domain() {
  local uid
  uid="$(id -u)"
  if launchctl print "gui/${uid}" >/dev/null 2>&1; then
    printf 'gui/%s' "$uid"
  else
    printf 'user/%s' "$uid"
  fi
}

read_env_value() {
  local file="$1" key="$2" value
  [ -f "$file" ] || return 1
  value="$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*(.*)$/\\2/p" "$file" | tail -n 1)"
  [ -n "$value" ] || return 1
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

normalize_wallet() {
  local value="$1"
  value="${value#0x}"
  value="${value#0X}"
  if [[ "$value" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

find_or_create_wallet() {
  local candidate="" file="" key=""
  local files=(
    "${HOME}/.dria/dkn-compute-launcher/.env"
    "${HOME}/.dria/dkn-compute-node/.env"
    "${HOME}/.dria/.env"
  )
  local keys=(DRIA_WALLET DKN_WALLET_SECRET_KEY DKN_PRIVATE_KEY PRIVATE_KEY)

  candidate="$(read_env_value "$ENV_FILE" DRIA_WALLET 2>/dev/null || true)"
  if candidate="$(normalize_wallet "$candidate" 2>/dev/null)"; then
    info "已保留本机现有 Dria 钱包。"
    printf '%s' "$candidate"
    return 0
  fi

  # Older NodeOS-style launchers put the wallet after --wallet in the running
  # process. Capture it without printing it, then migrate to the protected env.
  candidate="$(ps -axo command= 2>/dev/null | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i == "--wallet") { print $(i+1); exit }
      }
    }
  ')"
  if candidate="$(normalize_wallet "$candidate" 2>/dev/null)"; then
    info "已从正在运行的旧节点安全迁移原钱包，钱包身份保持不变。"
    printf '%s' "$candidate"
    return 0
  fi

  for file in "${files[@]}"; do
    for key in "${keys[@]}"; do
      candidate="$(read_env_value "$file" "$key" 2>/dev/null || true)"
      if candidate="$(normalize_wallet "$candidate" 2>/dev/null)"; then
        mkdir -p "${APP_DIR}/backup"
        cp -p "$file" "${APP_DIR}/backup/legacy-env-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        chmod 600 "${APP_DIR}/backup/"* 2>/dev/null || true
        info "已迁移并备份本机旧版 Dria 钱包。"
        printf '%s' "$candidate"
        return 0
      fi
    done
  done

  if [ "${DRIA_REQUIRE_EXISTING_WALLET:-0}" = "1" ]; then
    die "没有读取到旧节点钱包，已停止升级；任何钱包配置都没有改变。请先启动旧节点后重试。"
  fi

  candidate="$(openssl rand -hex 32)"
  normalize_wallet "$candidate" >/dev/null || die "无法生成安全钱包私钥。"
  warn "未发现旧钱包，已为本机生成一个全新的唯一钱包。"
  warn "每台电脑必须使用不同钱包；配置保存在 ${ENV_FILE}，请做好加密备份，切勿发给别人。"
  printf '%s' "$candidate"
}

valid_model() {
  case "$1" in
    qwen3.5:0.8b|lfm2.5:1.2b|lfm2.5-audio:1.5b|lfm2.5-vl:1.6b|qwen3.5:2b|nanbeige:3b|locooperator:4b|qwen3.5:9b|lfm2:24b-a2b|qwen3.5:27b|qwen3.5:35b-a3b|nemotron:30b-a3b) return 0 ;;
    *) return 1 ;;
  esac
}

valid_model_list() {
  local list="$1" item
  [ -n "$list" ] || return 1
  while IFS= read -r item; do
    [ -n "$item" ] && valid_model "$item" || return 1
  done < <(printf '%s' "$list" | tr ',' '\n')
}

select_model() {
  local existing="" bytes="" gb=0 chosen=""
  if [ -n "${DRIA_MODEL:-}" ]; then
    chosen="$DRIA_MODEL"
    valid_model_list "$chosen" || die "DRIA_MODEL=${chosen} 包含当前脚本不支持的官方模型名。"
    printf '%s' "$chosen"
    return 0
  fi

  existing="$(read_env_value "$ENV_FILE" DRIA_MODELS 2>/dev/null || true)"
  if valid_model_list "$existing"; then
    # v1.2.0 used qwen3.5:0.8b as its automatic default. Move only that
    # old default to the M4-tested text model; preserve every manually chosen
    # model and every later explicit DRIA_MODEL override.
    if [ "$existing" = "qwen3.5:0.8b" ]; then
      chosen="lfm2.5:1.2b"
      info "将旧版默认模型 ${existing} 升级为 M4 实测模型：${chosen}"
      printf '%s' "$chosen"
      return 0
    fi
    info "已保留现有模型：${existing}"
    printf '%s' "$existing"
    return 0
  fi

  bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '0')"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    gb=$((bytes / 1024 / 1024 / 1024))
  fi

  chosen="lfm2.5:1.2b"
  info "检测到约 ${gb}GB 内存；默认选择 M4 16GB 实测稳定模型：${chosen}（Q4_K_M）。"
  printf '%s' "$chosen"
}

install_official_binary() {
  local arch asset json url digest actual tmpbin
  arch="$(uname -m)"
  case "$arch" in
    arm64|aarch64) asset="dria-node-macOS-arm64" ;;
    x86_64|amd64) asset="dria-node-macOS-amd64" ;;
    *) die "不支持的 Mac 架构：${arch}" ;;
  esac

  cleanup_dir="$(mktemp -d)"
  json="${cleanup_dir}/release.json"
  tmpbin="${cleanup_dir}/dria-node"

  info "正在读取 Dria 官方最新稳定版本……"
  if curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 "$OFFICIAL_API" -o "$json"; then
    url="$(awk -v asset="$asset" '
      $0 ~ "\\\"name\\\": \\\"" asset "\\\"" { found=1 }
      found && /"browser_download_url"/ {
        line=$0; sub(/^.*"browser_download_url": "/, "", line); sub(/".*$/, "", line); print line; exit
      }
    ' "$json")"
    digest="$(awk -v asset="$asset" '
      $0 ~ "\\\"name\\\": \\\"" asset "\\\"" { found=1 }
      found && /"digest"/ {
        line=$0; sub(/^.*"digest": "sha256:/, "", line); sub(/".*$/, "", line); print line; exit
      }
    ' "$json")"
  else
    warn "GitHub API 暂时不可用或达到限额，改用官方 latest 下载地址。"
    url="https://github.com/${OFFICIAL_REPO}/releases/latest/download/${asset}"
    digest=""
  fi

  case "$url" in
    "https://github.com/${OFFICIAL_REPO}/releases/download/"*"/${asset}"|\
    "https://github.com/${OFFICIAL_REPO}/releases/latest/download/${asset}") ;;
    *) die "官方发布地址校验失败，已停止安装。" ;;
  esac

  curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 "$url" -o "$tmpbin"
  if [ -n "$digest" ]; then
    actual="$(shasum -a 256 "$tmpbin" | awk '{print $1}')"
    [ "$actual" = "$digest" ] || die "官方二进制 SHA-256 校验失败，已停止安装。"
  else
    warn "官方发布信息未提供 SHA-256，跳过哈希核验。"
  fi
  chmod 755 "$tmpbin"

  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_DIR"
  install -m 0755 "$tmpbin" "$BINARY"

  "$BINARY" --version >/dev/null 2>&1 || die "dria-node 安装后无法执行。"
  info "官方 dria-node 已安装：$("$BINARY" --version 2>/dev/null | head -n 1)"
}

write_config() {
  local wallet="$1" model="$2" concurrency="$3"
  mkdir -p "$APP_DIR" "$LOG_DIR" "$(dirname "$PLIST")"
  chmod 700 "$APP_DIR"

  umask 077
  {
    printf 'DRIA_WALLET=%s\n' "$wallet"
    printf 'DRIA_MODELS=%s\n' "$model"
    printf 'DRIA_GPU_LAYERS=-1\n'
    printf 'DRIA_MAX_CONCURRENT=%s\n' "$concurrency"
    printf 'DRIA_DATA_DIR="$HOME/.dria"\n'
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  {
    printf '#!/bin/bash\n'
    printf 'set -a\n'
    printf '. "%s"\n' "$ENV_FILE"
    printf 'set +a\n'
    printf 'exec "%s" start\n' "$BINARY"
  } > "$RUN_FILE"
  chmod 700 "$RUN_FILE"
}

write_launch_agent() {
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUN_FILE}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>${OUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${OUT_LOG}</string>
</dict>
</plist>
PLIST_EOF
  chmod 600 "$PLIST"
  plutil -lint "$PLIST" >/dev/null || die "LaunchAgent 配置校验失败。"
}

write_desktop_helpers() {
  local desktop="${HOME}/Desktop"
  [ -d "$desktop" ] || return 0

  # Keep the desktop clean: remove helpers created by older script versions.
  rm -f "${desktop}/Dria_Start.command" "${desktop}/Dria_Stop.command" \
    "${desktop}/Dria_Status.command" "${desktop}/Dria_Update.command"

  cat > "${desktop}/Dria_Live_Log.command" <<EOF
#!/bin/bash
printf '\\033]0;Dria 实时日志 - 关闭窗口不停止节点\\007'
clear
mkdir -p "$LOG_DIR"
touch "$OUT_LOG"
echo "===== Dria 实时运行日志 ====="
echo "日志会自动滚动；关闭此窗口不会停止节点。"
echo "按 Control + C 可停止查看。"
echo
tail -n 60 -F "$OUT_LOG"
EOF

  chmod 700 "${desktop}/Dria_Live_Log.command"
}

stop_service() {
  local domain
  domain="$(launch_domain)"
  launchctl bootout "$domain" "$PLIST" >/dev/null 2>&1 || true
  info "Dria 后台服务已停止。"
}

start_service() {
  local domain
  [ -x "$RUN_FILE" ] || die "尚未安装，请先运行安装命令。"
  domain="$(launch_domain)"
  launchctl bootout "$domain" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$PLIST" || die "无法载入 Dria 后台服务。"
  launchctl kickstart -k "${domain}/${LABEL}" || die "无法启动 Dria 后台服务。"
  info "Dria 后台服务已启动。"
}

show_status() {
  local domain
  domain="$(launch_domain)"
  if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
    info "Dria 服务正在运行。"
  else
    warn "Dria 服务当前未运行。"
  fi
  printf '\n最近日志：\n'
  tail -n 30 "$OUT_LOG" 2>/dev/null || true
}

follow_logs() {
  mkdir -p "$LOG_DIR"
  touch "$OUT_LOG"
  printf '\n===== Dria 实时日志 =====\n'
  printf '按 Control + C 只停止查看，后台节点不会停止。\n\n'
  tail -n 60 -F "$OUT_LOG"
}

install_all() {
  local wallet model domain concurrency
  require_macos
  printf '\nDria macOS 一键安装/升级脚本 v%s\n' "$SCRIPT_VERSION"
  printf '官方项目：%s\n\n' "https://github.com/${OFFICIAL_REPO}"

  wallet="$(find_or_create_wallet)"
  model="$(select_model)"
  concurrency="${DRIA_MAX_CONCURRENT:-1}"
  [[ "$concurrency" =~ ^[1-8]$ ]] || die "DRIA_MAX_CONCURRENT 必须是 1 到 8 的整数。"
  install_official_binary

  domain="$(launch_domain)"
  launchctl bootout "$domain" "$PLIST" >/dev/null 2>&1 || true
  pkill -TERM -x dkn-compute-launcher >/dev/null 2>&1 || true
  pkill -TERM -x dkn-compute-node >/dev/null 2>&1 || true
  pkill -TERM -x dria-node >/dev/null 2>&1 || true

  write_config "$wallet" "$model" "$concurrency"
  write_launch_agent
  write_desktop_helpers
  start_service
  sleep 3

  printf '\n'
  info "安装/升级完成，节点会在登录后自动启动，并在退出后自动重启。"
  info "模型：${model}｜GPU：Apple Metal 全层｜并发：${concurrency}"
  info "日志：${OUT_LOG}"
  warn "同一台电脑可重复运行本脚本升级；钱包和模型设置会保留。"
  warn "不同电脑禁止使用同一个钱包私钥，否则任务分配和积分可能冲突。"
  show_status
  if [ "${DRIA_NO_FOLLOW:-0}" != "1" ]; then
    follow_logs
  fi
}

case "${1:-install}" in
  install|update) install_all ;;
  start) require_macos; start_service ;;
  stop) require_macos; stop_service ;;
  status) require_macos; show_status ;;
  logs) require_macos; follow_logs ;;
  *) die "用法：$0 [install|update|start|stop|status|logs]" ;;
esac
