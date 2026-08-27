#!/bin/zsh
set -euo pipefail
setopt null_glob

VERSION="6.0.0"
BASE="$HOME/.iota-guardian"
LAUNCH="$HOME/Library/LaunchAgents"
DESKTOP="$HOME/Desktop"
NODEOS_STATUS="$HOME/.nodeos/iota_monitor_status.json"

MONITOR_LABEL="com.baibai.iota-guardian-v6.monitor"
CLEAN_LABEL="com.baibai.iota-guardian-v6.cleanup"
REPORT_LABEL="com.baibai.iota-guardian-v6.report"

MONITOR_PLIST="$LAUNCH/$MONITOR_LABEL.plist"
CLEAN_PLIST="$LAUNCH/$CLEAN_LABEL.plist"
REPORT_PLIST="$LAUNCH/$REPORT_LABEL.plist"
VIEWER="$DESKTOP/IOTA实时排名.command"

clear
echo "============================================================"
echo "       IOTA Guardian V6.0 实时排名综合版"
echo "============================================================"
echo
echo "综合功能："
echo "  • 每30秒识别 TRAINING / QUEUED / STOP 等状态"
echo "  • Kuma直接显示当前排名、上次排名、本次变化"
echo "  • 桌面生成『IOTA实时排名.command』，双击持续刷新"
echo "  • 已安装NodeOS时读取其可靠实时字段；未安装也能直接解析日志"
echo "  • 只读取日志、记录、告警和清理旧日志，绝不控制IOTA"
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "❌ 此安装程序只支持 macOS。"
  read "?按回车退出..."
  exit 1
fi

PYTHON_BIN=$(command -v python3 2>/dev/null || true)
if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
  echo "❌ 没有找到 python3，暂时无法安装。"
  echo "   这台电脑已安装NodeOS时通常已经具备python3。"
  read "?按回车退出..."
  exit 1
fi

mkdir -p "$BASE" "$LAUNCH" "$DESKTOP" "$BASE/reports"
chmod 700 "$BASE"

# 继承V4/V5的名称和Uptime Kuma Push URL。
DEFAULT_NODE=$(/usr/sbin/scutil --get ComputerName 2>/dev/null || /bin/hostname -s)
OLD_NODE=$(cat "$BASE/node_name" 2>/dev/null || true)
OLD_URL=$(cat "$BASE/push_url" 2>/dev/null || true)
[[ -n "$OLD_NODE" ]] && DEFAULT_NODE="$OLD_NODE"

if [[ -n "$OLD_NODE" && -n "$OLD_URL" ]]; then
  echo "检测到旧版配置：$OLD_NODE"
  read "KEEP?继续使用原电脑名称和原Push URL？输入 y 继续［y］："
  KEEP="${KEEP:-y}"
else
  KEEP="n"
fi

if [[ "$KEEP" == [yY] ]]; then
  NODE_NAME="$OLD_NODE"
  PUSH_URL="$OLD_URL"
else
  read "NODE_NAME?请输入这台电脑名称［默认：$DEFAULT_NODE］："
  NODE_NAME="${NODE_NAME:-$DEFAULT_NODE}"
  echo
  echo "请粘贴这台电脑独立的 Uptime Kuma Push URL："
  read "PUSH_URL?Push URL："
fi

NODE_NAME="${NODE_NAME//[$'\r\n']/}"
PUSH_URL="${PUSH_URL//[$'\r\n ']/}"
[[ -n "$NODE_NAME" ]] || { echo "❌ 电脑名称不能为空。"; exit 1; }
[[ "$PUSH_URL" == http://* || "$PUSH_URL" == https://* ]] || {
  echo "❌ Push URL格式不正确，安装已取消。"
  read "?按回车退出..."
  exit 1
}

STAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP="$BASE/backups/$STAMP"
mkdir -p "$BACKUP"
for old_file in node_name push_url version monitor.sh cleanup.sh daily_report.sh show_report.sh status_engine.py live_view.py; do
  [[ -f "$BASE/$old_file" ]] && cp -p "$BASE/$old_file" "$BACKUP/$old_file"
done

STAGE=$(mktemp -d "$BASE/.v6-stage.XXXXXX")
cleanup_stage() {
  [[ -n "${STAGE:-}" && -d "$STAGE" ]] && /bin/rm -rf -- "$STAGE"
}
trap cleanup_stage EXIT INT TERM

cat > "$STAGE/status_engine.py" <<'PY_ENGINE'
#!/usr/bin/env python3
"""IOTA Guardian V6 status engine. Read-only: never controls IOTA."""

import argparse
import datetime as dt
import glob
import json
import os
import re
import sys
import tempfile

VERSION = "6.0.0"
VALID_STATES = {
    "TRAINING", "QUEUED", "STARTING", "RESETTING", "CRASHED",
    "STOPPED", "NEED_START", "STALE", "NO_LOG", "UNKNOWN",
}
STATE_TEXT = {
    "TRAINING": "正常训练",
    "QUEUED": "正常排队",
    "STARTING": "状态未确认",
    "RESETTING": "重新注册",
    "CRASHED": "程序崩溃",
    "STOPPED": "IOTA停止",
    "NEED_START": "需要点击Start training",
    "STALE": "日志超时",
    "NO_LOG": "无日志",
    "UNKNOWN": "无法识别",
}


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError, TypeError):
        return {} if default is None else default


