#!/bin/zsh
set -euo pipefail
setopt null_glob
umask 077

# IOTA Guardian V6.0：按最新事件和活动时效判断真实状态，兼容 TAH 3.7 / 4.12.x。
[[ "$(uname -s)" == Darwin ]] || { echo "本脚本仅支持 macOS。"; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo "请使用当前登录用户运行，不要使用 sudo。"; exit 1; }
GUI_DOMAIN="gui/$(id -u)"
launchctl print "$GUI_DOMAIN" >/dev/null 2>&1 || { echo "请在已登录桌面的 Mac 终端运行。"; exit 1; }

VERSION="6.0.0"
BASE="$HOME/.iota-guardian"
LAUNCH="$HOME/Library/LaunchAgents"
MONITOR_LABEL="com.baibai.iota-guardian-v6.monitor"
CLEAN_LABEL="com.baibai.iota-guardian-v6.cleanup"
REPORT_LABEL="com.baibai.iota-guardian-v6.report"
mkdir -p "$BASE" "$LAUNCH" "$BASE/reports" "$BASE/backups"
BACKUP=$(mktemp -d "$BASE/backups/before-v6-XXXXXXXX")
STAGE=$(mktemp -d "$BASE/install-stage-XXXXXXXX")
mkdir -p "$BACKUP/files" "$BACKUP/LaunchAgents"
for item in node_name push_url version monitor.sh status_engine.py cleanup.sh daily_report.sh show_report.sh last_state queue_start_epoch low_p2p_count; do
  [[ ! -f "$BASE/$item" ]] || cp -p "$BASE/$item" "$BACKUP/files/$item"
done
trap 'echo "安装未完成。备份：$BACKUP；请保留此目录，勿上传（含 Push URL）。" >&2' ZERR

echo "=============================================="
echo " IOTA Guardian V6.0 精准状态版"
echo "=============================================="
echo "只监控、记录、告警和清理旧日志，不控制或重启 IOTA。"
echo

# 自动继承旧版名称与 Push URL；新电脑则交互输入。
for old in "$HOME/.iota-guardian" "$HOME/.iota-monitor"; do
  [[ -s "$BASE/node_name" ]] || [[ ! -s "$old/node_name" ]] || cp "$old/node_name" "$BASE/node_name"
  [[ -s "$BASE/push_url" ]] || [[ ! -s "$old/push_url" ]] || cp "$old/push_url" "$BASE/push_url"
done
if [[ -s "$BASE/node_name" && -s "$BASE/push_url" ]]; then
  echo "检测到旧配置：$(cat "$BASE/node_name")"
  read "KEEP?继续使用原名称和 Push URL？输入 y： "
else
  KEEP="n"
