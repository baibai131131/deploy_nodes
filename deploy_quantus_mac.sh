#!/bin/bash
set -Eeuo pipefail

# Quantus macOS Apple Silicon safe wrapper
# Uses only the official Quantus installer and refuses to treat Planck testnet as mainnet.

WRAPPER_VERSION="2.2.0"

OFFICIAL_URL="https://docs.quantus.com/scripts/quantus-mining.sh"
SELF_URL="https://raw.githubusercontent.com/baibai131131/deploy_nodes/main/deploy_quantus_mac.sh"
BASE_DIR="${HOME}/quantus-mining"
OFFICIAL_SCRIPT="${BASE_DIR}/quantus-mining.sh"
OFFICIAL_SOURCE="${BASE_DIR}/quantus-mining.official.sh"
CONFIG_FILE="${BASE_DIR}/mining.conf"
NODE_NAME_FILE="${BASE_DIR}/node-name"
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
  install -m 700 "$tmp" "$OFFICIAL_SOURCE"
  info "官方原始安装器 SHA-256：$(shasum -a 256 "$OFFICIAL_SOURCE" | awk '{print $1}')"

  # Preserve the official source verbatim. The runnable copy only adds wrapper
  # hooks for automatic node names and reuse of an existing mining identity.
  local patched
  patched="${tmp}.patched"
  if ! awk '
    /^[[:space:]]*read -r -p "Enter a node name \(shown on telemetry\): " NODE_NAME[[:space:]]*$/ {
      print "  if [ -z \"${NODE_NAME:-}\" ]; then"
      print "    read -r -p \"Enter a node name (shown on telemetry): \" NODE_NAME"
      print "  fi"
      node_replaced++
      next
    }
    /^[[:space:]]*local choice output mnemonic[[:space:]]*$/ {
      print
      print ""
      print "  if [ -n \"${PRESET_INNER_HASH_FILE:-}\" ]; then"
      print "    [ -r \"$PRESET_INNER_HASH_FILE\" ] || die \"Preset inner hash file is not readable\""
      print "    IFS= read -r INNER_HASH < \"$PRESET_INNER_HASH_FILE\""
      print "    [ -n \"$INNER_HASH\" ] || die \"Preset inner hash is empty\""
      print "    WORMHOLE_ADDRESS=\"${PRESET_WORMHOLE_ADDRESS:-}\""
      print "    info \"Using the existing mining reward identity.\""
      print "    return 0"
      print "  fi"
      preset_added++
      next
    }
    /^[[:space:]]*read -r -p "Enter choice \(1\/2\) \[1\]: " choice[[:space:]]*$/ {
      print "  if [ -n \"${WALLET_MODE:-}\" ]; then"
      print "    choice=\"$WALLET_MODE\""
      print "  else"
      print "    read -r -p \"Enter choice (1/2) [1]: \" choice"
      print "  fi"
      wallet_replaced++
      next
    }
    { print }
    END {
      if (node_replaced != 1 || preset_added != 1 || wallet_replaced != 1) exit 42
    }
  ' "$OFFICIAL_SOURCE" > "$patched"; then
    rm -f "$patched"
    die "官方安装器的节点名称输入结构发生变化，安全停止。"
  fi
  /bin/bash -n "$patched" || die "名称自动化适配后语法检查失败，已停止。"
  install -m 700 "$patched" "$OFFICIAL_SCRIPT"
  rm -f "$patched"
  info "官方安装器已保存；已适配自动名称和安全复用挖矿身份。"
}

auto_node_name() {
  local existing token name
  if [ -s "$NODE_NAME_FILE" ]; then
    existing="$(tr -cd 'A-Za-z0-9._-' < "$NODE_NAME_FILE" | head -c 48)"
    [ -n "$existing" ] && { printf '%s' "$existing"; return 0; }
  fi
  existing="$(config_value NODE_NAME 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing" > "$NODE_NAME_FILE"
    chmod 600 "$NODE_NAME_FILE"
    printf '%s' "$existing"
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    token="$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]' | head -c 10)"
  else
    token="$(date '+%s')${RANDOM}${RANDOM}"
    token="$(printf '%s' "$token" | shasum -a 256 | awk '{print toupper(substr($1,1,10))}')"
  fi
  name="Quantus-${token}"
  printf '%s\n' "$name" > "$NODE_NAME_FILE"
  chmod 600 "$NODE_NAME_FILE"
  printf '%s' "$name"
}

official_default_chain() {
  [ -f "$OFFICIAL_SCRIPT" ] || return 1
  sed -n 's/^[[:space:]]*CHAIN="${CHAIN:-\([^}"]*\)}".*/\1/p' "$OFFICIAL_SCRIPT" | head -n 1
}

validate_inner_hash() {
  printf '%s' "$1" | grep -Eq '^0x[0-9A-Fa-f]{64}$' || \
    die "Inner Hash格式错误：必须是0x开头、后面64位十六进制。"
}

