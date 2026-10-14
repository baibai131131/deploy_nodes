#!/bin/zsh
set -euo pipefail
setopt null_glob
umask 077

# IOTA Guardian V6.5.1：精准状态、官方 Run/收益、参与 Run 统计与本机实时仪表盘。
[[ "$(uname -s)" == Darwin ]] || { echo "本脚本仅支持 macOS。"; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo "请使用当前登录用户运行，不要使用 sudo。"; exit 1; }
GUI_DOMAIN="gui/$(id -u)"
launchctl print "$GUI_DOMAIN" >/dev/null 2>&1 || { echo "请在已登录桌面的 Mac 终端运行。"; exit 1; }

VERSION="6.5.1"
BASE="$HOME/.iota-guardian"
LAUNCH="$HOME/Library/LaunchAgents"
MONITOR_LABEL="com.baibai.iota-guardian-v6.monitor"
CLEAN_LABEL="com.baibai.iota-guardian-v6.cleanup"
REPORT_LABEL="com.baibai.iota-guardian-v6.report"
POOL_LABEL="com.baibai.iota-guardian-v6.run-pool"
REWARD_LABEL="com.baibai.iota-guardian-v6.rewards"
mkdir -p "$BASE" "$LAUNCH" "$BASE/reports" "$BASE/backups"
BACKUP=$(mktemp -d "$BASE/backups/before-v6-XXXXXXXX")
STAGE=$(mktemp -d "$BASE/install-stage-XXXXXXXX")
mkdir -p "$BACKUP/files" "$BACKUP/LaunchAgents"
for item in node_name push_url version monitor.sh status_engine.py dashboard.py runs_view.py run_tracker.py reward_tracker.py runs_refresh.sh rewards_refresh.sh show_monitor.sh show_runs.sh cleanup.sh daily_report.sh show_report.sh last_state current_record.tsv queue_start_epoch restart_required.tsv low_p2p_count run_history.tsv run_pool_summary.tsv reward_summary.tsv reward_snapshots.tsv hotkey; do
  [[ ! -f "$BASE/$item" ]] || cp -p "$BASE/$item" "$BACKUP/files/$item"
done
trap 'echo "安装未完成。备份：$BACKUP；请保留此目录，勿上传（含 Push URL）。" >&2' ZERR

echo "=============================================="
echo " IOTA Guardian V6.5.1 Run与收益增强版"
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
    print("UNKNOWN\t-\t-\t-\t-\t-\t999999\t无法读取日志\t0\t0\t-\t999999\t999999")
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
reg_error = ""
reg_error_ts = None
queue_warn_ts = None
midrun_reset_ts = None
cached_reset_ts = None
last_boot_ts = None
ACTIVE_STATES = {"TRAINING", "MERGING", "SYNCING", "RUN_IDLE", "INITIALIZING"}

def set_state(value, i, ts, hard=False):
    global state, state_i, state_ts, barrier_i
    state, state_i, state_ts = value, i, ts
    if hard:
        barrier_i = i

for i, line in enumerate(lines):
    low = line.lower()
    ts = line_epoch(line)

    # A full client/miner start after a reset proves that the user restarted it.
    if ts is not None and (
            re.search(r"\bstarting miner\b", line, re.I) or
            "initializing bittensor wallet" in low or
            "p2p start: begin" in low or
            "protocol server started in separate process" in low):
        last_boot_ts = ts

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

    # Keep recent registration failures visible after the client automatically rejoins the queue.
    if "invalid_attestation_challenge" in low:
        reg_error = "invalid_attestation_challenge"
        if ts is not None: reg_error_ts = ts
    elif "error registering miner" in low:
        reg_error = "registration_error"
        if ts is not None: reg_error_ts = ts
    if (("register.queue_state" in low and ("503" in low or "no handler" in low)) or
            "register_set_queue_state exhausted retries" in low):
        queue_warn_ts = ts

    # The GUI line below is only actionable when it follows a reset from an
    # active Run. It must not be confused with a normal cached speed test.
    if "using cached speedtest result" in low and ts is not None and midrun_reset_ts is not None:
        if 0 <= ts - midrun_reset_ts <= 300:
            cached_reset_ts = ts

    # Newer state-changing events always override older activity.
    if ("signal=sigabrt" in low or "training exited with code=1" in low or
            "training process exited with code 1" in low or "miner process exited" in low):
        set_state("CRASHED", i, ts, True); continue
    if ("closing iota cli" in low or "cleaning up miner on shutdown" in low or
            "p2p shutdown complete" in low):
        set_state("STOPPED", i, ts, True); continue
    if "invalid_attestation_challenge" in low or "error registering miner" in low:
        set_state("REG_FAILED", i, ts, True); continue
    # EntityNotRegistered/get_run_config is normal while queued. Only explicit reset/kick
    # events prove that an existing registration was actually discarded.
    if ("resetting miner entire state" in low or
            "appears to have been kicked" in low or "miner.kicked" in low):
        active_before = state in ACTIVE_STATES
        if ts is not None and last_activity_ts is not None and 0 <= ts - last_activity_ts <= 900:
            active_before = True
        if ts is not None:
            if active_before:
                midrun_reset_ts = ts
            elif midrun_reset_ts is not None and 0 <= ts - midrun_reset_ts <= 300:
                # "kicked" and "resetting" can be two lines from the same event.
                midrun_reset_ts = ts
        set_state("RESETTING", i, ts, True); continue
    if re.search(r"status['\"]?\s*:\s*['\"]failed", low):
        pos = ""
        set_state("REG_FAILED", i, ts, True); continue
    if re.search(r"status['\"]?\s*:\s*['\"]processing", low):
        pos = ""
        set_state("PROCESSING", i, ts, True); continue
    if re.search(r"status['\"]?\s*:\s*['\"]confirmed", low):
        pos = ""
        set_state("CONFIRMED", i, ts, True); continue
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
    if re.search(r"(?:End (?:forward|backward)|(?:FORWARD|BACKWARD) complete)", line, re.I): strong = "计算完成"
    elif re.search(r"End (upload|submit) activation", line, re.I): strong = "activation完成"
    elif "activation push send" in low and "ack ok" in low: strong = "activation送达"
    elif "activation push recv" in low and ("materialize done" in low or "pulled ingress" in low): strong = "收到activation"
    elif "/miner/submit_activation; response:" in low and "error" not in low: strong = "提交activation"
    elif "weights submitted successfully" in low: strong = "权重提交成功"
    elif "submit_weights:" in low or "getting pseudo gradients" in low or "optimization_reset:" in low: strong = "权重训练"
    if strong:
        last_activity_i, last_activity_ts, last_activity_name = i, ts, strong
        set_state("TRAINING", i, ts)

    if "failed to send" in low and "activation" in low: send_fail += 1
    if ("activation push send" in low and ("success" in low or "ack ok" in low)) or "end upload activation" in low: send_ok += 1

