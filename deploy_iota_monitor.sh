#!/bin/zsh
set -euo pipefail
setopt null_glob
umask 077

# V5.2：兼容 4.12.x TAH activation/heartbeat 训练协议，并保留旧 Run 识别。
[[ "$(uname -s)" == Darwin ]] || { echo "本脚本仅支持 macOS。"; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo "请使用当前登录用户运行，不要使用 sudo。"; exit 1; }
GUI_DOMAIN="gui/$(id -u)"
launchctl print "$GUI_DOMAIN" >/dev/null 2>&1 || {
  echo "请在已登录桌面的 Mac 终端运行。"; exit 1;
}

VERSION="5.2.0"
BASE="$HOME/.iota-guardian"
LAUNCH="$HOME/Library/LaunchAgents"
MONITOR_LABEL="com.baibai.iota-guardian-v5.monitor"
CLEAN_LABEL="com.baibai.iota-guardian-v5.cleanup"
REPORT_LABEL="com.baibai.iota-guardian-v5.report"
STAGE=""
MONITOR_PLIST="$LAUNCH/$MONITOR_LABEL.plist"
CLEAN_PLIST="$LAUNCH/$CLEAN_LABEL.plist"
REPORT_PLIST="$LAUNCH/$REPORT_LABEL.plist"
mkdir -p "$BASE" "$LAUNCH" "$BASE/reports" "$BASE/backups"
BACKUP=$(mktemp -d "$BASE/backups/before-v5.1-XXXXXXXX")
STAGE=$(mktemp -d "$BASE/install-stage-XXXXXXXX")
mkdir -p "$BACKUP/files" "$BACKUP/LaunchAgents"
# 备份不会包含模型，也不会修改 IOTA 的节点身份或应用数据。
for item in node_name push_url version monitor.sh cleanup.sh daily_report.sh show_report.sh status_engine.py live_view.py last_state queue_start_epoch low_p2p_count; do
  [[ ! -f "$BASE/$item" ]] || cp -p "$BASE/$item" "$BACKUP/files/$item"
done
trap 'echo "安装未完成。备份：$BACKUP；请保留此目录，勿上传（含 Push URL）。" >&2' ZERR

echo "=============================================="
echo " IOTA Guardian V5.2 真实状态版（兼容旧版与4.12.x）"
echo "=============================================="
echo "只监控、记录、告警和清理旧日志，不控制 IOTA。"
echo

# 继承旧版配置
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
fi

if [[ ! -f "$STAGE/node_name" ]]; then
  cp "$BASE/node_name" "$STAGE/node_name"
  cp "$BASE/push_url" "$STAGE/push_url"
fi
print -r -- "$VERSION" > "$STAGE/version"

cat > "$STAGE/monitor.sh" <<'MONITOR'
#!/bin/zsh
set -u
setopt null_glob
BASE="$HOME/.iota-guardian"
LOGDIR="$HOME/Library/Logs/IOTA Train at Home"
NODE=$(cat "$BASE/node_name" 2>/dev/null || echo UNKNOWN)
PUSH=$(cat "$BASE/push_url" 2>/dev/null || echo '')
PUSH="${PUSH%%\?*}"
NOW=$(date +%s)
NOWTXT=$(date '+%Y-%m-%d %H:%M:%S')
TODAY=$(date '+%Y-%m-%d')
RUNLOG="$BASE/guardian.log"
EVENTS="$BASE/events.csv"
SAMPLES="$BASE/samples-$TODAY.csv"
LAST="$BASE/last_state"
QUEUE_START="$BASE/queue_start_epoch"
LOWP2P="$BASE/low_p2p_count"

trim(){ [[ -f "$1" ]] || return 0; tail -n "$2" "$1" > "$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"; }
log(){ echo "$NOWTXT | $NODE | $1" >> "$RUNLOG"; trim "$RUNLOG" 1500; }
disk(){ df -Pk / | awk 'NR==2{gsub("%","",$5);print $5}'; }
duration(){ local s=${1:-0}; local h=$((s/3600)); local m=$(((s%3600)/60)); ((h>0)) && echo "${h}小时${m}分钟" || echo "${m}分钟"; }