def atomic_json(path, value):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".guardian-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            if os.path.exists(temporary):
                os.unlink(temporary)
        except OSError:
            pass


def read_tail(path, max_bytes=4 * 1024 * 1024):
    if not path or not os.path.isfile(path):
        return ""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            if size > max_bytes:
                handle.seek(size - max_bytes)
                handle.readline()
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def line_time(line):
    match = re.search(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?\]", line)
    return match.group(1) if match else None


def queue_fields(line):
    lower = line.lower()
    if "response" not in lower or "queued" not in lower or "position" not in lower:
        return None
    position_match = re.search(r"['\"]?position['\"]?\s*:\s*(\d+)", line, re.I)
    status_match = re.search(r"['\"]?status['\"]?\s*:\s*['\"]queued['\"]", line, re.I)
    if not position_match or not status_match:
        return None
    queue_match = re.search(r"['\"]?queue_id['\"]?\s*:\s*['\"]([^'\"]+)['\"]", line, re.I)
    return {
        "position": int(position_match.group(1)),
        "queue_id": queue_match.group(1) if queue_match else None,
        "updated_at": line_time(line),
    }


def native_parse(log_path):
    text = read_tail(log_path)
    state = "UNKNOWN"
    position = None
    queue_id = None
    queue_updated = None
    peer = None
    last_training = None
    forward_count = None
    activation_count = None
    attestation_count = None

    for line in text.splitlines():
        lower = line.lower()
        timestamp = line_time(line)

        parsed_queue = queue_fields(line)
        if parsed_queue:
            state = "QUEUED"
            position = parsed_queue["position"]
            queue_id = parsed_queue["queue_id"]
            queue_updated = parsed_queue["updated_at"]
            continue

        if "attempting to join registration waitlist" in lower:
            state = "QUEUED"
            position = None
            queue_id = None
            queue_updated = timestamp
            continue

        training_marker = (
            ("training.state accepted" in lower and re.search(r"state[^a-z]+training", lower))
            or "submit_weights:" in lower
            or "getting pseudo gradients" in lower
            or "miner.training.training:" in lower
            or "optimization_reset:" in lower
            or "resetting after optimization step" in lower
        )
        if training_marker:
            state = "TRAINING"
            position = None
            queue_id = None
            if timestamp:
                last_training = timestamp
            continue

        if (
            "resetting miner entire state" in lower
            or "entitynotregisterederror" in lower
            or "entity not registered" in lower
            or "miner.kicked" in lower
        ):
            state = "RESETTING"
            position = None
            queue_id = None
            continue

        if (
            "closing iota cli" in lower
            or "cleaning up miner on shutdown" in lower
            or "p2p shutdown complete" in lower
        ):
            state = "STOPPED"
            position = None
            queue_id = None
            continue

        if (
            "signal=sigabrt" in lower
            or "miner process exited" in lower
            or "uncaught exception" in lower
            or "fatal error" in lower
        ):
            state = "CRASHED"
            position = None
            queue_id = None
            continue

        if (
            "starting iota cli" in lower
            or "initializing miner" in lower
            or "starting miner" in lower
        ):
            state = "STARTING"
            continue

        peer_match = re.search(r"Broadcast peer status:\s*(\d+)\/(\d+)\s+ok", line, re.I)
        if peer_match:
            peer = f"{peer_match.group(1)}/{peer_match.group(2)}"
        else:
            peer_count_match = re.search(r"(?:peer_count|peer count)[^0-9]*(\d+)", line, re.I)
            if peer_count_match:
                peer = peer_count_match.group(1)

    return {
        "state": state,
        "source": "本地日志",
        "position": position,
        "previous_position": None,
        "initial_position": None,
        "queue_id": queue_id,
        "queue_updated": queue_updated,
        "peer": peer,
        "last_training": last_training,
        "forward_count": forward_count,
        "activation_count": activation_count,
        "attestation_count": attestation_count,
    }


