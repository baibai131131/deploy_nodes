#!/bin/zsh
set -u
setopt null_glob
umask 077

# IOTA Train at Home unified read-only diagnostic exporter for macOS.
VERSION="1.0.0"
LOGDIR="$HOME/Library/Logs/IOTA Train at Home"
STAMP=$(date '+%Y%m%d_%H%M%S')
DESKTOP="$HOME/Desktop"
[[ -d "$DESKTOP" ]] || DESKTOP="$HOME"
OUT="$DESKTOP/IOTA_DIAG_${STAMP}.txt"
TMP="${TMPDIR:-/tmp}/iota-diag-${UID}-${STAMP}"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

section(){ print; print -r -- "===== $1 ====="; }
safe_cmd(){ "$@" 2>&1 || true; }

FILES=("$LOGDIR"/*-cli.log)
LATEST=""
if (( ${#FILES[@]} > 0 )); then
  LATEST=$(/bin/ls -t "${FILES[@]}" 2>/dev/null | /usr/bin/head -1)
fi

sanitize(){
  /usr/bin/sed -E \
    -e 's/(--payout-coldkey[[:space:]]+)[1-9A-HJ-NP-Za-km-z]+/\1[PUBLIC_ADDRESS_REDACTED]/g' \
    -e 's#(https?://[^[:space:]?]+)\?[^[:space:]]+#\1?[QUERY_REDACTED]#g' \
    -e 's/(password|passwd|mnemonic|seed|private[_ -]?key|secret|api[_ -]?key|bearer)[=:[:space:]]+[^, }]+/\1=[REDACTED]/Ig'
}

{
  print -r -- "IOTA Train at Home 统一诊断报告 v${VERSION}"
  print -r -- "说明：只读采集；未读取任何钱包密钥文件。"

  section "时间与设备"
  date '+当前时间：%Y-%m-%d %H:%M:%S %Z'
  print -r -- "电脑名称：$(scutil --get ComputerName 2>/dev/null || hostname)"
  print -r -- "主机名称：$(hostname)"
  print -r -- "系统：$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
  print -r -- "架构：$(uname -m)"
  print -r -- "运行时长：$(uptime | sed 's/^[[:space:]]*//')"
  APP_VERSION=$(defaults read '/Applications/IOTA Train at Home.app/Contents/Info' CFBundleShortVersionString 2>/dev/null || echo UNKNOWN)
  print -r -- "IOTA客户端版本：$APP_VERSION"

  section "最新日志"
  if [[ -n "$LATEST" && -f "$LATEST" ]]; then
    NOW=$(date +%s)
    MTIME=$(stat -f %m "$LATEST" 2>/dev/null || echo 0)
    SIZE=$(stat -f %z "$LATEST" 2>/dev/null || echo 0)
    print -r -- "日志文件：${LATEST:t}"
    print -r -- "日志更新时间：$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$LATEST" 2>/dev/null)"
    print -r -- "距离更新：$((NOW-MTIME))秒"
    print -r -- "日志大小：${SIZE} bytes"
  else
    print -r -- "未找到 *-cli.log"
  fi

  section "IOTA进程（不包含钱包参数）"
  PIDS=($(pgrep -f '/Applications/IOTA Train at Home.app' 2>/dev/null || true))
  if (( ${#PIDS[@]} > 0 )); then
    print -r -- "PID PPID %CPU %MEM RSS(KB) ELAPSED EXECUTABLE"
    for P in "${PIDS[@]}"; do
      ps -ww -p "$P" -o pid=,ppid=,%cpu=,%mem=,rss=,etime=,comm= 2>/dev/null || true
    done
  else
    print -r -- "未发现IOTA进程"
  fi

  section "系统资源"
  safe_cmd df -h /
  print -r -- "--- memory_pressure ---"
  if command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure 2>&1 | /usr/bin/head -25
  else
    print -r -- "memory_pressure不可用"
  fi
  print -r -- "--- top memory processes ---"
  ps -Ao pid,%cpu,%mem,rss,comm -r 2>/dev/null | /usr/bin/head -15

  section "官方接口连通"
  if [[ "${IOTA_DIAG_SKIP_NET:-0}" == 1 ]]; then
    print -r -- "测试模式：已跳过联网检查"
  else
    API='https://iota-web.api.macrocosmos.ai/mainnet/runs'
    CURL_RESULT=$(/usr/bin/curl -L -sS -o /dev/null --connect-timeout 8 --max-time 15 \
      -w 'HTTP=%{http_code} DNS=%{time_namelookup}s CONNECT=%{time_connect}s TLS=%{time_appconnect}s TOTAL=%{time_total}s REMOTE=%{remote_ip}' \
      "$API" 2>&1 || true)
    print -r -- "$CURL_RESULT"
  fi

  if [[ -z "$LATEST" || ! -f "$LATEST" ]]; then
    section "结论所需数据"
    print -r -- "无IOTA日志，无法继续分析。"
  else
    section "最近队列名次（最多30条）"
    tail -n 20000 "$LATEST" | grep -E "register/status|status[^A-Za-z]*queued|position" | tail -30 | sanitize

    section "最近Run与Heartbeat（最多40条）"
    tail -n 20000 "$LATEST" | grep -Ei "selected_run|selected run|run_id|heartbeat.*response|assigned.*layer|epoch" | tail -40 | sanitize

    section "最近有效训练活动（最多80条）"
    tail -n 20000 "$LATEST" | grep -E "Activation push (RECV|OUTBOUND|SEND)|Start (forward|backward|upload activation|submit activation)|End (forward|backward|upload activation|submit activation)|submit_activation|submit_weights|merging.partition" | tail -80 | sanitize

    section "最近注册、重置、退出和错误（最多160条）"
    tail -n 30000 "$LATEST" | grep -Ei "not registered|EntityNotRegistered|Resetting miner|waitlist|queue_state|miner.kicked|training failed|process exited|exited with code|SIGABRT|SIGKILL|out of memory|oom|exception|traceback|failed|error|timeout|connection reset|timed out|speedtest" | tail -160 | sanitize

    section "最近P2P状态（最多60条）"
    tail -n 20000 "$LATEST" | grep -Ei "Broadcast peer status|p2p_node_ids|adjacent-layer peer|peer.*(lost|disconnect|timeout)|activation.*(drop|timeout|nack)" | tail -60 | sanitize

    section "最后一次自动退出或重置的上下文"
    MATCH=$(grep -nE "Resetting miner entire state|Miner not registered|miner.kicked|Training failed|process exited|SIGABRT|SIGKILL" "$LATEST" | tail -1 || true)
    if [[ -n "$MATCH" ]]; then
      LINE=${MATCH%%:*}
      START=$((LINE-120)); (( START < 1 )) && START=1
      END=$((LINE+120))
      sed -n "${START},${END}p" "$LATEST" | sanitize
    else
      print -r -- "未找到自动退出、重置或崩溃记录。"
    fi

    section "日志末尾原始上下文（最后200行，已脱敏）"
    tail -n 200 "$LATEST" | sanitize
  fi

  section "监控程序状态"
  GUI="gui/$(id -u)"
  for LABEL in com.baibai.iota-guardian-v5.monitor com.baibai.iota-guardian-v5.cleanup com.baibai.iota-guardian-v5.report; do
    if launchctl print "$GUI/$LABEL" >/dev/null 2>&1; then
      print -r -- "$LABEL：已运行"
    else
      print -r -- "$LABEL：未运行"
    fi
  done
} > "$TMP/report.txt" 2>&1

sanitize < "$TMP/report.txt" > "$OUT"
chmod 600 "$OUT"

echo
echo "✅ IOTA诊断报告已生成"
echo "文件：$OUT"
echo "请把这个TXT文件直接发给我分析。"
echo "脚本不会停止IOTA，也不会读取钱包密钥。"
open -R "$OUT" 2>/dev/null || true