send(){
  local st="$1" msg="$2"
  print -r -- "$msg" > "$BASE/current_message"
  if [[ -n "$PUSH" ]] && /usr/bin/curl -fsS --get --connect-timeout 8 --max-time 15 \
      --data-urlencode "status=$st" --data-urlencode "msg=$msg" "$PUSH" >/dev/null 2>&1; then
    log "$msg | PUSH_OK"
  else
    log "$msg | PUSH_FAILED"
  fi
}

finish(){
  local state="$1" kuma_status="$2" msg="$3" age="${4:-0}" pos="${5:-}" p2p="${6:-}"
  local old=$(cat "$LAST" 2>/dev/null || echo '')
  print -r -- "$state" > "$BASE/current_state"
  if [[ "$state" != "$old" ]]; then
    [[ -f "$EVENTS" ]] || echo 'time,node,state,message' > "$EVENTS"
    echo "\"$NOWTXT\",\"$NODE\",\"$state\",\"${msg//\"/\"\"}\"" >> "$EVENTS"
    trim "$EVENTS" 10000
  fi
  print -r -- "$state" > "$LAST"
  [[ -f "$SAMPLES" ]] || echo 'time,node,state,log_age,disk,queue_position,p2p' > "$SAMPLES"
  echo "\"$NOWTXT\",\"$NODE\",\"$state\",\"$age\",\"$(disk)\",\"$pos\",\"$p2p\"" >> "$SAMPLES"
  find "$BASE" -maxdepth 1 -name 'samples-*.csv' -mtime +31 -delete 2>/dev/null || true
  send "$kuma_status" "$msg"
  exit 0
}