activity_age = 999999 if last_activity_ts is None else max(0, now - last_activity_ts)
# 最近5分钟的有效计算优先于普通 idle heartbeat，但不能越过排队/重置/合并等新状态。
if activity_age <= 300 and last_activity_i > barrier_i:
    state = "TRAINING"
# 旧成功记录不能让机器一直冒充 TRAINING。
elif state == "TRAINING" and activity_age > 300:
    state = "RUN_IDLE"

# Queue/registration messages may contain stale peer layer data from a previous Run.
# Until the server returns an actual Run assignment, do not present it as this miner's assignment.
if state in {"QUEUED", "CONFIRMED", "PROCESSING", "REG_FAILED", "RESETTING"}:
    run = layer = epoch = p2p = ""

detail = last_activity_name or "无近期有效训练事件"
reg_error_age = 999999 if reg_error_ts is None else max(0, now - reg_error_ts)
queue_warn_age = 999999 if queue_warn_ts is None else max(0, now - queue_warn_ts)
values = [state, pos or "-", run or "-", layer or "-", epoch or "-", p2p or "-", str(activity_age), detail,
          str(send_fail), str(send_ok), reg_error or "-", str(reg_error_age), str(queue_warn_age),
          str(cached_reset_ts or 0), str(last_boot_ts or 0), str(last_activity_ts or 0)]
print("\t".join(v.replace("\t", " ").replace("\n", " ") for v in values))
PY

cat > "$STAGE/dashboard.py" <<'PY'
#!/usr/bin/python3
"""Local read-only terminal dashboard for IOTA Guardian."""
import glob, os, shutil, subprocess, sys, time
from datetime import datetime
from pathlib import Path

BASE = Path.home() / ".iota-guardian"
LOGDIR = Path.home() / "Library/Logs/IOTA Train at Home"
ENGINE = BASE / "status_engine.py"
REFRESH = 10

LABELS = {
    "TRAINING": ("🟢", "真实训练"), "MERGING": ("🟡", "合并阶段"),
    "SYNCING": ("🟡", "权重同步"), "RUN_IDLE": ("🟠", "池内等待"),
    "INITIALIZING": ("🟠", "训练池初始化"), "CONFIRMED": ("🔵", "已到队首确认"),
    "PROCESSING": ("🟠", "注册处理中"), "REG_FAILED": ("🔴", "注册确认失败"),
    "QUEUED": ("🔵", "正常排队"), "RESETTING": ("🔴", "注册被重置"),
    "RESTART_REQUIRED": ("🔴", "训练中途被重置，建议人工重启"),
    "CRASHED": ("🔴", "程序崩溃"), "STOPPED": ("🔴", "IOTA停止"),
    "STALE": ("🔴", "日志卡住"), "NO_LOG": ("🔴", "没有日志"),
    "UNKNOWN": ("🔴", "状态未确认"),
}