def fresh_nodeos(path, now_epoch):
    if not path or not os.path.isfile(path):
        return None
    try:
        if now_epoch - int(os.path.getmtime(path)) > 120:
            return None
    except OSError:
        return None

    data = load_json(path)
    state = str(data.get("status") or "UNKNOWN").upper()
    if state not in VALID_STATES:
        return None

    queue = data.get("queue") if isinstance(data.get("queue"), dict) else {}
    network = data.get("network") if isinstance(data.get("network"), dict) else {}
    training = data.get("training") if isinstance(data.get("training"), dict) else {}
    peer_value = network.get("peer_count")
    if peer_value is None:
        peer_value = network.get("adjacent_layer_p2p_available")

    return {
        "state": state,
        "source": "NodeOS",
        "position": integer_or_none(queue.get("position")),
        "previous_position": integer_or_none(queue.get("previous_position")),
        "initial_position": integer_or_none(queue.get("initial_position")),
        "queue_id": string_or_none(queue.get("queue_id")),
        "queue_updated": string_or_none(queue.get("updated_at")),
        "peer": string_or_none(peer_value),
        "last_training": string_or_none(training.get("last_training_at")),
        "forward_count": integer_or_none(training.get("forward_complete_count")),
        "activation_count": integer_or_none(training.get("activation_submit_success_count")),
        "attestation_count": integer_or_none(training.get("attestation_request_count")),
    }


def integer_or_none(value):
    try:
        return int(value) if value is not None and value != "" else None
    except (TypeError, ValueError):
        return None


def string_or_none(value):
    if value is None or value == "":
        return None
    return str(value)


def find_last_training(log_path):
    if not log_path:
        return None
    directory = os.path.dirname(log_path)
    candidates = sorted(
        glob.glob(os.path.join(directory, "*-cli.log")),
        key=lambda item: os.path.getmtime(item),
        reverse=True,
    )[:7]
    latest = None
    for candidate in candidates:
        text = read_tail(candidate, 6 * 1024 * 1024)
        for line in text.splitlines():
            lower = line.lower()
            if (
                ("training.state accepted" in lower and re.search(r"state[^a-z]+training", lower))
                or "submit_weights:" in lower
                or "getting pseudo gradients" in lower
                or "miner.training.training:" in lower
                or "optimization_reset:" in lower
                or "resetting after optimization step" in lower
            ):
                timestamp = line_time(line)
                if timestamp:
                    latest = timestamp
        if latest:
            return latest
    return None


def update_tracker(path, queue_id, position, source_previous, source_initial, updated_at):
    old = load_json(path)
    if position is None:
        tracker = {
            "queue_id": queue_id,
            "position": None,
            "previous_position": None,
            "initial_position": None,
            "delta": None,
            "updated_at": updated_at,
        }
        atomic_json(path, tracker)
        return tracker

    old_id = string_or_none(old.get("queue_id"))
    old_position = integer_or_none(old.get("position"))
    old_previous = integer_or_none(old.get("previous_position"))
    old_initial = integer_or_none(old.get("initial_position"))
    same_queue = bool(queue_id and old_id and queue_id == old_id)
    unknown_queue_continuation = not queue_id and not old_id and old_position is not None

    if same_queue or unknown_queue_continuation:
        if old_position != position:
            previous = old_position
            delta = old_position - position
        else:
            previous = old_previous
            delta = integer_or_none(old.get("delta"))
        initial = old_initial if old_initial is not None else position
    else:
        previous = source_previous
        delta = previous - position if previous is not None else None
        initial = source_initial if source_initial is not None else position

    tracker = {
        "queue_id": queue_id,
        "position": position,
        "previous_position": previous,
        "initial_position": initial,
        "delta": delta,
        "updated_at": updated_at,
    }
    atomic_json(path, tracker)
    return tracker


def change_text(delta):
    if delta is None:
        return "刚记录"
    if delta > 0:
        return f"↑前进{delta}"
    if delta < 0:
        return f"↓后退{abs(delta)}"
    return "未变化"


