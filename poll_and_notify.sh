#!/bin/bash
# Poller: wake idle sessions, deliver messages, notify tasks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi
export BROKER_URL API_SECRET

python3 << 'PYEOF'
import json, os, time, subprocess, urllib.request

BROKER_URL = os.environ.get("BROKER_URL", "")
API_SECRET = os.environ.get("API_SECRET", "")
SESSIONS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)) if '__file__' in dir() else os.getcwd(), ".sessions")

if not BROKER_URL or not API_SECRET:
    exit(0)

def api_get(path):
    req = urllib.request.Request(f"{BROKER_URL}{path}", headers={"Authorization": f"Bearer {API_SECRET}"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())

def api_post(path, data=None):
    body = json.dumps(data).encode() if data else b""
    req = urllib.request.Request(f"{BROKER_URL}{path}", data=body, headers={"Authorization": f"Bearer {API_SECRET}", "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())

def tmux_send(session, text):
    subprocess.run(["tmux", "send-keys", "-t", session, text, "Enter"], timeout=5, capture_output=True)

def tmux_exists(session):
    return subprocess.run(["tmux", "has-session", "-t", session], capture_output=True).returncode == 0

# Read sessions
try:
    with open(SESSIONS_FILE) as f:
        sessions = []
        for line in f:
            parts = line.strip().split("\t")
            if parts and parts[0]:
                sessions.append(parts[0])
except FileNotFoundError:
    exit(0)

import socket
hostname = socket.gethostname()

for session in sessions:
    if not tmux_exists(session):
        continue

    # Heartbeat
    try:
        api_post("/heartbeat", {"session": session, "host": hostname})
    except Exception:
        pass

    # Get pending items
    try:
        data = api_get(f"/tasks/pending?target={session}")
    except Exception:
        continue

    items = data.get("tasks", [])
    if not items:
        continue

    tasks = [i for i in items if i.get("type", "task") == "task"]
    messages = [i for i in items if i.get("type") == "message"]

    # Messages: claim + send content directly
    for m in messages:
        try:
            api_post(f"/tasks/{m['id']}/claim")
        except Exception:
            continue  # already claimed
        content = m["content"].replace("\n", " ").replace("\r", "")
        if len(content) > 400:
            content = content[:400] + "..."
        tmux_send(session, f"[Bridge btw — reply with reply_to_dispatcher] {content}")
        try:
            api_post(f"/tasks/{m['id']}/result", {"result": "delivered via poller"})
        except Exception:
            pass
        print(f"{time.strftime('%c')}: [{session}] message {m['id']} delivered")

    # Tasks: just poke
    if tasks:
        tmux_send(session, "请检查新任务")
        print(f"{time.strftime('%c')}: [{session}] poked ({len(tasks)} task(s))")
PYEOF
