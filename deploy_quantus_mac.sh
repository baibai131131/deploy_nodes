#!/bin/bash
set -Eeuo pipefail

# Quantus macOS Apple Silicon safe wrapper
# Uses only the official Quantus installer and refuses to treat Planck testnet as mainnet.

WRAPPER_VERSION="2.0.1"

OFFICIAL_URL="https://docs.quantus.com/scripts/quantus-mining.sh"
SELF_URL="https://raw.githubusercontent.com/baibai131131/deploy_nodes/main/deploy_quantus_mac.sh"
BASE_DIR="${HOME}/quantus-mining"
OFFICIAL_SCRIPT="${BASE_DIR}/quantus-mining.sh"
CONFIG_FILE="${BASE_DIR}/mining.conf"
ACTION="${1:-install}"

info() { printf '\033[1;32m[Quantus] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[注意] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }

self_command() {
  printf "bash <(curl -fsSL '%s') %s" "$SELF_URL" "$1"
}

require_mac_arm() {
  [ "$(uname -s)" = "Darwin" ] || die "本脚本只支持 macOS。"
  [ "$(uname -m)" = "arm64" ] || die "本脚本只支持 Apple Silicon（M1/M2/M3/M4/M5）。"
  command -v curl >/dev/null 2>&1 || die "系统找不到 curl。"
}

download_official() {
  mkdir -p "$BASE_DIR"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/quantus-mining.XXXXXX")"
  trap 'rm -f "${tmp:-}"' RETURN
  info "从 Quantus 官方文档下载安装器……"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$OFFICIAL_URL" -o "$tmp"
  [ -s "$tmp" ] || die "官方安装器下载为空。"
  /bin/bash -n "$tmp" || die "官方安装器语法检查失败，已停止。"
  grep -q 'readonly CHAIN_REPO="Quantus-Network/chain"' "$tmp" || die "官方节点仓库标识不匹配，已停止。"
  grep -q 'readonly MINER_REPO="Quantus-Network/quantus-miner"' "$tmp" || die "官方矿工仓库标识不匹配，已停止。"
  grep -q 'NODE_TARGET="aarch64-apple-darwin"' "$tmp" || die "官方安装器缺少 Apple Silicon 节点目标，已停止。"
  grep -q 'MINER_ASSET="quantus-miner-macos-aarch64"' "$tmp" || die "官方安装器缺少 Apple Silicon 矿工目标，已停止。"
  install -m 700 "$tmp" "$OFFICIAL_SCRIPT"
  info "官方安装器已保存：$OFFICIAL_SCRIPT"
  info "SHA-256：$(shasum -a 256 "$OFFICIAL_SCRIPT" | awk '{print $1}')"
}

official_default_chain() {
  [ -f "$OFFICIAL_SCRIPT" ] || return 1
  sed -n 's/^[[:space:]]*CHAIN="${CHAIN:-\([^}"]*\)}".*/\1/p' "$OFFICIAL_SCRIPT" | head -n 1
}

config_value() {
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 1
  awk -F= -v k="$key" '
    $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
      v=$2; sub(/[[:space:]#].*$/, "", v); gsub(/^[[:space:]\047\042]+|[[:space:]\047\042]+$/, "", v); print v; exit
    }
  ' "$CONFIG_FILE"
}

chain_name() {
  local c
  c="$(config_value CHAIN 2>/dev/null || true)"
  printf '%s' "${c:-unknown}"
}

require_official_mainnet() {
  local c official_c node_v miner_v protocol
  c="$(chain_name)"
  official_c="$(official_default_chain 2>/dev/null || true)"

  case "$(printf '%s' "$official_c" | tr '[:upper:]' '[:lower:]')" in
    planck|testnet|unknown|'')
      die "Quantus 官方安装器默认链仍为 '${official_c:-unknown}'，尚未确认主网；不会启动。"
      ;;
  esac

  [ "$c" = "$official_c" ] || die "本机配置链 '$c' 与官方链 '$official_c' 不一致。请先运行：$(self_command update)"
  node_v="$(config_value NODE_VERSION 2>/dev/null || true)"
  miner_v="$(config_value MINER_VERSION 2>/dev/null || true)"
  protocol="$(config_value MINER_PROTOCOL 2>/dev/null || true)"
  [ -n "$node_v" ] || die "配置缺少 NODE_VERSION，不允许启动。"
  [ -n "$miner_v" ] || die "配置缺少 MINER_VERSION，不允许启动。"
  [ "$protocol" = "auth" ] || die "节点与矿工没有确认 quantus-miner/2 认证协议匹配，不允许启动。"
  info "官方主网核对通过：CHAIN=$c，NODE=$node_v，MINER=$miner_v，PROTOCOL=$protocol"
}

install_or_prepare() {
  download_official
  info "开始官方交互式 setup。期间生成/导入24词钱包时，请自己离线保存；不要发给任何人。"
  "$OFFICIAL_SCRIPT" setup

  # Coexistence profile for M4: Metal GPU enabled; no extra CPU workers by default.
  "$OFFICIAL_SCRIPT" config set CPU_WORKERS "${CPU_WORKERS:-0}" || true
  "$OFFICIAL_SCRIPT" config set GPU_DEVICES "${GPU_DEVICES:-1}" || true

  info "准备完成。当前 CHAIN=$(chain_name)"
  if [ "$(printf '%s' "$(chain_name)" | tr '[:upper:]' '[:lower:]')" = "planck" ]; then
    warn "现在还是 Planck 测试网，本脚本没有启动。主网上线确认后运行 update，再运行 start。"
  else
    warn "请先核对官方主网公告，再手动运行：$(self_command start)"
  fi
}

update_install() {
  local official_c backup_stamp
  download_official
  official_c="$(official_default_chain 2>/dev/null || true)"
  case "$(printf '%s' "$official_c" | tr '[:upper:]' '[:lower:]')" in
    planck|testnet|unknown|'')
      die "官方安装器默认链仍为 '${official_c:-unknown}'。没有更新主网配置，也没有启动。"
      ;;
  esac
  backup_stamp="$(date '+%Y%m%d_%H%M%S')"
  [ ! -f "$CONFIG_FILE" ] || cp -p "$CONFIG_FILE" "${CONFIG_FILE}.backup_${backup_stamp}"
  info "官方默认链已变更为 '$official_c'，刷新官方节点与矿工匹配版本……"
  CHAIN="$official_c" "$OFFICIAL_SCRIPT" setup --force
  info "更新完成。当前 CHAIN=$(chain_name)"
  require_official_mainnet
}