def placeholder(value):
    if value is None or value == "":
        return "-"
    return str(value).replace("\t", " ").replace("\n", " ")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", default="")
    parser.add_argument("--nodeos", default="")
    parser.add_argument("--tracker", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--previous-output", default="")
    parser.add_argument("--now", type=int, required=True)
    parser.add_argument("--age", type=int, default=999999)
    parser.add_argument("--app", type=int, choices=(0, 1), default=0)
    parser.add_argument("--cli", type=int, choices=(0, 1), default=0)
    parser.add_argument("--node", default="UNKNOWN")
    args = parser.parse_args()

    prior = load_json(args.previous_output or args.output)
    nodeos = fresh_nodeos(args.nodeos, args.now)
    parsed = nodeos if nodeos is not None else native_parse(args.log)

    if not args.log or not os.path.isfile(args.log):
        parsed["state"] = "NO_LOG"
    elif args.app == 0 and args.cli == 0:
        parsed["state"] = "STOPPED"
    elif args.app == 1 and args.cli == 0:
        parsed["state"] = "NEED_START"
    elif args.age > 180:
        parsed["state"] = "STALE"
    elif parsed.get("state") not in VALID_STATES or parsed.get("state") == "UNKNOWN":
        parsed["state"] = "STARTING" if args.cli == 1 else "UNKNOWN"

    state = parsed["state"]
    if state != "QUEUED":
        parsed["position"] = None
        parsed["previous_position"] = None
        parsed["queue_id"] = None

    tracker = update_tracker(
        args.tracker,
        parsed.get("queue_id"),
        integer_or_none(parsed.get("position")),
        integer_or_none(parsed.get("previous_position")),
        integer_or_none(parsed.get("initial_position")),
        parsed.get("queue_updated"),
    )

    training_prior = prior.get("training") if isinstance(prior.get("training"), dict) else {}
    last_training = parsed.get("last_training")
    if not last_training:
        last_training = training_prior.get("last_training_at")
    if not last_training and args.log:
        last_training = find_last_training(args.log)

    for parsed_key, prior_key in (
        ("forward_count", "forward_complete_count"),
        ("activation_count", "activation_submit_success_count"),
        ("attestation_count", "attestation_request_count"),
    ):
        if parsed.get(parsed_key) is None:
            parsed[parsed_key] = integer_or_none(training_prior.get(prior_key))

    checked = dt.datetime.fromtimestamp(args.now).strftime("%Y-%m-%d %H:%M:%S")
    result = {
        "version": VERSION,
        "checked_at": checked,
        "status": state,
        "status_text": STATE_TEXT.get(state, "无法识别"),
        "healthy": state in {"TRAINING", "QUEUED"},
        "source": parsed.get("source") or "本地日志",
        "node": args.node,
        "process": {"app_running": bool(args.app), "cli_running": bool(args.cli)},
        "log": {"path": args.log or None, "lag_seconds": args.age},
        "queue": {
            "queue_id": tracker.get("queue_id"),
            "position": tracker.get("position"),
            "previous_position": tracker.get("previous_position"),
            "initial_position": tracker.get("initial_position"),
            "delta": tracker.get("delta"),
            "change_text": change_text(tracker.get("delta")),
            "updated_at": tracker.get("updated_at"),
        },
        "network": {"peer": parsed.get("peer")},
        "training": {
            "last_training_at": last_training,
            "forward_complete_count": parsed.get("forward_count"),
            "activation_submit_success_count": parsed.get("activation_count"),
            "attestation_request_count": parsed.get("attestation_count"),
        },
    }
    atomic_json(args.output, result)

    fields = [
        state,
        result["source"],
        tracker.get("position"),
        tracker.get("previous_position"),
        tracker.get("delta"),
        result["queue"]["change_text"],
        tracker.get("queue_id"),
        tracker.get("updated_at"),
        parsed.get("peer"),
        last_training,
        parsed.get("forward_count"),
        parsed.get("activation_count"),
        parsed.get("attestation_count"),
        result["status_text"],
    ]
    print("\t".join(placeholder(value) for value in fields))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"status_engine error: {exc}", file=sys.stderr)
        raise
PY_ENGINE

cat > "$STAGE/monitor.sh" <<'MONITOR_SCRIPT'
#!/bin/zsh
set -u
setopt null_glob

BASE="$HOME/.iota-guardian"
LOGDIR="$HOME/Library/Logs/IOTA Train at Home"
NODEOS_STATUS="$HOME/.nodeos/iota_monitor_status.json"
NODE=$(cat "$BASE/node_name" 2>/dev/null || echo UNKNOWN)
PUSH=$(cat "$BASE/push_url" 2>/dev/null || echo '')
PUSH="${PUSH%%\?*}"
PYTHON=$(cat "$BASE/python_bin" 2>/dev/null || command -v python3 2>/dev/null || true)
NOW=$(date +%s)
NOWTXT=$(date '+%Y-%m-%d %H:%M:%S')
TODAY=$(date '+%Y-%m-%d')
RUNLOG="$BASE/guardian.log"
EVENTS="$BASE/events.csv"
SAMPLES="$BASE/samples-$TODAY.csv"
LAST="$BASE/last_state"
QUEUE_START="$BASE/queue_start_epoch"
LOWP2P="$BASE/low_p2p_count"
LIVE="$BASE/live_status.json"
TRACKER="$BASE/queue_tracker.json"
LOCK="$BASE/.monitor-lock"

mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