D=$(disk)
FILES=("$LOGDIR"/*-cli.log)
(( ${#FILES[@]} > 0 )) || finish NO_LOG down "🔴 无日志 | NO_LOG | 未找到IOTA日志 | 磁盘${D}%" 999999
LATEST=$(/bin/ls -t "${FILES[@]}" 2>/dev/null | head -1)
[[ -f "$LATEST" ]] || finish NO_LOG down "🔴 无日志 | NO_LOG | 没有找到有效IOTA日志 | 磁盘${D}%" 999999
MT=$(/usr/bin/stat -f %m "$LATEST" 2>/dev/null || echo 0)
AGE=$((NOW-MT))

APP=0; CLI=0
/usr/bin/pgrep -f '/Applications/IOTA Train at Home.app/Contents/MacOS/IOTA Train at Home' >/dev/null 2>&1 && APP=1
/usr/bin/pgrep -f '/Applications/IOTA Train at Home.app/Contents/Frameworks/iota-cli/main_pool' >/dev/null 2>&1 && CLI=1
(( APP==1 || CLI==1 )) || finish STOPPED down "🔴 IOTA停止 | STOPPED | 需要打开IOTA并点击Start training | 日志${AGE}秒 | 磁盘${D}%" "$AGE"
(( AGE<=180 )) || finish STALE down "🔴 日志故障 | STALE | 日志${AGE}秒未更新 | 程序可能卡住 | 磁盘${D}%" "$AGE"

RESULT=$(/usr/bin/tail -n 8000 "$LATEST" | /usr/bin/awk '
BEGIN{s="UNKNOWN";p="";ok="";tot="";run="";layer="";epoch="";mstatus=""}
{
 l=$0
 if(l~/signal=SIGABRT/||l~/miner process exited/)s="CRASHED"
 if(l~/Closing IOTA Cli/||l~/Cleaning up miner on shutdown/||l~/P2P shutdown complete/)s="STOPPED"
 if(l~/Resetting miner entire state/||l~/EntityNotRegistered/||l~/miner.kicked/)s="RESETTING"
 if(l~/Attempting to join registration waitlist/||l~/status.*queued/){s="QUEUED";if(match(l,/position[^0-9]*[0-9]+/)){t=substr(l,RSTART,RLENGTH);gsub(/[^0-9]/,"",t);p=t}}
 if((l~/training.state accepted/&&l~/state:.*training/)||l~/submit_weights:/||l~/Getting pseudo gradients/||l~/miner.training.training:/||l~/optimization_reset:/||l~/Resetting after optimization step/)s="TRAINING"
 # 4.12.x 的真实训练活动。失败/NACK本身不作为开始训练的依据。
 if(l~/Activation push (RECV|OUTBOUND)/||
    (l~/Activation push SEND/&&l!~/NACK/&&l!~/Failed/)||
    l~/name[^A-Za-z]*submit_activation/||
    l~/\/miner\/submit_activation; response:/||
    l~/(Start|End) (forward|backward|upload activation|submit activation)/)s="TRAINING"
 # heartbeat 是当前Run、层、epoch和本机状态的权威来源。
 if(l~/heartbeat.*response:/){
   if(match(l,/run_id[^A-Za-z0-9]*[A-Za-z0-9._-]+/)){t=substr(l,RSTART,RLENGTH);sub(/.*run_id[^A-Za-z0-9]*/,"",t);run=t}
   if(match(l,/layer[^0-9]*[0-9]+/)){t=substr(l,RSTART,RLENGTH);gsub(/[^0-9]/,"",t);layer=t}
   if(match(l,/epoch[^0-9]*[0-9]+/)){t=substr(l,RSTART,RLENGTH);gsub(/[^0-9]/,"",t);epoch=t}
   if(match(l,/status[^A-Za-z]*(initializing|idle|training|ready|running)/)){t=substr(l,RSTART,RLENGTH);sub(/.*status[^A-Za-z]*/,"",t);mstatus=t}
   if(l~/phase[^A-Za-z]*training/){
     if(mstatus=="initializing")s="INITIALIZING"
     else if(mstatus=="idle"||mstatus=="training"||mstatus=="ready"||mstatus=="running")s="TRAINING"
   }
 }
 if(match(l,/Broadcast peer status: [0-9]+\/[0-9]+ ok/)){t=substr(l,RSTART,RLENGTH);sub(/Broadcast peer status: /,"",t);sub(/ ok/,"",t);split(t,a,"/");ok=a[1];tot=a[2]}
}
END{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",s,p,ok,tot,run,layer,epoch,mstatus}')
IFS=$'\t' read -r STATE POS POK PTOT RUNID LAYER EPOCH MINER_STATUS <<< "$RESULT"
[[ -n "$STATE" && "$STATE" != UNKNOWN ]] || { ((CLI==1)) && STATE=STARTING || STATE=STOPPED; }

RUNINFO=""
[[ -n "$RUNID" ]] && RUNINFO="Run ${RUNID}"
[[ -n "$LAYER" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }L${LAYER}"
[[ -n "$EPOCH" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }E${EPOCH}"
[[ -n "$MINER_STATUS" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }${MINER_STATUS}"
[[ -n "$RUNINFO" ]] || RUNINFO="Run待更新"

OLD=$(cat "$LAST" 2>/dev/null || echo '')
if [[ "$STATE" == QUEUED ]]; then
  if [[ "$OLD" != QUEUED || ! -s "$QUEUE_START" ]]; then print -r -- "$NOW" > "$QUEUE_START"; fi
else
  rm -f "$QUEUE_START"
fi
QTXT=''
if [[ "$STATE" == QUEUED && -s "$QUEUE_START" ]]; then QS=$(cat "$QUEUE_START"); QTXT=$(duration $((NOW-QS))); fi

P2P=''
LOW=0
if [[ -n "$POK" && -n "$PTOT" && "$PTOT" -gt 0 ]]; then
  P2P="$POK/$PTOT"
  if [[ "$STATE" == TRAINING || "$STATE" == INITIALIZING ]]; then
    if (( POK*4<PTOT )); then C=$(cat "$LOWP2P" 2>/dev/null || echo 0); C=$((C+1)); print -r -- "$C" > "$LOWP2P"; ((C>=10))&&LOW=1; else print 0 > "$LOWP2P"; fi
  else
    print 0 > "$LOWP2P"
  fi
fi

case "$STATE" in
 TRAINING)
   STATUS=up
   MSG="🟢 真实训练 | TRAINING | ${RUNINFO} | P2P ${P2P:-待更新} | activation/heartbeat有效 | 日志${AGE}秒 | 磁盘${D}%"
   ;;
 INITIALIZING)
   STATUS=down
   MSG="🟠 训练池初始化 | INITIALIZING | ${RUNINFO} | 尚未接收有效activation | P2P ${P2P:-待更新} | 日志${AGE}秒 | 磁盘${D}%"
   ;;
 QUEUED)
   STATUS=up
   if [[ -n "$POS" ]]; then
     MSG="🟢 正常排队 | QUEUED | 位置${POS} | 已排${QTXT:-0分钟} | 程序运行（Stop training） | 日志${AGE}秒 | 磁盘${D}%"
   else
     MSG="🟢 正常排队 | QUEUED | 已排${QTXT:-0分钟} | 程序运行（Stop training） | 日志${AGE}秒 | 磁盘${D}%"
   fi
   ;;
 RESETTING)
   STATUS=down
   MSG="🔴 重新注册 | RESETTING | 已失去注册或被重置 | 日志${AGE}秒 | 磁盘${D}%"
   ;;
 CRASHED)
   STATUS=down
   MSG="🔴 程序崩溃 | CRASHED | miner进程异常退出 | 日志${AGE}秒 | 磁盘${D}%"
   ;;
 STARTING)
   STATUS=down
   MSG="🔴 状态未确认 | STARTING | 检查是否显示Start training | 日志${AGE}秒 | 磁盘${D}%"
   ;;
 STOPPED)
   STATUS=down
   MSG="🔴 IOTA停止 | STOPPED | 需要点击Start training | 日志${AGE}秒 | 磁盘${D}%"
   ;;
 *)
   STATUS=down
   MSG="🔴 无法识别 | UNKNOWN | 检查IOTA界面与日志 | 日志${AGE}秒 | 磁盘${D}%"
   ;;