def duration(seconds):
    seconds = int(seconds)
    if seconds >= 999999:
        return "暂无"
    seconds = max(0, seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return (f"{h}小时{m}分钟" if h else f"{m}分{s}秒")

def process_stats():
    try:
        out = subprocess.check_output(["/bin/ps", "-A", "-o", "%cpu=,%mem=,command="], text=True)
        rows = [x for x in out.splitlines() if "main_pool" in x and "status_engine" not in x]
        cpu = mem = 0.0
        for row in rows:
            parts = row.strip().split(None, 2)
            if len(parts) >= 2:
                cpu += float(parts[0]); mem += float(parts[1])
        return bool(rows), cpu, mem
    except Exception:
        return False, 0.0, 0.0

def latest_log():
    files = glob.glob(str(LOGDIR / "*-cli.log"))
    return Path(max(files, key=os.path.getmtime)) if files else None

def parse(log):
    cache = BASE / "current_record.tsv"
    try:
        # Background Guardian refreshes this tiny cache every 60 seconds.
        # Re-parse the log only once as a fallback during a fresh installation.
        if cache.exists() and time.time() - cache.stat().st_mtime <= 120:
            out = cache.read_text(errors="replace").strip()
        else:
            out = subprocess.check_output([sys.executable, str(ENGINE), str(log)], text=True, timeout=8).strip()
        values = out.split("\t")
    except Exception:
        values = ["UNKNOWN"]
    values += ["-"] * (13 - len(values))
    return values[:13]

def run_stats():
    history = BASE / "run_history.tsv"
    today = datetime.now().strftime("%Y-%m-%d")
    rows = {}
    try:
        for line in history.read_text(errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                rows[parts[0]] = parts
    except Exception:
        pass
    return sum(1 for parts in rows.values() if parts[2].startswith(today)), len(rows)

def pool_stats(now):
    cache = BASE / "run_pool_summary.tsv"
    try:
        values = cache.read_text(errors="replace").strip().split("\t")
        values += ["-"] * (7 - len(values))
        age = max(0, now - int(values[0]))
        return values[1], values[2], values[3], values[4], values[5], values[6], age
    except Exception:
        return "-", "-", "-", "-", "-", "-", 999999

def reward_stats(now):
    cache = BASE / "reward_summary.tsv"
    try:
        values = cache.read_text(errors="replace").strip().split("\t")
        values += ["-"] * (13 - len(values))
        age = max(0, now - int(values[0]))
        return values[2], values[3], values[4], values[5], values[7], values[8], values[9], values[10], values[11], values[12], age
    except Exception:
        return ("-",) * 10 + (999999,)

def render():
    node = (BASE / "node_name").read_text(errors="ignore").strip() if (BASE / "node_name").exists() else os.uname().nodename
    version = (BASE / "version").read_text(errors="ignore").strip() if (BASE / "version").exists() else "未知"
    log = latest_log()
    running, cpu, mem = process_stats()
    now = int(time.time())
    run_today, run_total = run_stats()
    pool_active, pool_total, pool_used, pool_cap, pool_free, pool_default, pool_age = pool_stats(now)
    earned, paid, pending, frozen, reward_today, reward_week, reward_avg, last_reward, last_reward_ts, last_reward_status, reward_age = reward_stats(now)

    if not log:
        fields = ["NO_LOG"] + ["-"] * 12
        age = 999999
    else:
        fields = parse(log)
        age = max(0, now - int(log.stat().st_mtime))
    state, pos, run, layer, epoch, p2p, activity_age, detail, fails, oks, reg_error, reg_age, queue_warn_age = fields
    if not running:
        state = "STOPPED"
    elif age > 180:
        state = "STALE"
    elif (BASE / "restart_required.tsv").exists() and state != "TRAINING":
        state = "RESTART_REQUIRED"

    icon, label = LABELS.get(state, ("🔴", "状态未确认"))
    free = shutil.disk_usage("/").free / 1024**3
    lines = [
        "==============================================",
        f"       IOTA GUARDIAN V{version} 本机实时监控",
        "==============================================",
        "",
        f"机器：            {node}",
        f"当前时间：        {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "",
        f"状态：            {icon} {state}（{label}）",
        f"IOTA进程：        {'运行中' if running else '未运行'} | CPU {cpu:.1f}% | 内存 {mem:.1f}%",
    ]
    if pos != "-": lines.append(f"队列位置：        {pos}")
    if state == "QUEUED": lines.append("Run：             未分配（排队中）")
    elif state in {"CONFIRMED", "PROCESSING"}: lines.append("Run：             等待服务端分配")
    if run != "-": lines.append(f"Run：             {run}")
    if layer != "-": lines.append(f"Layer：           {layer}")
    if epoch != "-": lines.append(f"Epoch：           {epoch}")
    if p2p != "-":
        warning = ""
        try:
            ok, total = map(int, p2p.split("/"))
            if total and ok * 100 < total * 25: warning = "  ⚠️ 偏低"
        except Exception: pass
        lines.append(f"P2P：             {p2p}{warning}")
    lines.append(f"本机Run统计：     今日 {run_today} 个 | 累计 {run_total} 个")
    if pool_active != "-":
        pool_line = f"官方Run池：       活跃 {pool_active} 个"
        if pool_used != "-" and pool_cap != "-": pool_line += f" | 已用 {pool_used}/{pool_cap}"
        if pool_free != "-": pool_line += f" | 空位 {pool_free}"
        if pool_age > 1800: pool_line += "  ⚠️ 数据超过30分钟"
        lines.append(pool_line)
    if earned != "-":
        reward_line = f"官方收益：       累计 {earned} α | 今日结算 +{reward_today} | 7日均值 {reward_avg}/日"
        if reward_age > 7200: reward_line += "  ⚠️ 数据超过2小时"
        lines.append(reward_line)
        lines.append(f"结算状态：       已支付 {paid} | 待支付 {pending} | 冻结 {frozen}")
    else:
        lines.append("官方收益：       待识别本机公开 hotkey（进入Run后自动获取）")
    lines += [
        f"最近有效计算：    {duration(activity_age)}" if activity_age != "-" else "最近有效计算：    暂无",
        f"判断依据：        {detail if detail != '-' else '暂无'}",
        f"Activation：      成功ACK {oks if oks != '-' else '0'} | 失败 {fails if fails != '-' else '0'}",
    ]
    if reg_error != "-" and int(reg_age or 999999) <= 21600:
        lines.append(f"最近注册问题：    {reg_error}（{duration(reg_age)}前）")
    if queue_warn_age != "-" and int(queue_warn_age or 999999) <= 600:
        lines.append("调度接口：        ⚠️ register.queue_state 503")
    lines += [
        "",
        f"当前日志：        {log.name if log else '未找到'}",
        f"日志最后更新：    {duration(age)}前",
        f"磁盘可用：        {free:.1f} GB",
        "",
        f"每{REFRESH}秒刷新 | Ctrl+C 仅关闭此窗口，不会停止 IOTA",
        "全部Run池：      ~/.iota-guardian/show_runs.sh",
        "==============================================",
    ]
    sys.stdout.write("\033[2J\033[H" + "\n".join(lines) + "\n")
    sys.stdout.flush()

def main():
    try:
        while True:
            render()
            time.sleep(REFRESH)
    except KeyboardInterrupt:
        print("\n已关闭本机显示，IOTA和后台监控继续运行。")

if __name__ == "__main__":
    main()
PY

cat > "$STAGE/show_monitor.sh" <<'DASH'
#!/bin/zsh
exec /usr/bin/python3 "$HOME/.iota-guardian/dashboard.py"
DASH

cat > "$STAGE/runs_view.py" <<'PY'
#!/usr/bin/python3
"""Read public Macrocosmos Run APIs; never changes local IOTA state."""
import gzip, json, re, sys, time
from urllib.request import Request, urlopen

URLS = (
    "https://iota-web.api.macrocosmos.ai/mainnet/runs",
    "https://iota-web.api.macrocosmos.ai/mainnet/v1/runs_occupancy",
)
RUN_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+(?:-[A-Za-z0-9_-]+)?$")

def fetch(url):
    req = Request(url, headers={"User-Agent": "IOTA-Guardian/6.5.1", "Accept": "application/json"})
    with urlopen(req, timeout=12) as res:
        body = res.read()
        if res.headers.get("Content-Encoding", "").lower() == "gzip" or body[:2] == b"\x1f\x8b":
            body = gzip.decompress(body)
        return json.loads(body.decode("utf-8"))

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def run_id(obj):
    for key in ("run_id", "run", "id", "name"):
        value = obj.get(key)
        if isinstance(value, str) and RUN_RE.match(value):
            return value
    return ""

def first_number(obj, keys):
    for key in keys:
        value = obj.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return int(value)
    return None

def list_value(values, index):
    if isinstance(values, list) and index < len(values):
        value = values[index]
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return int(value)
    return None

runs_data = occupancy_data = {}
errors = []
try:
    runs_data = fetch(URLS[0])
except Exception as exc:
    errors.append("runs: " + str(exc))
try:
    occupancy_data = fetch(URLS[1])
except Exception as exc:
    errors.append("occupancy: " + str(exc))
if not runs_data and not occupancy_data:
    print("官方 Run 接口暂时无法访问：" + "; ".join(errors))
    print("这只影响池子查询，不影响本机监控和 IOTA 训练。")
    raise SystemExit(1)

runs = {}
source_runs = runs_data.get("runs", []) if isinstance(runs_data, dict) else []
if isinstance(source_runs, list):
    for obj in source_runs:
        if not isinstance(obj, dict):
            continue
        rid = run_id(obj)
        if rid:
            runs.setdefault(rid, {}).update(obj)
if not runs:
    for obj in walk(runs_data):
        rid = run_id(obj)
        if rid:
            runs.setdefault(rid, {}).update(obj)

# Current occupancy endpoint returns parallel arrays. Keep the older object
# parser as a fallback in case Macrocosmos changes the schema again.
columnar = False
if isinstance(occupancy_data, dict) and isinstance(occupancy_data.get("run_ids"), list):
    columnar = True
    for index, rid in enumerate(occupancy_data["run_ids"]):
        if not isinstance(rid, str) or not RUN_RE.match(rid):
            continue
        obj = runs.setdefault(rid, {})
        for source, target in (("max_miners", "max_miners"),
                               ("active_miners", "active_miners"),
                               ("slots_remaining", "slots_remaining")):
            value = list_value(occupancy_data.get(source), index)
            if value is not None:
                obj[target] = value
if not columnar:
    for obj in walk(occupancy_data):
        rid = run_id(obj)
        if rid:
            runs.setdefault(rid, {}).update(obj)

def key(rid):
    return tuple(int(x) for x in re.findall(r"\d+", rid)[:4])

if not runs:
    print("接口已响应，但没有识别到 Run；项目方可能调整了接口格式。")
    raise SystemExit(2)

active_ids = [rid for rid, obj in runs.items()
              if str(obj.get("state") or obj.get("status") or "active").lower() == "active"]
visible_ids = active_ids or list(runs)
used_total = cap_total = slots_total = 0
used_known = cap_known = slots_known = False
for rid in visible_ids:
    obj = runs[rid]
    used = first_number(obj, ("active_miners", "current_miners", "miners", "occupied", "occupancy", "current"))
    cap = first_number(obj, ("max_miners", "capacity", "total_slots", "max_nodes", "total"))
    slots = first_number(obj, ("slots_remaining", "remaining", "available_slots", "free_slots"))
    if used is not None:
        used_total += used; used_known = True
    if cap is not None and cap > 0:
        cap_total += cap; cap_known = True
    if slots is not None:
        slots_total += slots; slots_known = True
    elif used is not None and cap is not None and cap > 0:
        slots_total += max(0, cap - used); slots_known = True

default_id = next((rid for rid in visible_ids if runs[rid].get("is_default") is True), "-")
if "--summary-tsv" in sys.argv:
    print("\t".join((str(int(time.time())), str(len(visible_ids)), str(len(runs)),
                      str(used_total) if used_known else "-",
                      str(cap_total) if cap_known else "-",
                      str(slots_total) if slots_known else "-", default_id)))
    raise SystemExit

print("===== Macrocosmos IOTA 当前 Run 池 =====")
summary = f"活跃 {len(visible_ids)} 个"
if used_known and cap_known:
    summary += f" | 已用 {used_total}/{cap_total}"
if slots_known:
    summary += f" | 空位 {slots_total}"
print(summary)
for rid in sorted(visible_ids, key=key, reverse=True):
    obj = runs[rid]
    used = first_number(obj, ("active_miners", "current_miners", "miners", "occupied", "occupancy", "current"))
    cap = first_number(obj, ("max_miners", "capacity", "total_slots", "max_nodes", "total"))
    slots = first_number(obj, ("slots_remaining", "remaining", "available_slots", "free_slots"))
    status = obj.get("state") or obj.get("status") or ("active" if obj.get("active") is True or obj.get("is_active") is True else "")
    detail = []
    if status: detail.append(str(status))
    if used is not None and cap is not None:
        free = slots if slots is not None else max(0, cap-used)
        detail.append(f"{used}/{cap}，空位{free}")
    elif used is not None: detail.append(f"当前{used}")
    elif cap is not None: detail.append(f"容量{cap}")
    metadata = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
    desc = metadata.get("description")
    if desc: detail.append(str(desc))
    if obj.get("is_default") is True: detail.append("默认池")
    print(f"{rid}" + (" | " + " | ".join(detail) if detail else ""))
print(f"合计识别：{len(visible_ids)} 个活跃 Run（接口总记录 {len(runs)}）")
PY

cat > "$STAGE/run_tracker.py" <<'PY'
#!/usr/bin/python3
"""Persist unique Run participation without touching IOTA state."""
import os, re, sys
from datetime import datetime
from pathlib import Path

path = Path.home() / ".iota-guardian" / "run_history.tsv"
rid = sys.argv[1].strip() if len(sys.argv) > 1 else ""
valid = re.compile(r"^\d+\.\d+\.\d+\.\d+(?:-[A-Za-z0-9_-]+)?$")
now = datetime.now().astimezone().isoformat(timespec="seconds")
today = now[:10]
rows = {}
if path.exists():
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) >= 4 and valid.match(parts[0]):
            try: samples = int(parts[3])
            except ValueError: samples = 0
            rows[parts[0]] = [parts[1], parts[2], samples]
if rid and valid.match(rid):
    if rid in rows:
        rows[rid][1] = now
        rows[rid][2] += 1
    else:
        rows[rid] = [now, now, 1]
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tsv.tmp")
    tmp.write_text("".join(f"{key}\t{value[0]}\t{value[1]}\t{value[2]}\n"
                           for key, value in sorted(rows.items())), encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
today_count = sum(1 for value in rows.values() if value[1].startswith(today))
print(f"{today_count}\t{len(rows)}")
PY

cat > "$STAGE/reward_tracker.py" <<'PY'
#!/usr/bin/python3
"""Read public IOTA entitlement data for this miner hotkey. Never reads wallet secrets."""
import gzip, json, os, re, sys, time
from datetime import datetime
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

BASE = Path.home() / ".iota-guardian"
LOGDIR = Path.home() / "Library/Logs/IOTA Train at Home"
HOTKEY_FILE = BASE / "hotkey"
LOOKUP_FILE = BASE / "hotkey_lookup_epoch"
SUMMARY_FILE = BASE / "reward_summary.tsv"
API = "https://iota-web.api.macrocosmos.ai/mainnet"
SS58 = re.compile(r"5[1-9A-HJ-NP-Za-km-z]{47}")
PREFIX = re.compile(r"Miner\s+(5[1-9A-HJ-NP-Za-km-z]{7})\s+(?:registered successfully|in Layer)", re.I)

def get(url):
    req = Request(url, headers={"User-Agent": "IOTA-Guardian/6.5.1", "Accept": "application/json"})
    with urlopen(req, timeout=20) as response:
        body = response.read()
        if response.headers.get("Content-Encoding", "").lower() == "gzip" or body[:2] == b"\x1f\x8b":
            body = gzip.decompress(body)
        return json.loads(body.decode("utf-8"))

def read_tail(path, limit=8 * 1024 * 1024):
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            size = stream.tell()
            stream.seek(max(0, size - limit))
            return stream.read().decode("utf-8", errors="replace")
    except Exception:
        return ""

def cached_hotkey():
    try:
        value = HOTKEY_FILE.read_text().strip()
        return value if SS58.fullmatch(value) else ""
    except Exception:
        return ""

def save_hotkey(value):
    tmp = HOTKEY_FILE.with_suffix(".tmp")
    tmp.write_text(value + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, HOTKEY_FILE)

def discover_hotkey():
    files = sorted(LOGDIR.glob("*-cli*.log"), key=lambda p: p.stat().st_mtime, reverse=True)[:6]
    texts = [read_tail(path) for path in files]
    prefix = ""
    # Prefer a full key on a line explicitly naming the hotkey.
    for text in texts:
        for line in reversed(text.splitlines()):
            if "hotkey" in line.lower():
                matches = SS58.findall(line)
                if matches:
                    return matches[-1]
            match = PREFIX.search(line)
            if match and not prefix:
                prefix = match.group(1)
    if not prefix:
        for text in texts:
            match = PREFIX.search(text)
            if match:
                prefix = match.group(1); break
    if prefix:
        for text in texts:
            matches = re.findall(re.escape(prefix) + r"[1-9A-HJ-NP-Za-km-z]{40}", text)
            if matches:
                return matches[-1]
    # Avoid repeatedly scanning every official Run while the miner is still queued.
    now = int(time.time())
    try: last_lookup = int(LOOKUP_FILE.read_text().strip())
    except Exception: last_lookup = 0
    if not prefix or now - last_lookup < 21600:
        return ""
    LOOKUP_FILE.write_text(str(now) + "\n")
    try:
        runs = get(API + "/runs").get("runs", [])
        found = set()
        for run in runs:
            if run.get("state") != "active" or not run.get("run_id"):
                continue
            miners = get(API + "/miners?run_id=" + quote(str(run["run_id"]), safe="-.")).get("miners", [])
            for miner in miners:
                value = miner.get("hotkey", "")
                if isinstance(value, str) and value.startswith(prefix) and SS58.fullmatch(value):
                    found.add(value)
        if len(found) == 1:
            return found.pop()
    except Exception:
        pass
    return ""

def number(value):
    try: return float(value)
    except (TypeError, ValueError): return 0.0

def fmt(value):
    return f"{value:.8f}".rstrip("0").rstrip(".") or "0"

hotkey = cached_hotkey() or discover_hotkey()
if not hotkey:
    print("尚未识别本机公开 hotkey；进入 Run 后会自动重试。", file=sys.stderr)
    raise SystemExit(2)
save_hotkey(hotkey)

totals = get(API + "/v1/entitlements/totals/hotkey/" + quote(hotkey, safe=""))
try:
    history = get(API + "/v1/entitlements/history/hotkey/" + quote(hotkey, safe=""))
except Exception:
    history = {}

earned = number(totals.get("total_amount_earned"))
paid = number(totals.get("total_amount_paid"))
pending = number(totals.get("total_amount_pending"))
frozen = number(totals.get("total_amount_frozen"))
minimum = number(totals.get("minimum_payout_amount"))
amounts = history.get("alpha_amounts", []) if isinstance(history, dict) else []
timestamps = history.get("timestamps", []) if isinstance(history, dict) else []
statuses = history.get("statuses", []) if isinstance(history, dict) else []
events = []
for index, timestamp in enumerate(timestamps if isinstance(timestamps, list) else []):
    if index >= len(amounts): break
    try:
        epoch = int(timestamp); amount = float(amounts[index])
    except (TypeError, ValueError):
        continue
    status = str(statuses[index]) if isinstance(statuses, list) and index < len(statuses) else "unknown"
    events.append((epoch, amount, status))

now = int(time.time())
local_today = datetime.fromtimestamp(now).astimezone().date()
today_amount = sum(amount for epoch, amount, _ in events
                   if datetime.fromtimestamp(epoch).astimezone().date() == local_today)
seven_amount = sum(amount for epoch, amount, _ in events if epoch >= now - 7 * 86400)
seven_average = seven_amount / 7.0
if events:
    last_epoch, last_amount, last_status = max(events, key=lambda item: item[0])
else:
    last_epoch, last_amount, last_status = 0, 0.0, "-"

fields = (str(now), hotkey, fmt(earned), fmt(paid), fmt(pending), fmt(frozen), fmt(minimum),
          fmt(today_amount), fmt(seven_amount), fmt(seven_average), fmt(last_amount),
          str(last_epoch), last_status.replace("\t", " ").replace("\n", " "))
tmp = SUMMARY_FILE.with_suffix(".tsv.tmp")
tmp.write_text("\t".join(fields) + "\n", encoding="utf-8")
os.chmod(tmp, 0o600)
os.replace(tmp, SUMMARY_FILE)
print("\t".join(fields))
PY

cat > "$STAGE/runs_refresh.sh" <<'REFRESH'
#!/bin/zsh
set -u
BASE="$HOME/.iota-guardian"
SUMMARY_TMP="$BASE/run_pool_summary.tsv.tmp"
if /usr/bin/python3 "$BASE/runs_view.py" --summary-tsv > "$SUMMARY_TMP" 2> "$BASE/run-pool-error.log"; then
  mv "$SUMMARY_TMP" "$BASE/run_pool_summary.tsv"
else
  rm -f "$SUMMARY_TMP"
fi
tail -n 30 "$BASE/run-pool-error.log" > "$BASE/run-pool-error.log.tmp" 2>/dev/null && mv "$BASE/run-pool-error.log.tmp" "$BASE/run-pool-error.log"
REFRESH

cat > "$STAGE/rewards_refresh.sh" <<'REWARDS'
#!/bin/zsh
set -u
BASE="$HOME/.iota-guardian"
# Existing installations stagger requests so a large Mac fleet does not hit the public API at once.
[[ ! -s "$BASE/reward_summary.tsv" ]] || sleep $(( RANDOM % 120 ))
if ! /usr/bin/python3 "$BASE/reward_tracker.py" > /dev/null 2> "$BASE/reward-error.log"; then
  # Keep the last successful figures. Reward API failure must never mark IOTA down.
  tail -n 30 "$BASE/reward-error.log" > "$BASE/reward-error.log.tmp" 2>/dev/null && mv "$BASE/reward-error.log.tmp" "$BASE/reward-error.log"
fi
REWARDS

cat > "$STAGE/show_runs.sh" <<'RUNS'
#!/bin/zsh
/usr/bin/python3 "$HOME/.iota-guardian/runs_view.py"
RUNS

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
LAST="$BASE/last_state"; QUEUE_START="$BASE/queue_start_epoch"; RESTART_LATCH="$BASE/restart_required.tsv"
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
print -r -- "$RESULT" > "$BASE/current_record.tsv.tmp" && mv "$BASE/current_record.tsv.tmp" "$BASE/current_record.tsv"
IFS=$'\t' read -r STATE POS RUNID LAYER EPOCH P2P ACTIVEAGE DETAIL FAILS OKS REGERROR REGERRORAGE QUEUEWARNAGE RESETEVENT BOOTEVENT ACTIVITYEVENT <<< "$RESULT"
[[ -n "${STATE:-}" ]] || STATE=UNKNOWN
for FIELD in POS RUNID LAYER EPOCH P2P REGERROR; do
  [[ "${(P)FIELD:-}" == "-" ]] && typeset -g "$FIELD="
done
RESETEVENT=${RESETEVENT:-0}; BOOTEVENT=${BOOTEVENT:-0}; ACTIVITYEVENT=${ACTIVITYEVENT:-0}

# Persist the warning because QUEUED otherwise replaces RESETTING within seconds.
# It is cleared only by a later full client start or later real training activity.
if [[ "$RESETEVENT" == <-> ]] && (( RESETEVENT > 0 )); then
  OLD_ALERT=$(cut -f1 "$RESTART_LATCH" 2>/dev/null || echo 0)
  [[ "$OLD_ALERT" == <-> ]] || OLD_ALERT=0
  if (( RESETEVENT > OLD_ALERT )); then
    print -r -- "$RESETEVENT"$'\t'"$NOWTXT" > "$RESTART_LATCH"
  fi
fi
ALERT_TS=$(cut -f1 "$RESTART_LATCH" 2>/dev/null || echo 0)
[[ "$ALERT_TS" == <-> ]] || ALERT_TS=0
CLEAR_TS=0
[[ "$BOOTEVENT" == <-> ]] && (( BOOTEVENT > CLEAR_TS )) && CLEAR_TS=$BOOTEVENT
[[ "$ACTIVITYEVENT" == <-> ]] && (( ACTIVITYEVENT > CLEAR_TS )) && CLEAR_TS=$ACTIVITYEVENT
(( ALERT_TS > 0 && CLEAR_TS > ALERT_TS )) && { rm -f "$RESTART_LATCH"; ALERT_TS=0; }

TRACKID=""
case "$STATE" in
  TRAINING|MERGING|SYNCING|RUN_IDLE|INITIALIZING) TRACKID="${RUNID:-}" ;;
esac
RUNSTATS=$(/usr/bin/python3 "$BASE/run_tracker.py" "$TRACKID" 2>/dev/null || print -r -- $'0\t0')
IFS=$'\t' read -r RUNTODAY RUNTOTAL <<< "$RUNSTATS"
RUNTODAY=${RUNTODAY:-0}; RUNTOTAL=${RUNTOTAL:-0}
POOLTXT=""
if [[ -s "$BASE/run_pool_summary.tsv" ]]; then
  IFS=$'\t' read -r POOLTIME POOLACTIVE POOLALL POOLUSED POOLCAP POOLFREE POOLDEFAULT < "$BASE/run_pool_summary.tsv"
  if [[ -n "${POOLACTIVE:-}" && "$POOLACTIVE" != "-" ]]; then
    POOLTXT=" | 官方池${POOLACTIVE}个"
    [[ -n "${POOLUSED:-}" && "$POOLUSED" != "-" && -n "${POOLCAP:-}" && "$POOLCAP" != "-" ]] && POOLTXT="${POOLTXT} · ${POOLUSED}/${POOLCAP}"
    [[ -n "${POOLFREE:-}" && "$POOLFREE" != "-" ]] && POOLTXT="${POOLTXT} · 空位${POOLFREE}"
    (( NOW-${POOLTIME:-0} <= 1800 )) || POOLTXT="${POOLTXT}(数据过期)"
  fi
fi
REWARDTXT=""
if [[ -s "$BASE/reward_summary.tsv" ]]; then
  IFS=$'\t' read -r REWARDTIME REWARDHOTKEY REWARDEARNED REWARDPAID REWARDPENDING REWARDFROZEN REWARDMIN REWARDTODAY REWARDWEEK REWARDAVG REWARDLAST REWARDLASTTIME REWARDSTATUS < "$BASE/reward_summary.tsv"
  if [[ -n "${REWARDEARNED:-}" && "$REWARDEARNED" != "-" ]]; then
    REWARDTXT=" | 收益累计${REWARDEARNED}α · 今日结算+${REWARDTODAY:-0} · 待付${REWARDPENDING:-0}"
    [[ "${REWARDTIME:-}" == <-> ]] && (( NOW-REWARDTIME <= 7200 )) || REWARDTXT="${REWARDTXT}(数据过期)"
  fi
fi
CPU=$(/bin/ps -A -o %cpu=,command= | awk '/main_pool/ && !/awk/{s+=$1} END{printf "%.0f",s+0}')
RUNINFO=""; [[ -n "$RUNID" ]] && RUNINFO="Run ${RUNID}"; [[ -n "$LAYER" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }L${LAYER}"; [[ -n "$EPOCH" ]] && RUNINFO="${RUNINFO}${RUNINFO:+ · }E${EPOCH}"; [[ -n "$RUNINFO" ]] || RUNINFO="Run待更新"
OLD=$(cat "$LAST" 2>/dev/null || echo '')
if [[ "$STATE" == QUEUED ]]; then
  [[ -s "$QUEUE_START" ]] || print -r -- "$NOW" > "$QUEUE_START"
else rm -f "$QUEUE_START"; fi
QTXT=""; [[ "$STATE" == QUEUED && -s "$QUEUE_START" ]] && QTXT=$(duration $((NOW-$(cat "$QUEUE_START"))))
ATXT="无近期有效计算"; [[ "$ACTIVEAGE" != 999999 ]] && ATXT="上次有效计算$(duration "$ACTIVEAGE")前"
WARN=""
[[ -n "${REGERROR:-}" && "${REGERRORAGE:-999999}" -le 21600 ]] && WARN=" | 上轮确认失败 ${REGERROR}"
[[ "${QUEUEWARNAGE:-999999}" -le 600 ]] && WARN="${WARN} | 调度接口503"
NETWARN=""
if [[ "$P2P" =~ '^([0-9]+)/([0-9]+)$' ]] && (( match[2] > 0 && match[1] * 100 < match[2] * 25 )); then
  NETWARN=" | P2P偏低 ${P2P}"
fi

case "$STATE" in
 TRAINING) STATUS=up; MSG="🟢 真实训练 | TRAINING | ${RUNINFO} | ${DETAIL} | ${ATXT} | CPU ${CPU}% | P2P ${P2P:-待更新}${NETWARN} | 日志${AGE}秒" ;;
 MERGING) STATUS=up; MSG="🟡 合并阶段 | MERGING | ${RUNINFO} | 当前没有训练计算属正常 | ${ATXT} | 日志${AGE}秒" ;;
 SYNCING) STATUS=up; MSG="🟡 权重同步 | SYNCING | ${RUNINFO} | 正在上传/下载/设置模型权重${NETWARN} | CPU ${CPU}% | 日志${AGE}秒" ;;
 RUN_IDLE) STATUS=up; MSG="🟠 池内等待 | RUN_IDLE | ${RUNINFO} | 已在Run但近期无有效计算 | ${ATXT}${NETWARN} | CPU ${CPU}% | 日志${AGE}秒" ;;
 INITIALIZING) STATUS=up; MSG="🟠 训练池初始化 | INITIALIZING | ${RUNINFO} | 尚未出现有效计算 | 日志${AGE}秒" ;;
 CONFIRMED) STATUS=up; MSG="🔵 已到队首确认 | CONFIRMED | 服务端已确认，尚未分配Run | 日志${AGE}秒" ;;
 PROCESSING) STATUS=up; MSG="🟠 注册处理中 | PROCESSING | 正在验证设备并分配Run | 日志${AGE}秒" ;;
 REG_FAILED) STATUS=down; MSG="🔴 注册确认失败 | REG_FAILED${REGERROR:+ | ${REGERROR}} | 客户端通常会自动重新排队 | 日志${AGE}秒" ;;
 QUEUED) STATUS=up; MSG="🔵 正常排队 | QUEUED${POS:+ | 位置${POS}} | 已排${QTXT:-0分钟} | 尚未训练${WARN} | 日志${AGE}秒" ;;
 RESETTING) STATUS=down; MSG="🔴 注册被重置 | RESETTING | 已失去Run注册，等待重新排队 | 日志${AGE}秒" ;;
 CRASHED) STATUS=down; MSG="🔴 程序崩溃 | CRASHED | miner异常退出 | 日志${AGE}秒" ;;
 STOPPED) STATUS=down; MSG="🔴 IOTA停止 | STOPPED | 请点击 Start training | 日志${AGE}秒" ;;
 *) STATUS=down; MSG="🔴 状态未确认 | UNKNOWN | 进程存在但没有可确认状态 | CPU ${CPU}% | 日志${AGE}秒" ;;