trim(){
  [[ -f "$1" ]] || return 0
  local count=$(wc -l < "$1" 2>/dev/null || echo 0)
  ((count>$2+200)) || return 0
  tail -n "$2" "$1" > "$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"
}
log(){ echo "$NOWTXT | $NODE | $1" >> "$RUNLOG"; trim "$RUNLOG" 2000; }
disk(){ df -Pk / | awk 'NR==2{gsub("%","",$5);print $5}'; }
duration(){
  local s=${1:-0} d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  ((d>0)) && { echo "${d}天${h}小时${m}分钟"; return; }
  ((h>0)) && { echo "${h}小时${m}分钟"; return; }
  echo "${m}分钟"
}

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
  local state="$1" kuma="$2" msg="$3" age="$4" pos="$5" prev="$6" change="$7" peer="$8" source="$9"
  local old=$(cat "$LAST" 2>/dev/null || echo '')
  print -r -- "$state" > "$BASE/current_state"
  if [[ "$state" != "$old" ]]; then
    [[ -f "$EVENTS" ]] || echo 'time,node,state,message' > "$EVENTS"
    echo "\"$NOWTXT\",\"$NODE\",\"$state\",\"${msg//\"/\"\"}\"" >> "$EVENTS"
    trim "$EVENTS" 10000
  fi
  print -r -- "$state" > "$LAST"
  [[ -f "$SAMPLES" ]] || echo 'time,node,state,log_age,disk,queue_position,previous_position,change,peer,source' > "$SAMPLES"
  echo "\"$NOWTXT\",\"$NODE\",\"$state\",\"$age\",\"$(disk)\",\"$pos\",\"$prev\",\"$change\",\"$peer\",\"$source\"" >> "$SAMPLES"
  find "$BASE" -maxdepth 1 -name 'samples-*.csv' -mtime +31 -delete 2>/dev/null || true
  send "$kuma" "$msg"
  exit 0
}

D=$(disk)
FILES=("$LOGDIR"/**/*-cli.log(N.om[1]))
LATEST=''
AGE=999999
if (( ${#FILES[@]} > 0 )); then
  LATEST="${FILES[1]}"
  MT=$(/usr/bin/stat -f %m "$LATEST" 2>/dev/null || echo 0)
  AGE=$((NOW-MT))
  ((AGE<0)) && AGE=0
fi

APP=0
CLI=0
/usr/bin/pgrep -f '/Applications/IOTA Train at Home.app/Contents/MacOS/IOTA Train at Home' >/dev/null 2>&1 && APP=1
/usr/bin/pgrep -f '/Applications/IOTA Train at Home.app/Contents/Frameworks/.*/main_pool|iota-cli/main_pool|/main_pool([[:space:]]|$)' >/dev/null 2>&1 && CLI=1

if [[ -z "$PYTHON" || ! -x "$PYTHON" ]]; then
  log "status_engine无法运行：没有python3"
  finish UNKNOWN down "🔴 监控故障 | UNKNOWN | 未找到python3 | 磁盘${D}%" "$AGE" '-' '-' '-' '-' '监控'
fi

RESULT=$("$PYTHON" "$BASE/status_engine.py" \
  --log "$LATEST" \
  --nodeos "$NODEOS_STATUS" \
  --tracker "$TRACKER" \
  --output "$LIVE" \
  --previous-output "$LIVE" \
  --now "$NOW" \
  --age "$AGE" \
  --app "$APP" \
  --cli "$CLI" \
  --node "$NODE" 2>>"$BASE/monitor-error.log")
ENGINE_RC=$?
if ((ENGINE_RC!=0)) || [[ -z "$RESULT" ]]; then
  log "status_engine执行失败，返回码${ENGINE_RC}"
  finish UNKNOWN down "🔴 监控解析故障 | UNKNOWN | 请查看monitor-error.log | 磁盘${D}%" "$AGE" '-' '-' '-' '-' '监控'
fi

IFS=$'\t' read -r STATE SOURCE POS PREV DELTA CHANGE QID QUPDATED PEER LASTTRAIN FORWARD ACTIVATION ATTESTATION STATUSTEXT <<< "$RESULT"

OLD=$(cat "$LAST" 2>/dev/null || echo '')
if [[ "$STATE" == QUEUED ]]; then
  if [[ "$OLD" != QUEUED || ! -s "$QUEUE_START" ]]; then print -r -- "$NOW" > "$QUEUE_START"; fi
else
  rm -f "$QUEUE_START"
fi
QTXT='0分钟'
if [[ "$STATE" == QUEUED && -s "$QUEUE_START" ]]; then
  QS=$(cat "$QUEUE_START" 2>/dev/null || echo "$NOW")
  QTXT=$(duration $((NOW-QS)))
fi

LOW=0
if [[ "$PEER" == */* ]]; then
  POK="${PEER%%/*}"
  PTOT="${PEER##*/}"
  if [[ "$POK" == <-> && "$PTOT" == <-> ]] && ((PTOT>0)); then
    if ((POK*4<PTOT)); then
      C=$(cat "$LOWP2P" 2>/dev/null || echo 0)
      C=$((C+1)); print -r -- "$C" > "$LOWP2P"
      ((C>=20)) && LOW=1
    else
      print 0 > "$LOWP2P"
    fi
  fi
fi

case "$STATE" in
  TRAINING)
    STATUS=up
    MSG="🟢 正常训练 | TRAINING | Peer${PEER:--} | 日志${AGE}秒 | 磁盘${D}%"
    ;;
  QUEUED)
    STATUS=up
    if [[ "$POS" != '-' ]]; then
      PREV_TEXT=''
      [[ "$PREV" != '-' ]] && PREV_TEXT=" | 上次${PREV}"
      MSG="🟢 正常排队 | 当前排名${POS}${PREV_TEXT} | ${CHANGE} | 已排${QTXT} | Peer${PEER:--} | 日志${AGE}秒 | 磁盘${D}%"
    else
      MSG="🟢 正常排队 | QUEUED | 排名等待更新 | 已排${QTXT} | 日志${AGE}秒 | 磁盘${D}%"
    fi
    ;;
  RESETTING)
    STATUS=down
    MSG="🔴 重新注册 | RESETTING | 排名已重置 | 日志${AGE}秒 | 磁盘${D}%"
    ;;
  CRASHED)
    STATUS=down
    MSG="🔴 程序崩溃 | CRASHED | miner进程异常退出 | 日志${AGE}秒 | 磁盘${D}%"
    ;;
  NEED_START)
    STATUS=down
    MSG="🔴 需要点击Start training | NEED_START | IOTA界面已开但训练进程未运行 | 日志${AGE}秒"
    ;;
  STOPPED)
    STATUS=down
    MSG="🔴 IOTA停止 | STOPPED | 需要打开IOTA并点击Start training | 日志${AGE}秒"
    ;;
  STALE)
    STATUS=down
    MSG="🔴 日志故障 | STALE | 已${AGE}秒未更新（阈值180秒） | 磁盘${D}%"
    ;;
  NO_LOG)
    STATUS=down
    MSG="🔴 无日志 | NO_LOG | 未找到IOTA CLI日志 | 磁盘${D}%"
    ;;
  STARTING)
    STATUS=down
    MSG="🔴 状态未确认 | STARTING | 检查是否显示Start training | 日志${AGE}秒"
    ;;
  *)
    STATUS=down
    MSG="🔴 无法识别 | UNKNOWN | 检查IOTA界面与日志 | 日志${AGE}秒 | 磁盘${D}%"
    ;;