esac
if ((LOW!=0)); then
  STATUS=down
  MSG="🔴 训练中但P2P严重异常 | ${STATE} | ${RUNINFO} | P2P ${P2P:-待更新} | 连续10分钟低于25% | 日志${AGE}秒 | 磁盘${D}%"
fi
((D<90)) || { STATUS=down; MSG="🔴 磁盘故障 | $MSG | 磁盘严重不足"; }
finish "$STATE" "$STATUS" "$MSG" "$AGE" "$POS" "$P2P"
MONITOR

cat > "$STAGE/cleanup.sh" <<'CLEANUP'
#!/bin/zsh
set -u
BASE="$HOME/.iota-guardian"
LOGDIR="$HOME/Library/Logs/IOTA Train at Home"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
B=$(du -sk "$LOGDIR" 2>/dev/null|awk '{print $1}'); B=${B:-0}
find "$LOGDIR" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.gz' \) -mtime +14 -delete 2>/dev/null || true
find "$HOME/Library/Logs/DiagnosticReports" -type f \( -iname '*iota*' -o -iname '*main_pool*' \) -mtime +30 -delete 2>/dev/null || true
A=$(du -sk "$LOGDIR" 2>/dev/null|awk '{print $1}'); A=${A:-0}; F=$((B-A)); ((F<0))&&F=0
echo "$NOW | IOTA日志 ${B}KB→${A}KB | 释放${F}KB" >> "$BASE/cleanup.log"
tail -n 300 "$BASE/cleanup.log" > "$BASE/cleanup.log.tmp" 2>/dev/null && mv "$BASE/cleanup.log.tmp" "$BASE/cleanup.log"
CLEANUP

cat > "$STAGE/daily_report.sh" <<'REPORT'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
TODAY=$(date '+%Y-%m-%d')
S="$BASE/samples-$TODAY.csv"
R="$BASE/reports/$TODAY.txt"
mkdir -p "$BASE/reports"
count(){ grep -c ",\"$1\"," "$S" 2>/dev/null || true; }
cat > "$R" <<EOF2
IOTA Guardian V5.2 每日报告
日期：$TODAY
电脑：$(cat "$BASE/node_name" 2>/dev/null)
TRAINING：约 $(count TRAINING) 分钟
QUEUED：约 $(count QUEUED) 分钟
RESETTING：约 $(count RESETTING) 分钟
CRASHED：约 $(count CRASHED) 分钟
STOPPED：约 $(count STOPPED) 分钟
STALE：约 $(count STALE) 分钟
NO_LOG：约 $(count NO_LOG) 分钟
UNKNOWN：约 $(count UNKNOWN) 分钟
当前状态：$(cat "$BASE/current_message" 2>/dev/null)
EOF2
find "$BASE/reports" -type f -mtime +31 -delete 2>/dev/null || true
REPORT