show_status() {
  printf '\n===== Quantus 状态 =====\n'
  printf '一键脚本：v%s\n' "$WRAPPER_VERSION"
  printf '目录：%s\n' "$BASE_DIR"
  printf '链：%s\n' "$(chain_name)"
  printf '官方安装器默认链：%s\n' "$(official_default_chain 2>/dev/null || printf unknown)"
  if pgrep -f '[q]uantus-node' >/dev/null 2>&1; then printf '节点：运行中\n'; else printf '节点：未运行\n'; fi
  if pgrep -f '[q]uantus-miner' >/dev/null 2>&1; then printf '矿工：运行中\n'; else printf '矿工：未运行\n'; fi
  [ -x "$OFFICIAL_SCRIPT" ] && "$OFFICIAL_SCRIPT" config show || true
}

show_logs() {
  [ -d "$BASE_DIR/logs" ] || die "还没有日志目录，请先安装并启动。"
  info "按 Control+C 退出日志，不会停止后台矿工。"
  if [ -f "$BASE_DIR/logs/miner.log" ]; then
    tail -n 100 -F "$BASE_DIR/logs/miner.log"
  else
    local node_log="${HOME}/Library/Application Support/quantus-node/chains/$(chain_name)/network/quantus-node.log"
    [ -f "$node_log" ] || die "暂时找不到 miner.log 或节点日志。"
    tail -n 100 -F "$node_log"
  fi
}

require_mac_arm

case "$ACTION" in
  install|prepare) install_or_prepare ;;
  update) update_install ;;
  start)
    [ -x "$OFFICIAL_SCRIPT" ] || die "尚未安装，请先运行 install。"
    download_official
    require_official_mainnet
    info "后台启动 Quantus 节点和矿工……"
    "$OFFICIAL_SCRIPT" start --detach
    show_status
    ;;
  testnet-start)
    [ "${ALLOW_TESTNET:-0}" = "1" ] || die "测试网启动被锁定。如确实只想测试，使用 ALLOW_TESTNET=1 bash $0 testnet-start"
    [ -x "$OFFICIAL_SCRIPT" ] || die "尚未安装，请先运行 install。"
    "$OFFICIAL_SCRIPT" start --detach
    ;;
  stop)
    [ -x "$OFFICIAL_SCRIPT" ] || die "尚未安装。"
    "$OFFICIAL_SCRIPT" stop
    ;;
  restart)
    [ -x "$OFFICIAL_SCRIPT" ] || die "尚未安装。"
    download_official
    require_official_mainnet
    "$OFFICIAL_SCRIPT" stop || true
    "$OFFICIAL_SCRIPT" start --detach
    ;;
  status) show_status ;;
  logs) show_logs ;;
  uninstall)
    [ -x "$OFFICIAL_SCRIPT" ] || die "尚未安装。"
    warn "该操作会调用官方卸载流程。助记词如未备份，先按 Control+C 取消。"
    "$OFFICIAL_SCRIPT" uninstall
    ;;
  help|-h|--help)
    printf 'Quantus Mac 一键脚本 v%s\n\n' "$WRAPPER_VERSION"
    printf '安装准备：%s\n' "$(self_command install)"
    printf '更新版本：%s\n' "$(self_command update)"
    printf '查看状态：%s\n' "$(self_command status)"
    printf '启动主网：%s\n' "$(self_command start)"
    printf '查看日志：%s\n' "$(self_command logs)"
    printf '停止运行：%s\n' "$(self_command stop)"
    ;;
  *)
    printf '用法：%s {install|update|start|stop|restart|status|logs|uninstall}\n' "$(self_command ACTION)"
    exit 2
    ;;
esac