fi
if [[ "${KEEP:-n}" != "y" && "${KEEP:-n}" != "Y" ]]; then
  read "NODE_NAME?请输入本机名称，例如 B1-M01： "
  read "PUSH_URL?请粘贴本机独立的 Uptime Kuma Push URL： "
  [[ -n "$NODE_NAME" ]] || { echo "名称不能为空"; exit 1; }
  [[ "$PUSH_URL" == http://* || "$PUSH_URL" == https://* ]] || { echo "Push URL格式错误"; exit 1; }
  print -r -- "$NODE_NAME" > "$STAGE/node_name"
  print -r -- "$PUSH_URL" > "$STAGE/push_url"
else
  cp "$BASE/node_name" "$STAGE/node_name"
  cp "$BASE/push_url" "$STAGE/push_url"
fi
print -r -- "$VERSION" > "$STAGE/version"

cat > "$STAGE/status_engine.py" <<'PY'
#!/usr/bin/python3
"""Parse the newest IOTA CLI log. Output one tab-separated status record."""
import re, sys, time
from datetime import datetime
from pathlib import Path

log = Path(sys.argv[1])
now = int(time.time())
try:
    # CLI 日志可能很大；最多读取尾部 16 MiB，避免监控程序自己占用大量内存。
    with log.open("rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 16 * 1024 * 1024))
        raw = fh.read()
    lines = raw.decode("utf-8", errors="replace").splitlines()[-20000:]
except Exception:
    print("UNKNOWN\t\t\t\t\t\t999999\t无法读取日志\t0\t0")
    raise SystemExit

ts_re = re.compile(r"(?:\[)?(20\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d)(?:\.\d+)?")
def line_epoch(line):
    m = ts_re.search(line)
    if not m:
        return None
    try:
        return int(datetime.strptime(m.group(1).replace("T", " "), "%Y-%m-%d %H:%M:%S").timestamp())
    except ValueError:
        return None

state = "UNKNOWN"
state_i = -1
state_ts = None
barrier_i = -1
pos = run = layer = epoch = p2p = ""
last_activity_i = -1
last_activity_ts = None
last_activity_name = ""
send_fail = send_ok = 0

def set_state(value, i, ts, hard=False):
    global state, state_i, state_ts, barrier_i
    state, state_i, state_ts = value, i, ts
    if hard:
        barrier_i = i

for i, line in enumerate(lines):
    low = line.lower()
    ts = line_epoch(line)

    m = re.search(r"position[^0-9]*([0-9]+)", line, re.I)
    if m: pos = m.group(1)
    m = re.search(r"run_id[^A-Za-z0-9]*['\"]?([A-Za-z0-9._-]+)", line, re.I)
    if m: run = m.group(1)
    m = re.search(r"(?:^|[^a-z])layer[^0-9]*([0-9]+)", line, re.I)
    if m: layer = m.group(1)
    m = re.search(r"epoch[^0-9]*([0-9]+)", line, re.I)
    if m: epoch = m.group(1)
    m = re.search(r"Broadcast peer status:\s*([0-9]+/[0-9]+)\s+ok", line, re.I)
    if m: p2p = m.group(1)

    # Newer state-changing events always override older activity.
    if ("signal=sigabrt" in low or "training exited with code=1" in low or
            "training process exited with code 1" in low or "miner process exited" in low):
        set_state("CRASHED", i, ts, True); continue
    if ("closing iota cli" in low or "cleaning up miner on shutdown" in low or
            "p2p shutdown complete" in low):
        set_state("STOPPED", i, ts, True); continue
    if ("resetting miner entire state" in low or "entitynotregistered" in low or
            "appears to have been kicked" in low or "miner.kicked" in low or
            "miner not registered error" in low):
        set_state("RESETTING", i, ts, True); continue
    if ("attempting to join registration waitlist" in low or
            re.search(r"status['\"]?\s*:\s*['\"]queued", low)):
        set_state("QUEUED", i, ts, True); continue
    if ("in state: merging_partitions" in low or "layer_phase" in low and "merging_partitions" in low or
            "getting weight partition info" in low or "has no partitions to merge" in low):
        set_state("MERGING", i, ts, True); continue
    if ("downloading weights for layer" in low or "start download and set global weights" in low or
            "processing batch" in low and "partitions" in low):
        set_state("SYNCING", i, ts, True); continue

    # A heartbeat proves Run membership, not actual computation.
    if "heartbeat" in low and "response:" in low and "error_name" not in low:
        phase = re.search(r"phase[^a-z]*(training|merging_partitions|weights_uploading|initializing|registration)", low)
        status = re.search(r"status[^a-z]*(initializing|idle|training|ready|running)", low)
        if phase:
            ph = phase.group(1)
            if ph == "merging_partitions": set_state("MERGING", i, ts)
            elif ph == "weights_uploading": set_state("SYNCING", i, ts)
            elif ph == "training":
                set_state("INITIALIZING" if status and status.group(1) == "initializing" else "RUN_IDLE", i, ts)

    # Only completed computation/data movement is counted as real training.
    strong = None
    if re.search(r"End (forward|backward)", line, re.I): strong = "计算完成"
    elif re.search(r"End (upload|submit) activation", line, re.I): strong = "activation完成"
    elif "activation push recv" in low and ("materialize done" in low or "pulled ingress" in low): strong = "收到activation"
    elif "/miner/submit_activation; response:" in low and "error" not in low: strong = "提交activation"
    elif "submit_weights:" in low or "getting pseudo gradients" in low or "optimization_reset:" in low: strong = "权重训练"
    if strong:
        last_activity_i, last_activity_ts, last_activity_name = i, ts, strong
        set_state("TRAINING", i, ts)

    if "failed to send" in low and "activation" in low: send_fail += 1
    if ("activation push send" in low and "success" in low) or "end upload activation" in low: send_ok += 1

activity_age = 999999 if last_activity_ts is None else max(0, now - last_activity_ts)
# 最近5分钟的有效计算优先于普通 idle heartbeat，但不能越过排队/重置/合并等新状态。
if activity_age <= 300 and last_activity_i > barrier_i:
    state = "TRAINING"
# 旧成功记录不能让机器一直冒充 TRAINING。
elif state == "TRAINING" and activity_age > 300:
    state = "RUN_IDLE"

detail = last_activity_name or "无近期有效训练事件"
values = [state, pos, run, layer, epoch, p2p, str(activity_age), detail, str(send_fail), str(send_ok)]
print("\t".join(v.replace("\t", " ").replace("\n", " ") for v in values))
PY

cat > "$STAGE/monitor.sh" <<'MONITOR'
#!/bin/zsh
set -u
setopt null_glob
BASE="$HOME/.iota-guardian"
LOGDIR="$HOME/Library/Logs/IOTA Train at Home"
NODE=$(cat "$BASE/node_name" 2>/dev/null || echo UNKNOWN)
PUSH=$(cat "$BASE/push_url" 2>/dev/null || echo '')
PUSH="${PUSH%%\?*}"
NOW=$(date +%s); NOWTXT=$(date '+%Y-%m-%d %H:%M:%S'); TODAY=$(date '+%Y-%m-%d')
RUNLOG="$BASE/guardian.log"; EVENTS="$BASE/events.csv"; SAMPLES="$BASE/samples-$TODAY.csv"
LAST="$BASE/last_state"; QUEUE_START="$BASE/queue_start_epoch"
trim(){ [[ -f "$1" ]] || return 0; tail -n "$2" "$1" > "$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"; }
log(){ echo "$NOWTXT | $NODE | $1" >> "$RUNLOG"; trim "$RUNLOG" 1500; }
disk(){ df -Pk / | awk 'NR==2{gsub("%","",$5);print $5}'; }
duration(){ local s=${1:-0}; local h=$((s/3600)); local m=$(((s%3600)/60)); ((h>0)) && echo "${h}小时${m}分钟" || echo "${m}分钟"; }
send(){
  local st="$1" msg="$2"; print -r -- "$msg" > "$BASE/current_message"
  if [[ -n "$PUSH" ]] && /usr/bin/curl -fsS --get --connect-timeout 8 --max-time 15 --data-urlencode "status=$st" --data-urlencode "msg=$msg" "$PUSH" >/dev/null 2>&1; then
    log "$msg | PUSH_OK"
  else log "$msg | PUSH_FAILED"; fi
}
finish(){
  local state="$1" kuma="$2" msg="$3" age="${4:-0}" pos="${5:-}" activity="${6:-999999}"
  local old=$(cat "$LAST" 2>/dev/null || echo '')
  print -r -- "$state" > "$BASE/current_state"
  if [[ "$state" != "$old" ]]; then
    [[ -f "$EVENTS" ]] || echo 'time,node,state,message' > "$EVENTS"
    echo "\"$NOWTXT\",\"$NODE\",\"$state\",\"${msg//\"/\"\"}\"" >> "$EVENTS"; trim "$EVENTS" 10000
  fi
  print -r -- "$state" > "$LAST"
  [[ -f "$SAMPLES" ]] || echo 'time,node,state,log_age,disk,queue_position,activity_age' > "$SAMPLES"
  echo "\"$NOWTXT\",\"$NODE\",\"$state\",\"$age\",\"$(disk)\",\"$pos\",\"$activity\"" >> "$SAMPLES"
  find "$BASE" -maxdepth 1 -name 'samples-*.csv' -mtime +31 -delete 2>/dev/null || true
  send "$kuma" "$msg"; exit 0
}

D=$(disk); FILES=("$LOGDIR"/*-cli.log)
(( ${#FILES[@]} > 0 )) || finish NO_LOG down "🔴 无日志 | NO_LOG | 未找到 IOTA 日志 | 磁盘${D}%" 999999
LATEST=$(/bin/ls -t "${FILES[@]}" 2>/dev/null | head -1)
MT=$(/usr/bin/stat -f %m "$LATEST" 2>/dev/null || echo 0); AGE=$((NOW-MT))
APP=0; CLI=0
/usr/bin/pgrep -f '/Applications/IOTA Train at Home.app/Contents/MacOS/IOTA Train at Home' >/dev/null 2>&1 && APP=1
/usr/bin/pgrep -f 'IOTA Train at Home.app/Contents/Frameworks/.*/main_pool|IOTA Train at Home.app/Contents/Frameworks/iota-cli/main_pool' >/dev/null 2>&1 && CLI=1
(( APP==1 || CLI==1 )) || finish STOPPED down "🔴 IOTA停止 | STOPPED | 请打开 IOTA 并点击 Start training | 日志${AGE}秒 | 磁盘${D}%" "$AGE"
(( AGE<=180 )) || finish STALE down "🔴 日志卡住 | STALE | ${AGE}秒未更新 | 程序可能失联 | 磁盘${D}%" "$AGE"

RESULT=$(/usr/bin/python3 "$BASE/status_engine.py" "$LATEST" 2>/dev/null)
IFS=$'\t' read -r STATE POS RUNID LAYER EPOCH P2P ACTIVEAGE DETAIL FAILS OKS <<< "$RESULT"
[[ -n "${STATE:-}" ]] || STATE=UNKNOWN
CPU=$(/bin/ps -A -o %cpu=,command= | awk '/main_pool/ && !/awk/{s+=$1} END{printf "%.0f",s+0}')
RUNINFO=""; [[ -n "$RUNID" ]] && RUNINFO="Run ${RUNID}"; [[ -n "$LAYER" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }L${LAYER}"; [[ -n "$EPOCH" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }E${EPOCH}"; [[ -n "$RUNINFO" ]] || RUNINFO="Run待更新"
OLD=$(cat "$LAST" 2>/dev/null || echo '')
if [[ "$STATE" == QUEUED ]]; then
  [[ "$OLD" == QUEUED && -s "$QUEUE_START" ]] || print -r -- "$NOW" > "$QUEUE_START"
else rm -f "$QUEUE_START"; fi
QTXT=""; [[ "$STATE" == QUEUED && -s "$QUEUE_START" ]] && QTXT=$(duration $((NOW-$(cat "$QUEUE_START"))))
ATXT="无近期有效计算"; [[ "$ACTIVEAGE" != 999999 ]] && ATXT="上次有效计算$(duration "$ACTIVEAGE")前"

case "$STATE" in
 TRAINING) STATUS=up; MSG="🟢 真实训练 | TRAINING | ${RUNINFO} | ${DETAIL} | ${ATXT} | CPU ${CPU}% | P2P ${P2P:-待更新} | 日志${AGE}秒" ;;
 MERGING) STATUS=up; MSG="🟡 合并阶段 | MERGING | ${RUNINFO} | 当前没有训练计算属正常 | ${ATXT} | 日志${AGE}秒" ;;
 SYNCING) STATUS=up; MSG="🟡 权重同步 | SYNCING | ${RUNINFO} | 正在下载/设置模型权重 | CPU ${CPU}% | 日志${AGE}秒" ;;
 RUN_IDLE) STATUS=up; MSG="🟠 池内等待 | RUN_IDLE | ${RUNINFO} | 已在Run但近期无有效计算 | ${ATXT} | CPU ${CPU}% | 日志${AGE}秒" ;;
 INITIALIZING) STATUS=up; MSG="🟠 训练池初始化 | INITIALIZING | ${RUNINFO} | 尚未出现有效计算 | 日志${AGE}秒" ;;
 QUEUED) STATUS=up; MSG="🔵 正常排队 | QUEUED${POS:+ | 位置${POS}} | 已排${QTXT:-0分钟} | 尚未训练 | 日志${AGE}秒" ;;
 RESETTING) STATUS=down; MSG="🔴 注册被重置 | RESETTING | 已失去Run注册，等待重新排队 | 日志${AGE}秒" ;;
 CRASHED) STATUS=down; MSG="🔴 程序崩溃 | CRASHED | miner异常退出 | 日志${AGE}秒" ;;
 STOPPED) STATUS=down; MSG="🔴 IOTA停止 | STOPPED | 请点击 Start training | 日志${AGE}秒" ;;
 *) STATUS=down; MSG="🔴 状态未确认 | UNKNOWN | 进程存在但没有可确认状态 | CPU ${CPU}% | 日志${AGE}秒" ;;