esac

# Keep the reset warning visible while live queue details continue to refresh.
if [[ -s "$RESTART_LATCH" ]]; then
  ALERT_TS=$(cut -f1 "$RESTART_LATCH" 2>/dev/null || echo 0)
  ALERT_WHEN=$(/bin/date -r "${ALERT_TS:-0}" '+%m-%d %H:%M' 2>/dev/null || echo "时间待更新")
  LIVE="当前状态${STATE}"
  [[ "$STATE" == QUEUED ]] && LIVE="当前已重新排队${POS:+，位置${POS}}"
  [[ "$STATE" == CONFIRMED ]] && LIVE="当前已到队首确认"
  [[ "$STATE" == PROCESSING ]] && LIVE="当前注册处理中"
  STATE=RESTART_REQUIRED
  STATUS=down
  MSG="🔴 训练中途被重置 | RESTART_REQUIRED | ${ALERT_WHEN}出现缓存测速界面 | ${LIVE} | 建议手动重启；若自动恢复真实训练将解除 | 日志${AGE}秒"
fi
((D<90)) || { STATUS=down; MSG="🔴 磁盘严重不足 | ${D}% | $MSG"; }
MSG="$MSG | 今日Run ${RUNTODAY} · 累计${RUNTOTAL}${POOLTXT}${REWARDTXT}"
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
TRAIN=$(count TRAINING); MERGE=$(count MERGING); SYNC=$(count SYNCING)
TOTAL=$(awk 'END{print (NR>0 ? NR-1 : 0)}' "$S" 2>/dev/null); TOTAL=${TOTAL:-0}
PRODUCTIVE=$((TRAIN+MERGE+SYNC)); RATE=0; ((TOTAL>0)) && RATE=$((PRODUCTIVE*100/TOTAL))
RUNSTATS=$(/usr/bin/python3 "$BASE/run_tracker.py" "" 2>/dev/null || print -r -- $'0\t0')
IFS=$'\t' read -r RUNTODAY RUNTOTAL <<< "$RUNSTATS"
POOL=$(cat "$BASE/run_pool_summary.tsv" 2>/dev/null || true)
POOLL="暂无"
if [[ -n "$POOL" ]]; then
  IFS=$'\t' read -r PT PA PALL PU PC PF PD <<< "$POOL"
  POOLL="活跃${PA}个"
  [[ "$PU" != "-" && "$PC" != "-" ]] && POOLL="${POOLL}，已用${PU}/${PC}"
  [[ "$PF" != "-" ]] && POOLL="${POOLL}，空位${PF}"