run_setup_with_identity() {
  local node_name="$1" force="$2" inner_hash="$3" address="${4:-}" secret_file rc=0
  validate_inner_hash "$inner_hash"
  secret_file="$(mktemp "${TMPDIR:-/tmp}/quantus-inner-hash.XXXXXX")"
  chmod 600 "$secret_file"
  printf '%s\n' "$inner_hash" > "$secret_file"
  if [ "$force" = "true" ]; then
    NODE_NAME="$node_name" PRESET_INNER_HASH_FILE="$secret_file" \
      PRESET_WORMHOLE_ADDRESS="$address" "$OFFICIAL_SCRIPT" setup --force || rc=$?
  else
    NODE_NAME="$node_name" PRESET_INNER_HASH_FILE="$secret_file" \
      PRESET_WORMHOLE_ADDRESS="$address" "$OFFICIAL_SCRIPT" setup || rc=$?
  fi
  rm -f "$secret_file"
  [ "$rc" -eq 0 ] || return "$rc"
}

fresh_wallet_setup() {
  local node_name="$1" choice inner_hash address
  printf '\n===== 奖励钱包选择 =====\n'
  printf '1. 自动生成新的Quantus挖矿钱包（第一台推荐）\n'
  printf '2. 导入已有Quantus钱包24词（输入隐藏）\n'
  printf '3. 复用已有挖矿身份（其他矿机推荐，不输入24词）\n\n'
  read -r -p '请选择 [1/2/3]：' choice
  case "$choice" in
    1)
      info "将由Quantus官方节点生成新钱包。务必手写保存24词、Address和Inner Hash。"
      NODE_NAME="$node_name" WALLET_MODE=2 "$OFFICIAL_SCRIPT" setup
      ;;
    2)
      info "请只输入Quantus钱包24词；终端输入不会显示。"
      NODE_NAME="$node_name" WALLET_MODE=1 "$OFFICIAL_SCRIPT" setup
      ;;
    3)
      read -r -p '奖励Address（可留空，之后由节点日志核对）：' address
      printf '请输入第一台保存的Inner Hash（输入隐藏）：'
      read -r -s inner_hash
      printf '\n'
      run_setup_with_identity "$node_name" false "$inner_hash" "$address"
      ;;
    *) die "选择无效，请重新运行安装命令并输入1、2或3。" ;;
  esac
}

existing_wallet_setup() {
  local node_name="$1" chain_override="${2:-}" inner_hash address
  inner_hash="$(config_value INNER_HASH 2>/dev/null || true)"
  address="$(config_value WORMHOLE_ADDRESS 2>/dev/null || true)"
  [ -n "$inner_hash" ] || die "现有配置缺少Inner Hash，无法安全更新。"
  if [ -n "$chain_override" ]; then
    CHAIN="$chain_override" run_setup_with_identity "$node_name" true "$inner_hash" "$address"
  else
    run_setup_with_identity "$node_name" true "$inner_hash" "$address"
  fi
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
  local node_name
  download_official
  node_name="$(auto_node_name)"
  info "本机自动节点名称：$node_name"
  if [ -f "$CONFIG_FILE" ]; then
    info "检测到现有配置：自动保留节点名称和奖励钱包，不再要求输入24词。"
    existing_wallet_setup "$node_name"
  else
    fresh_wallet_setup "$node_name"
  fi

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
  local official_c backup_stamp node_name
  download_official
  official_c="$(official_default_chain 2>/dev/null || true)"
  case "$(printf '%s' "$official_c" | tr '[:upper:]' '[:lower:]')" in
    planck|testnet|unknown|'')
      die "官方安装器默认链仍为 '${official_c:-unknown}'。没有更新主网配置，也没有启动。"
      ;;
  esac
  backup_stamp="$(date '+%Y%m%d_%H%M%S')"
  [ ! -f "$CONFIG_FILE" ] || cp -p "$CONFIG_FILE" "${CONFIG_FILE}.backup_${backup_stamp}"
  node_name="$(auto_node_name)"
  info "官方默认链已变更为 '$official_c'，刷新官方节点与矿工匹配版本……"
  existing_wallet_setup "$node_name" "$official_c"
  info "更新完成。当前 CHAIN=$(chain_name)"
  require_official_mainnet
}

show_status() {
  printf '\n===== Quantus 状态 =====\n'
  printf '一键脚本：v%s\n' "$WRAPPER_VERSION"
  printf '目录：%s\n' "$BASE_DIR"
  printf '节点名称：%s\n' "$(auto_node_name)"
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

show_identity() {
  local address inner_hash confirm
  [ -f "$CONFIG_FILE" ] || die "尚未安装。"
  address="$(config_value WORMHOLE_ADDRESS 2>/dev/null || true)"
  inner_hash="$(config_value INNER_HASH 2>/dev/null || true)"
  [ -n "$inner_hash" ] || die "配置中没有Inner Hash。"
  warn "Inner Hash属于敏感挖矿身份资料。只用于你自己的其他矿机，不要发给任何人。"
  read -r -p '输入 SHOW 确认在本终端显示：' confirm
  [ "$confirm" = "SHOW" ] || die "已取消显示。"
  printf 'WORMHOLE_ADDRESS=%s\n' "$address"
  printf 'INNER_HASH=%s\n' "$inner_hash"
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
  identity) show_identity ;;
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
    printf '显示挖矿身份：%s\n' "$(self_command identity)"
    printf '启动主网：%s\n' "$(self_command start)"
    printf '查看日志：%s\n' "$(self_command logs)"
    printf '停止运行：%s\n' "$(self_command stop)"
    ;;
  *)
    printf '用法：%s {install|update|start|stop|restart|status|identity|logs|uninstall}\n' "$(self_command ACTION)"
    exit 2
    ;;
esac
