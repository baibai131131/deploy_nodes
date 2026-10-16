#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/iota-training-dashboard"
ENV_FILE="/etc/iota-training-dashboard.env"
SERVICE_FILE="/etc/systemd/system/iota-training-dashboard.service"

install -d -m 0755 "$APP_DIR"

cat > "$APP_DIR/server.py" <<'PY'
#!/usr/bin/env python3
import base64
import hmac
import html
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = int(os.environ.get("IOTA_DASH_PORT", "3002"))
USER = os.environ.get("IOTA_DASH_USER", "iota")
PASSWORD = os.environ["IOTA_DASH_PASSWORD"]
CACHE_SECONDS = 5

SQL = r"""
SELECT
    m.id,
    REPLACE(REPLACE(REPLACE(m.name, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' '),
    COALESCE(h.status, -1),
    COALESCE(DATE_FORMAT(h.time, '%Y-%m-%d %H:%i:%s'), ''),
    COALESCE(TIMESTAMPDIFF(SECOND, h.time, NOW()), 999999),
    LEFT(REPLACE(REPLACE(REPLACE(COALESCE(h.msg, ''), CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' '), 1000)
FROM monitor AS m
LEFT JOIN heartbeat AS h
    ON h.id = (
        SELECT h2.id
        FROM heartbeat AS h2
        WHERE h2.monitor_id = m.id
        ORDER BY h2.id DESC
        LIMIT 1
    )
WHERE m.active = 1
ORDER BY m.name;
"""

cache_lock = threading.Lock()
cache_at = 0.0
cache_rows = []
cache_error = ""

STATE_MAP = {
    "TRAINING": ("training", "真实训练"),
    "QUEUED": ("queued", "正常排队"),
    "CONFIRMED": ("ready", "准备开跑"),
    "JOINING": ("transition", "正在注册"),
    "SYNCING": ("transition", "权重同步"),
    "MERGING": ("transition", "合并阶段"),
    "INITIALIZING": ("transition", "初始化"),
    "PROCESSING": ("transition", "处理中"),
    "RUN_IDLE": ("transition", "Run空闲"),
    "REG_FAILED": ("error", "注册失败"),
    "RESETTING": ("error", "反复重置"),
    "WAITLIST_STUCK": ("restart", "需手动重启"),
    "CRASHED": ("error", "进程崩溃"),
    "STOPPED": ("error", "已经停止"),
    "UNKNOWN": ("error", "状态未知"),
}

def classify(status, age, message):
    if age > 180:
        return "offline", "上报离线"
    match = re.search(r"\|\s*([A-Z][A-Z0-9_]*)\s*\|", message)
    if match and match.group(1) in STATE_MAP:
        return STATE_MAP[match.group(1)]
    if status != 1:
        return "error", "监控异常"
    if "真实训练" in message:
        return "training", "真实训练"
    if "正常排队" in message:
        return "queued", "正常排队"
    if any(x in message for x in ("权重同步", "合并阶段", "训练池初始化")):
        return "transition", "过渡阶段"
    return "unknown", "未识别"

def query_rows():
    global cache_at, cache_rows, cache_error
    now = time.monotonic()
    with cache_lock:
        if now - cache_at < CACHE_SECONDS:
            return cache_rows, cache_error
        cmd = [
            "docker", "exec", "uptime-kuma", "mariadb",
            "--protocol=SOCKET",
            "--socket=/app/data/run/mariadb.sock",
            "--default-character-set=utf8mb4",
            "--batch", "--raw", "--skip-column-names",
            "-D", "kuma", "-e", SQL,
        ]
        try:
            result = subprocess.run(cmd, text=True, capture_output=True, timeout=15, check=True)
            rows = []
            for line in result.stdout.splitlines():
                parts = line.split("\t", 5)
                if len(parts) != 6:
                    continue
                monitor_id, name, status_s, heartbeat_time, age_s, message = parts
                status = int(status_s)
                age = int(age_s)
                state, label = classify(status, age, message)
                rows.append({
                    "id": int(monitor_id), "name": name, "status": status,
                    "heartbeat_time": heartbeat_time, "age": age,
                    "message": message, "state": state, "label": label,
                })
            order = {"restart": 0, "error": 1, "offline": 2, "training": 3, "ready": 4, "transition": 5, "unknown": 6, "queued": 7}
            rows.sort(key=lambda r: (order.get(r["state"], 9), r["name"].lower()))
            cache_rows, cache_error = rows, ""
        except Exception as exc:
            cache_error = str(exc)
        cache_at = now
        return cache_rows, cache_error