fi
REWARDL="待识别hotkey或官方接口暂不可用"
if [[ -s "$BASE/reward_summary.tsv" ]]; then
  IFS=$'\t' read -r RT RH RE RP RPN RF RM RDAY RWEEK RAVG RLAST RLASTT RSTATUS < "$BASE/reward_summary.tsv"
  REWARDL="累计${RE} α，今日结算+${RDAY}，7日合计${RWEEK}，7日均值${RAVG}/日，已支付${RP}，待支付${RPN}，冻结${RF}"
fi
cat > "$R" <<EOF2
IOTA Guardian V6.5.1 每日报告
日期：$TODAY
电脑：$(cat "$BASE/node_name" 2>/dev/null)
本机参与Run：今日 ${RUNTODAY:-0} 个 / 累计 ${RUNTOTAL:-0} 个
官方Run池：$POOLL
官方收益：$REWARDL
真实训练：约 $TRAIN 分钟
合并阶段：约 $MERGE 分钟
权重同步：约 $SYNC 分钟
有效在线占比：约 ${RATE}%（训练+合并+权重同步 / 当日监控样本）
池内等待：约 $(count RUN_IDLE) 分钟
排队：约 $(count QUEUED) 分钟
注册阶段：CONFIRMED $(count CONFIRMED) / PROCESSING $(count PROCESSING) / REG_FAILED $(count REG_FAILED) 分钟
故障：RESTART_REQUIRED $(count RESTART_REQUIRED) / RESETTING $(count RESETTING) / CRASHED $(count CRASHED) / STOPPED $(count STOPPED) / STALE $(count STALE) 分钟
当前：$(cat "$BASE/current_message" 2>/dev/null)
EOF2
find "$BASE/reports" -type f -mtime +31 -delete 2>/dev/null || true
REPORT