esac

((LOW==0)) || { STATUS=down; MSG="🔴 P2P故障 | $MSG | 已连续10分钟严重偏低"; }
((D<90)) || { STATUS=down; MSG="🔴 磁盘故障 | $MSG | 磁盘严重不足"; }
finish "$STATE" "$STATUS" "$MSG" "$AGE" "$POS" "$PREV" "$CHANGE" "$PEER" "$SOURCE"
MONITOR_SCRIPT

cat > "$STAGE/live_view.py" <<'PY_VIEW'
#!/usr/bin/env python3
import json
import os
import time

BASE = os.path.expanduser("~/.iota-guardian")
STATUS = os.path.join(BASE, "live_status.json")


def value(item, default="等待更新"):
    return default if item is None or item == "" else str(item)


while True:
    print("\033[2J\033[H", end="")
    print("============================================================")
    print("              IOTA Guardian V6 实时排名")
    print("============================================================")
    try:
        with open(STATUS, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        queue = data.get("queue") or {}
        network = data.get("network") or {}
        training = data.get("training") or {}
        log = data.get("log") or {}
        healthy = data.get("healthy")
        icon = "🟢" if healthy else "🔴"
        print(f"电脑：{value(data.get('node'))}")
        print(f"状态：{icon} {value(data.get('status_text'))}（{value(data.get('status'))}）")
        print(f"数据来源：{value(data.get('source'))}")
        print("------------------------------------------------------------")
        if data.get("status") == "QUEUED":
            print(f"当前排名：{value(queue.get('position'))}")
            print(f"上次排名：{value(queue.get('previous_position'), '刚开始记录')}")
            print(f"本轮首次记录：{value(queue.get('initial_position'), '刚开始记录')}")
            print(f"本次变化：{value(queue.get('change_text'))}")
            print(f"排名更新时间：{value(queue.get('updated_at'))}")
            queue_id = value(queue.get("queue_id"), "未读取到")
            if len(queue_id) > 20:
                queue_id = queue_id[:8] + "…" + queue_id[-8:]
            print(f"队列ID：{queue_id}")
        else:
            print("当前排名：当前不是排队状态")
        print("------------------------------------------------------------")
        print(f"Peer：{value(network.get('peer'))}")
        print(f"日志延迟：{value(log.get('lag_seconds'))} 秒")
        print(f"上次训练：{value(training.get('last_training_at'), '尚未从日志确定')}")
        forward = training.get("forward_complete_count")
        activation = training.get("activation_submit_success_count")
        attestation = training.get("attestation_request_count")
        if any(item is not None for item in (forward, activation, attestation)):
            print("日志记录次数（不等于实际完成任务数）：")
            print(f"  Forward {value(forward, '-')} | Activation {value(activation, '-')} | Attestation {value(attestation, '-')}")
        print("------------------------------------------------------------")
        print(f"监控更新时间：{value(data.get('checked_at'))}")
    except Exception as exc:
        print("状态文件正在生成，请稍等……")
        print(f"读取提示：{exc}")
    print("\n每10秒刷新；按 Control + C 只退出本窗口，不会停止IOTA。")
    try:
        time.sleep(10)
    except KeyboardInterrupt:
        print("\n已退出实时查看，后台监控和IOTA继续运行。")
        break
PY_VIEW

cat > "$STAGE/cleanup.sh" <<'CLEANUP_SCRIPT'
#!/bin/zsh
set -u
BASE="$HOME/.iota-guardian"
LOGDIR="$HOME/Library/Logs/IOTA Train at Home"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
B=$(du -sk "$LOGDIR" 2>/dev/null | awk '{print $1}'); B=${B:-0}
find "$LOGDIR" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.gz' \) -mtime +14 -delete 2>/dev/null || true
find "$HOME/Library/Logs/DiagnosticReports" -type f \( -iname '*iota*' -o -iname '*main_pool*' \) -mtime +30 -delete 2>/dev/null || true
A=$(du -sk "$LOGDIR" 2>/dev/null | awk '{print $1}'); A=${A:-0}
F=$((B-A)); ((F<0)) && F=0
echo "$NOW | IOTA日志 ${B}KB→${A}KB | 释放${F}KB" >> "$BASE/cleanup.log"
tail -n 300 "$BASE/cleanup.log" > "$BASE/cleanup.log.tmp" 2>/dev/null && mv "$BASE/cleanup.log.tmp" "$BASE/cleanup.log"
CLEANUP_SCRIPT

cat > "$STAGE/daily_report.sh" <<'REPORT_SCRIPT'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
TODAY=$(date '+%Y-%m-%d')
S="$BASE/samples-$TODAY.csv"
R="$BASE/reports/$TODAY.txt"
mkdir -p "$BASE/reports"
minutes(){
  local count=$(grep -c ",\"$1\"," "$S" 2>/dev/null || true)
  echo $((count/2))
}
cat > "$R" <<EOF_REPORT
IOTA Guardian V6.0 每日报告
日期：$TODAY
电脑：$(cat "$BASE/node_name" 2>/dev/null)
TRAINING：约 $(minutes TRAINING) 分钟
QUEUED：约 $(minutes QUEUED) 分钟
RESETTING：约 $(minutes RESETTING) 分钟
CRASHED：约 $(minutes CRASHED) 分钟
STOPPED/NEED_START：约 $(( $(minutes STOPPED) + $(minutes NEED_START) )) 分钟
STALE：约 $(minutes STALE) 分钟
NO_LOG/UNKNOWN：约 $(( $(minutes NO_LOG) + $(minutes UNKNOWN) )) 分钟
当前状态：$(cat "$BASE/current_message" 2>/dev/null)
EOF_REPORT
find "$BASE/reports" -type f -mtime +31 -delete 2>/dev/null || true
REPORT_SCRIPT

cat > "$STAGE/show_report.sh" <<'SHOW_SCRIPT'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
echo "===== IOTA Guardian V6.0 实时排名综合版 ====="
echo "版本：$(cat "$BASE/version" 2>/dev/null)"
echo "电脑：$(cat "$BASE/node_name" 2>/dev/null)"
echo "当前：$(cat "$BASE/current_message" 2>/dev/null)"
echo "详细状态：$BASE/live_status.json"
echo "Guardian占用：$(du -sh "$BASE" 2>/dev/null | awk '{print $1}')"
echo "IOTA日志占用：$(du -sh "$HOME/Library/Logs/IOTA Train at Home" 2>/dev/null | awk '{print $1}')"
echo "最近状态变化："
tail -n 15 "$BASE/events.csv" 2>/dev/null
SHOW_SCRIPT

cat > "$STAGE/viewer.command" <<'VIEWER_SCRIPT'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
PYTHON=$(cat "$BASE/python_bin" 2>/dev/null || command -v python3 2>/dev/null || true)
if [[ -z "$PYTHON" || ! -x "$PYTHON" ]]; then
  echo "没有找到python3，无法打开实时排名。"
  read "?按回车退出..."
  exit 1
fi
exec "$PYTHON" "$BASE/live_view.py"
VIEWER_SCRIPT

cat > "$STAGE/$MONITOR_LABEL.plist" <<EOF_MONITOR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$MONITOR_LABEL</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/monitor.sh</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>30</integer>
<key>Nice</key><integer>10</integer>
<key>LowPriorityIO</key><true/>
<key>StandardOutPath</key><string>$BASE/monitor-out.log</string>
<key>StandardErrorPath</key><string>$BASE/monitor-error.log</string>
</dict></plist>
EOF_MONITOR_PLIST

cat > "$STAGE/$CLEAN_LABEL.plist" <<EOF_CLEAN_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$CLEAN_LABEL</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/cleanup.sh</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>20</integer></dict>
<key>Nice</key><integer>15</integer>
<key>LowPriorityIO</key><true/>
<key>StandardOutPath</key><string>/dev/null</string>
<key>StandardErrorPath</key><string>$BASE/cleanup-error.log</string>
</dict></plist>
EOF_CLEAN_PLIST

cat > "$STAGE/$REPORT_LABEL.plist" <<EOF_REPORT_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$REPORT_LABEL</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BASE/daily_report.sh</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>23</integer><key>Minute</key><integer>55</integer></dict>
<key>Nice</key><integer>15</integer>
<key>LowPriorityIO</key><true/>
<key>StandardOutPath</key><string>/dev/null</string>
<key>StandardErrorPath</key><string>$BASE/report-error.log</string>
</dict></plist>
EOF_REPORT_PLIST

# 全部通过语法检查后，才替换旧版监控文件。
/bin/zsh -n "$STAGE/monitor.sh" "$STAGE/cleanup.sh" "$STAGE/daily_report.sh" "$STAGE/show_report.sh" "$STAGE/viewer.command"
"$PYTHON_BIN" -m py_compile "$STAGE/status_engine.py" "$STAGE/live_view.py"
plutil -lint "$STAGE/$MONITOR_LABEL.plist" >/dev/null
plutil -lint "$STAGE/$CLEAN_LABEL.plist" >/dev/null
plutil -lint "$STAGE/$REPORT_LABEL.plist" >/dev/null

UID_NUM=$(id -u)
for plist in \
  "$LAUNCH"/com.baibai.iota-log-monitor.plist(N) \
  "$LAUNCH"/com.baibai.iota-guardian*.plist(N); do
  launchctl bootout "gui/$UID_NUM" "$plist" 2>/dev/null || true
  rm -f "$plist"
done

/usr/bin/install -m 700 "$STAGE/status_engine.py" "$BASE/status_engine.py"
/usr/bin/install -m 700 "$STAGE/monitor.sh" "$BASE/monitor.sh"
/usr/bin/install -m 700 "$STAGE/live_view.py" "$BASE/live_view.py"
/usr/bin/install -m 700 "$STAGE/cleanup.sh" "$BASE/cleanup.sh"
/usr/bin/install -m 700 "$STAGE/daily_report.sh" "$BASE/daily_report.sh"
/usr/bin/install -m 700 "$STAGE/show_report.sh" "$BASE/show_report.sh"
/usr/bin/install -m 700 "$STAGE/viewer.command" "$VIEWER"
/usr/bin/install -m 600 "$STAGE/$MONITOR_LABEL.plist" "$MONITOR_PLIST"
/usr/bin/install -m 600 "$STAGE/$CLEAN_LABEL.plist" "$CLEAN_PLIST"
/usr/bin/install -m 600 "$STAGE/$REPORT_LABEL.plist" "$REPORT_PLIST"

print -r -- "$NODE_NAME" > "$BASE/node_name"
print -r -- "$PUSH_URL" > "$BASE/push_url"
print -r -- "$PYTHON_BIN" > "$BASE/python_bin"
print -r -- "$VERSION" > "$BASE/version"
chmod 600 "$BASE/node_name" "$BASE/push_url" "$BASE/python_bin" "$BASE/version"
touch "$BASE/guardian.log" "$BASE/monitor-error.log" "$BASE/monitor-out.log"
chmod 600 "$BASE/guardian.log" "$BASE/monitor-error.log" "$BASE/monitor-out.log"

launchctl bootstrap "gui/$UID_NUM" "$MONITOR_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$CLEAN_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$REPORT_PLIST"
launchctl kickstart -k "gui/$UID_NUM/$MONITOR_LABEL"
sleep 3
"$BASE/monitor.sh" || true

cleanup_stage
trap - EXIT INT TERM

echo
echo "============================================================"
echo "✅ IOTA Guardian V6.0 实时排名综合版安装/升级完成"
echo "============================================================"
echo "电脑：$(cat "$BASE/node_name")"
echo "检测频率：30秒"
echo "日志超时阈值：180秒"
echo "Kuma显示：状态、当前排名、上次排名、本次变化、日志延迟"
echo "桌面实时查看：双击『IOTA实时排名.command』"
echo "当前状态：$(cat "$BASE/current_message" 2>/dev/null || echo '正在生成，请稍等30秒')"
echo
if [[ -s "$NODEOS_STATUS" ]]; then
  echo "已检测到NodeOS状态文件：综合版会优先读取其可靠实时字段。"
else
  echo "未检测到NodeOS状态文件：综合版将直接解析IOTA日志，功能仍可使用。"
fi
echo
echo "本程序不会关闭、启动、重启或点击IOTA。"
echo "旧版配置已安全继承；备份位置：$BACKUP"
echo
read "?按回车关闭本窗口..."