esac
((D<90)) || { STATUS=down; MSG="🔴 磁盘严重不足 | ${D}% | $MSG"; }
finish "$STATE" "$STATUS" "$MSG" "$AGE" "$POS" "$ACTIVEAGE"
MONITOR

cat > "$STAGE/cleanup.sh" <<'CLEANUP'
#!/bin/zsh
set -u
BASE="$HOME/.iota-guardian"; LOGDIR="$HOME/Library/Logs/IOTA Train at Home"; NOW=$(date '+%Y-%m-%d %H:%M:%S')
B=$(du -sk "$LOGDIR" 2>/dev/null|awk '{print $1}'); B=${B:-0}
find "$LOGDIR" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.gz' \) -mtime +14 -delete 2>/dev/null || true
find "$HOME/Library/Logs/DiagnosticReports" -type f \( -iname '*iota*' -o -iname '*main_pool*' \) -mtime +30 -delete 2>/dev/null || true
A=$(du -sk "$LOGDIR" 2>/dev/null|awk '{print $1}'); A=${A:-0}; F=$((B-A)); ((F<0))&&F=0
echo "$NOW | IOTA日志 ${B}KB→${A}KB | 释放${F}KB" >> "$BASE/cleanup.log"
tail -n 300 "$BASE/cleanup.log" > "$BASE/cleanup.log.tmp" 2>/dev/null && mv "$BASE/cleanup.log.tmp" "$BASE/cleanup.log"
CLEANUP