cat > "$STAGE/show_report.sh" <<'SHOW'
#!/bin/zsh
BASE="$HOME/.iota-guardian"
echo "===== IOTA Guardian V6.5.1 Run与收益增强版 ====="
echo "版本：$(cat "$BASE/version" 2>/dev/null)"
echo "电脑：$(cat "$BASE/node_name" 2>/dev/null)"
echo "当前：$(cat "$BASE/current_message" 2>/dev/null)"
echo "Run统计：$(/usr/bin/python3 "$BASE/run_tracker.py" "" 2>/dev/null | awk -F '\t' '{print "今日"$1"个 / 累计"$2"个"}')"
echo "官方Run池：$(awk -F '\t' '{s="活跃"$2"个"; if($4!="-"&&$5!="-")s=s"，已用"$4"/"$5; if($6!="-")s=s"，空位"$6; print s}' "$BASE/run_pool_summary.tsv" 2>/dev/null || echo "暂未取得")"
echo "官方收益：$(awk -F '\t' '{print "累计"$3" α，今日结算+"$8"，7日均值"$10"/日，已支付"$4"，待支付"$5"，冻结"$6}' "$BASE/reward_summary.tsv" 2>/dev/null || echo "暂未取得")"
echo "最近状态变化："; tail -n 15 "$BASE/events.csv" 2>/dev/null
echo; "$BASE/show_runs.sh" 2>/dev/null || true
SHOW