cat > "$STAGE/show_report.sh" <<'SHOW'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
echo "===== IOTA Guardian V5.2 真实状态版 ====="
echo "版本：$(cat "$BASE/version" 2>/dev/null)"
echo "电脑：$(cat "$BASE/node_name" 2>/dev/null)"
echo "当前：$(cat "$BASE/current_message" 2>/dev/null)"
echo "Guardian占用：$(du -sh "$BASE" 2>/dev/null|awk '{print $1}')"
echo "IOTA日志占用：$(du -sh "$HOME/Library/Logs/IOTA Train at Home" 2>/dev/null|awk '{print $1}')"
echo "最近状态变化："
tail -n 15 "$BASE/events.csv" 2>/dev/null
SHOW
for item in monitor.sh cleanup.sh daily_report.sh show_report.sh; do
  zsh -n "$STAGE/$item"
  chmod 700 "$STAGE/$item"
done

cat > "$STAGE/$MONITOR_LABEL.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$MONITOR_LABEL</string><key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/monitor.sh</string></array><key>RunAtLoad</key><true/><key>StartInterval</key><integer>60</integer><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>$BASE/monitor-error.log</string></dict></plist>
EOF2
cat > "$STAGE/$CLEAN_LABEL.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$CLEAN_LABEL</string><key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/cleanup.sh</string></array><key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>20</integer></dict><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>$BASE/cleanup-error.log</string></dict></plist>
EOF2
cat > "$STAGE/$REPORT_LABEL.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$REPORT_LABEL</string><key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/daily_report.sh</string></array><key>StartCalendarInterval</key><dict><key>Hour</key><integer>23</integer><key>Minute</key><integer>55</integer></dict><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>$BASE/report-error.log</string></dict></plist>
EOF2

plutil -lint "$STAGE/$MONITOR_LABEL.plist" >/dev/null
plutil -lint "$STAGE/$CLEAN_LABEL.plist" >/dev/null
plutil -lint "$STAGE/$REPORT_LABEL.plist" >/dev/null

# 全部新文件通过检查后，再卸载旧监控。仅处理本系列 Guardian 任务。
# 把旧 plist 移出 LaunchAgents（不删除），防止 V6 下次登录再次启动。
for plist in "$LAUNCH"/com.baibai.iota-log-monitor.plist "$LAUNCH"/com.baibai.iota-guardian*.plist; do
  [[ -f "$plist" ]] || continue
  old_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")
  [[ "$old_label" == "${${plist:t}%.plist}" ]] || {
    echo "旧监控 plist 的标签不匹配，已停止安装：$plist"; exit 1;
  }
  if launchctl print "$GUI_DOMAIN/$old_label" >/dev/null 2>&1; then
    launchctl bootout "$GUI_DOMAIN/$old_label" || {
      echo "无法停止旧监控 $old_label，未覆盖程序。"; exit 1;
    }
  fi
  mv "$plist" "$BACKUP/LaunchAgents/"
done

for item in monitor.sh cleanup.sh daily_report.sh show_report.sh; do
  /usr/bin/install -m 700 "$STAGE/$item" "$BASE/$item"
done
for item in node_name push_url version; do
  /usr/bin/install -m 600 "$STAGE/$item" "$BASE/$item"
done
for label in "$MONITOR_LABEL" "$CLEAN_LABEL" "$REPORT_LABEL"; do
  /usr/bin/install -m 600 "$STAGE/$label.plist" "$LAUNCH/$label.plist"
done

launchctl bootstrap "$GUI_DOMAIN" "$MONITOR_PLIST"
launchctl bootstrap "$GUI_DOMAIN" "$CLEAN_PLIST"
launchctl bootstrap "$GUI_DOMAIN" "$REPORT_PLIST"
mv "$STAGE" "$BACKUP/staged-install"
trap - ZERR

echo
echo "✅ IOTA Guardian V5.2 真实状态版安装/升级完成"
echo "电脑：$(cat "$BASE/node_name")"
echo "检测频率：60秒"
echo "日志超过180秒：红色故障"
echo "Uptime Kuma心跳间隔：150秒"
echo "TRAINING：🟢 正常训练（详细信息）"
echo "INITIALIZING：🟠 已进训练池但尚未有效训练"
echo "QUEUED：🟢 正常排队（位置、时长、程序状态）"
echo "RESETTING、CRASHED、STOPPED、STALE、NO_LOG、UNKNOWN：🔴 故障"
echo "备份位置：$BACKUP（含私密配置，请勿上传）"
echo "请等待约60秒，在 Uptime Kuma 查看新心跳。"
echo "保留原版清理规则：IOTA日志超过14天、相关崩溃报告超过30天会清理。"
echo "本程序不会关闭、启动、重启或点击IOTA。"