cat > "$STAGE/daily_report.sh" <<'REPORT'
#!/bin/zsh
BASE="$HOME/.iota-guardian"; TODAY=$(date '+%Y-%m-%d'); S="$BASE/samples-$TODAY.csv"; R="$BASE/reports/$TODAY.txt"; mkdir -p "$BASE/reports"
count(){ grep -c ",\"$1\"," "$S" 2>/dev/null || true; }
cat > "$R" <<EOF2
IOTA Guardian V6.0 每日报告
日期：$TODAY
电脑：$(cat "$BASE/node_name" 2>/dev/null)
真实训练：约 $(count TRAINING) 分钟
合并阶段：约 $(count MERGING) 分钟
权重同步：约 $(count SYNCING) 分钟
池内等待：约 $(count RUN_IDLE) 分钟
排队：约 $(count QUEUED) 分钟
故障：RESETTING $(count RESETTING) / CRASHED $(count CRASHED) / STOPPED $(count STOPPED) / STALE $(count STALE) 分钟
当前：$(cat "$BASE/current_message" 2>/dev/null)
EOF2
find "$BASE/reports" -type f -mtime +31 -delete 2>/dev/null || true
REPORT

cat > "$STAGE/show_report.sh" <<'SHOW'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
echo "===== IOTA Guardian V6.0 精准状态版 ====="
echo "版本：$(cat "$BASE/version" 2>/dev/null)"
echo "电脑：$(cat "$BASE/node_name" 2>/dev/null)"
echo "当前：$(cat "$BASE/current_message" 2>/dev/null)"
echo "最近状态变化："; tail -n 15 "$BASE/events.csv" 2>/dev/null
SHOW