for item in monitor.sh runs_refresh.sh rewards_refresh.sh show_monitor.sh show_runs.sh cleanup.sh daily_report.sh show_report.sh; do chmod 700 "$STAGE/$item"; done
chmod 700 "$STAGE/status_engine.py" "$STAGE/dashboard.py" "$STAGE/runs_view.py" "$STAGE/run_tracker.py" "$STAGE/reward_tracker.py"
/usr/bin/python3 -m py_compile "$STAGE/status_engine.py"
/usr/bin/python3 -m py_compile "$STAGE/dashboard.py"
/usr/bin/python3 -m py_compile "$STAGE/runs_view.py"
/usr/bin/python3 -m py_compile "$STAGE/run_tracker.py"
/usr/bin/python3 -m py_compile "$STAGE/reward_tracker.py"

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
make_plist "$POOL_LABEL" runs_refresh.sh '<key>RunAtLoad</key><true/><key>StartInterval</key><integer>600</integer>'
make_plist "$REWARD_LABEL" rewards_refresh.sh '<key>RunAtLoad</key><true/><key>StartInterval</key><integer>3600</integer>'
for label in "$MONITOR_LABEL" "$CLEAN_LABEL" "$REPORT_LABEL" "$POOL_LABEL" "$REWARD_LABEL"; do plutil -lint "$STAGE/$label.plist" >/dev/null; done