def age_text(seconds):
    if seconds < 60:
        return f"{seconds}秒前"
    if seconds < 3600:
        return f"{seconds // 60}分钟前"
    return f"{seconds // 3600}小时{(seconds % 3600) // 60}分钟前"

def render_page(rows, error):
    counts = {k: 0 for k in ("restart", "training", "ready", "queued", "transition", "error", "offline", "unknown")}
    for row in rows:
        counts[row["state"]] = counts.get(row["state"], 0) + 1
    cards = [
        ("restart", "需手动重启", counts["restart"]),
        ("training", "真实训练", counts["training"]),
        ("ready", "准备开跑", counts["ready"]),
        ("queued", "正常排队", counts["queued"]),
        ("transition", "同步/合并/初始化", counts["transition"]),
        ("error", "异常", counts["error"]),
        ("offline", "离线", counts["offline"]),
    ]
    stats = "".join(
        f'<button class="stat {key}" onclick="filterState(\'{key}\')"><b>{value}</b><span>{label}</span></button>'
        for key, label, value in cards
    )
    body_rows = []
    for row in rows:
        searchable = html.escape((row["name"] + " " + row["message"]).lower(), quote=True)
        body_rows.append(
            f'<tr class="machine {row["state"]}" data-state="{row["state"]}" data-search="{searchable}">'
            f'<td class="name">{html.escape(row["name"])}</td>'
            f'<td><span class="badge {row["state"]}">{html.escape(row["label"])}</span></td>'
            f'<td class="age">{html.escape(age_text(row["age"]))}</td>'
            f'<td class="message">{html.escape(row["message"])}</td></tr>'
        )
    error_html = f'<div class="db-error">数据库读取失败：{html.escape(error)}</div>' if error else ""
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>IOTA 训练总览</title>
<style>
:root{{--bg:#080b10;--panel:#10151d;--line:#222a36;--text:#eef3f8;--muted:#8e9bad;--green:#20df79;--cyan:#20d9e8;--blue:#3996ff;--amber:#ffb429;--red:#ff5166;--purple:#c15cff;--gray:#758094;}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
.wrap{{max-width:1800px;margin:auto;padding:22px}}header{{display:flex;justify-content:space-between;gap:20px;align-items:end;margin-bottom:18px}}h1{{margin:0;font-size:27px}}.sub{{color:var(--muted);margin-top:5px}}.clock{{color:var(--muted);text-align:right}}
.stats{{display:grid;grid-template-columns:repeat(7,minmax(120px,1fr));gap:12px;margin-bottom:16px}}.stat{{appearance:none;text-align:left;background:var(--panel);color:var(--text);border:1px solid var(--line);border-top:3px solid var(--gray);border-radius:10px;padding:14px 16px;cursor:pointer}}.stat b{{font-size:28px;display:block}}.stat span{{color:var(--muted)}}.stat.restart{{border-top-color:var(--purple)}}.stat.training{{border-top-color:var(--green)}}.stat.ready{{border-top-color:var(--cyan)}}.stat.queued{{border-top-color:var(--blue)}}.stat.transition{{border-top-color:var(--amber)}}.stat.error{{border-top-color:var(--red)}}
.tools{{display:flex;gap:10px;margin:12px 0}}input{{flex:1;min-width:220px;background:var(--panel);border:1px solid var(--line);border-radius:8px;color:var(--text);padding:11px 13px}}.all{{background:#1c2430;color:#fff;border:1px solid #344055;border-radius:8px;padding:0 16px;cursor:pointer}}
.tablebox{{overflow:auto;border:1px solid var(--line);border-radius:10px}}table{{width:100%;border-collapse:collapse;background:var(--panel)}}th{{position:sticky;top:0;background:#151b24;color:#aab4c3;text-align:left;padding:11px 12px;white-space:nowrap}}td{{padding:10px 12px;border-top:1px solid var(--line);vertical-align:top}}tr.machine{{border-left:4px solid var(--gray)}}tr.machine.restart{{border-left-color:var(--purple);background:#21102d}}tr.machine.training{{border-left-color:var(--green);background:#0d2018}}tr.machine.ready{{border-left-color:var(--cyan);background:#0a2024}}tr.machine.queued{{border-left-color:var(--blue)}}tr.machine.transition{{border-left-color:var(--amber);background:#211b0d}}tr.machine.error{{border-left-color:var(--red);background:#241016}}tr.machine.offline{{opacity:.68}}.name{{font-weight:700;white-space:nowrap}}.age{{color:var(--muted);white-space:nowrap}}.message{{min-width:520px;color:#cbd3de}}.badge{{display:inline-block;border:1px solid currentColor;border-radius:999px;padding:3px 9px;white-space:nowrap}}.badge.restart{{color:var(--purple)}}.badge.training{{color:var(--green)}}.badge.ready{{color:var(--cyan)}}.badge.queued{{color:var(--blue)}}.badge.transition{{color:var(--amber)}}.badge.error{{color:var(--red)}}.badge.offline,.badge.unknown{{color:var(--gray)}}.db-error{{background:#35131a;border:1px solid var(--red);padding:12px;border-radius:8px;margin-bottom:12px}}.hidden{{display:none}}
@media(max-width:800px){{.stats{{grid-template-columns:repeat(2,1fr)}}header{{display:block}}.clock{{text-align:left;margin-top:8px}}.wrap{{padding:12px}}}}
</style></head><body><div class="wrap">
<header><div><h1>IOTA 训练总览</h1><div class="sub">只读读取 Uptime Kuma · 每15秒自动刷新 · 共 {len(rows)} 台</div></div><div class="clock">数据库最新读取：{time.strftime('%Y-%m-%d %H:%M:%S')} UTC</div></header>
{error_html}<section class="stats">{stats}</section>
<div class="tools"><input id="search" placeholder="搜索机器名称或状态消息…" oninput="applyFilter()"><button class="all" onclick="filterState('all')">显示全部</button></div>
<div class="tablebox"><table><thead><tr><th>机器</th><th>状态</th><th>最后上报</th><th>详细信息</th></tr></thead><tbody>{''.join(body_rows)}</tbody></table></div>
</div><script>
let selected='all';function filterState(s){{selected=s;applyFilter()}}function applyFilter(){{const q=document.getElementById('search').value.toLowerCase();document.querySelectorAll('tr.machine').forEach(r=>{{const okState=selected==='all'||r.dataset.state===selected;const okText=!q||r.dataset.search.includes(q);r.classList.toggle('hidden',!(okState&&okText));}})}}
</script></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def authorized(self):
        expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        return hmac.compare_digest(self.headers.get("Authorization", ""), expected)
    def require_auth(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="IOTA Training Dashboard"')
        self.send_header("Content-Length", "0")
        self.end_headers()
    def send_bytes(self, code, content_type, data):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/health":
            return self.send_bytes(200, "text/plain; charset=utf-8", b"ok\n")
        if not self.authorized():
            return self.require_auth()
        rows, error = query_rows()
        if self.path == "/api":
            data = json.dumps({"rows": rows, "error": error}, ensure_ascii=False).encode()
            return self.send_bytes(200, "application/json; charset=utf-8", data)
        data = render_page(rows, error).encode()
        self.send_bytes(200, "text/html; charset=utf-8", data)

if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
PY

chmod 0755 "$APP_DIR/server.py"

if [[ -f "$ENV_FILE" ]]; then
  # Preserve the existing login when reinstalling/upgrading this dashboard.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  IOTA_DASH_USER="iota"
  IOTA_DASH_PASSWORD="$(openssl rand -hex 8)"
  IOTA_DASH_PORT="3002"
  umask 077
  cat > "$ENV_FILE" <<ENV
IOTA_DASH_USER=$IOTA_DASH_USER
IOTA_DASH_PASSWORD=$IOTA_DASH_PASSWORD
IOTA_DASH_PORT=$IOTA_DASH_PORT
ENV
fi

cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=IOTA Training Color Dashboard
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/iota-training-dashboard.env
ExecStart=/usr/bin/python3 /opt/iota-training-dashboard/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable iota-training-dashboard.service >/dev/null
systemctl restart iota-training-dashboard.service
sleep 2

if ! curl -fsS http://127.0.0.1:3002/health >/dev/null; then
  echo "❌ 彩色总览启动失败"
  journalctl -u iota-training-dashboard.service -n 50 --no-pager
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "========================================"
echo "✅ IOTA 彩色训练总览安装成功"
echo "地址：http://${SERVER_IP:-服务器IP}:${IOTA_DASH_PORT}/"
echo "用户名：${IOTA_DASH_USER}"
echo "密码：${IOTA_DASH_PASSWORD}"
echo "========================================"