for item in monitor.sh cleanup.sh daily_report.sh show_report.sh; do chmod 700 "$STAGE/$item"; done
chmod 700 "$STAGE/status_engine.py"
/usr/bin/python3 -m py_compile "$STAGE/status_engine.py"

make_plist(){
  local label="$1" script="$2" schedule="$3"
  cat > "$STAGE/$label.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$label</string><key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/$script</string></array>$schedule<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>$BASE/${script%.sh}-error.log</string></dict></plist>
EOF2
}
make_plist "$MONITOR_LABEL" monitor.sh '<key>RunAtLoad</key><true/><key>StartInterval</key><integer>60</integer>'
make_plist "$CLEAN_LABEL" cleanup.sh '<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>20</integer></dict>'
make_plist "$REPORT_LABEL" daily_report.sh '<key>StartCalendarInterval</key><dict><key>Hour</key><integer>23</integer><key>Minute</key><integer>55</integer></dict>'
for label in "$MONITOR_LABEL" "$CLEAN_LABEL" "$REPORT_LABEL"; do plutil -lint "$STAGE/$label.plist" >/dev/null; done

# 仅停用本系列旧监控，不碰 IOTA、钱包、hotkey 或第三方 hub agent。
for plist in "$LAUNCH"/com.baibai.iota-log-monitor.plist "$LAUNCH"/com.baibai.iota-guardian*.plist; do
  [[ -f "$plist" ]] || continue
  old_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || echo '')
  [[ -n "$old_label" && "$old_label" == "${${plist:t}%.plist}" ]] || { echo "旧监控标签不匹配，停止安装：$plist"; exit 1; }
  launchctl print "$GUI_DOMAIN/$old_label" >/dev/null 2>&1 && launchctl bootout "$GUI_DOMAIN/$old_label"
  mv "$plist" "$BACKUP/LaunchAgents/"
done
for item in monitor.sh status_engine.py cleanup.sh daily_report.sh show_report.sh; do /usr/bin/install -m 700 "$STAGE/$item" "$BASE/$item"; done
for item in node_name push_url version; do /usr/bin/install -m 600 "$STAGE/$item" "$BASE/$item"; done
for label in "$MONITOR_LABEL" "$CLEAN_LABEL" "$REPORT_LABEL"; do /usr/bin/install -m 600 "$STAGE/$label.plist" "$LAUNCH/$label.plist"; launchctl bootstrap "$GUI_DOMAIN" "$LAUNCH/$label.plist"; done
mv "$STAGE" "$BACKUP/staged-install"; trap - ZERR

echo
echo "✅ IOTA Guardian V6.0 安装/升级完成"
echo "电脑：$(cat "$BASE/node_name")"
echo "60秒检测一次；日志超过180秒才判定 STALE。"
echo "TRAINING=真实计算；MERGING=合并；SYNCING=权重同步；RUN_IDLE=池内等待；QUEUED=排队。"
echo "本工具不会启动、停止、重启或点击 IOTA，也不会修改钱包和 miner。"
echo "请等待约60秒后查看 Uptime Kuma。"