# 仅停用本系列旧监控，不碰 IOTA、钱包、hotkey 或第三方 hub agent。
for plist in "$LAUNCH"/com.baibai.iota-log-monitor.plist "$LAUNCH"/com.baibai.iota-guardian*.plist; do
  [[ -f "$plist" ]] || continue
  old_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || echo '')
  [[ -n "$old_label" && "$old_label" == "${${plist:t}%.plist}" ]] || { echo "旧监控标签不匹配，停止安装：$plist"; exit 1; }
  launchctl print "$GUI_DOMAIN/$old_label" >/dev/null 2>&1 && launchctl bootout "$GUI_DOMAIN/$old_label"
  mv "$plist" "$BACKUP/LaunchAgents/"
done
for item in monitor.sh status_engine.py dashboard.py runs_view.py run_tracker.py reward_tracker.py runs_refresh.sh rewards_refresh.sh show_monitor.sh show_runs.sh cleanup.sh daily_report.sh show_report.sh; do /usr/bin/install -m 700 "$STAGE/$item" "$BASE/$item"; done
for item in node_name push_url version; do /usr/bin/install -m 600 "$STAGE/$item" "$BASE/$item"; done
for label in "$MONITOR_LABEL" "$CLEAN_LABEL" "$REPORT_LABEL" "$POOL_LABEL" "$REWARD_LABEL"; do /usr/bin/install -m 600 "$STAGE/$label.plist" "$LAUNCH/$label.plist"; launchctl bootstrap "$GUI_DOMAIN" "$LAUNCH/$label.plist"; done
mv "$STAGE" "$BACKUP/staged-install"; trap - ZERR

echo
echo "✅ IOTA Guardian V6.5.1 安装/升级完成"
echo "电脑：$(cat "$BASE/node_name")"
echo "60秒检测一次；日志超过180秒才判定 STALE。"
echo "TRAINING=真实计算；MERGING=合并；SYNCING=权重同步；CONFIRMED/PROCESSING=注册中；QUEUED=排队。"
echo "RESTART_REQUIRED=训练中途重置后出现缓存测速；人工重启或恢复真实训练后自动解除。"
echo "查看全部 Run 池：$BASE/show_runs.sh"
echo "打开本机实时仪表盘：$BASE/show_monitor.sh"
echo "官方 Run 池每10分钟刷新；官方收益每60分钟刷新。"
echo "收益只读取公开 hotkey 的官方 entitlement，不读取钱包、助记词或私钥。"
echo "终端和 Kuma 同时显示今日/累计参与 Run 数及官方结算收益。"
echo "本工具不会启动、停止、重启或点击 IOTA，也不会修改钱包和 miner。"
echo "请等待约60秒后查看 Uptime Kuma。"

