#!/usr/bin/env python3
"""
Claude Bridge - Lab Hook Script
支持两种 hook 事件:
  - Stop:        干完活检查新任务，有 task 就阻止停止
  - PostToolUse: 工作中检查，message 注入 context 不打断

任务类型:
  - task:    需要领取执行（Stop 时阻塞）
  - message: 只注入 context（btw 模式，不打断）
"""

import json
import os
import sys
import urllib.request

BROKER_URL = os.environ.get("BROKER_URL", "")
API_SECRET = os.environ.get("API_SECRET", "")
SESSION_NAME = os.environ.get("SESSION_NAME", "")

if not BROKER_URL or not API_SECRET or not SESSION_NAME:
    sys.exit(1)

try:
    hook_input = json.loads(sys.stdin.read())
except Exception:
    hook_input = {}

event = hook_input.get("hook_event_name", "Stop")

if event == "Stop" and hook_input.get("stop_hook_active", False):
    sys.exit(0)


def consume_task(task_id):
    """Claim + mark done (for messages that just need to be seen)"""
    try:
        req = urllib.request.Request(
            f"{BROKER_URL}/tasks/{task_id}/claim",
            method="POST",
            headers={"Authorization": f"Bearer {API_SECRET}"},
        )
        urllib.request.urlopen(req, timeout=5)
        req2 = urllib.request.Request(
            f"{BROKER_URL}/tasks/{task_id}/result",
            data=json.dumps({"result": "seen"}).encode(),
            headers={
                "Authorization": f"Bearer {API_SECRET}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        urllib.request.urlopen(req2, timeout=5)
    except Exception:
        pass


# 发心跳（静默，失败不影响主流程）
try:
    import socket
    hb_data = json.dumps({"session": SESSION_NAME, "host": socket.gethostname()}).encode()
    hb_req = urllib.request.Request(
        f"{BROKER_URL}/heartbeat",
        data=hb_data,
        headers={"Authorization": f"Bearer {API_SECRET}", "Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(hb_req, timeout=3)
except Exception:
    pass

try:
    req = urllib.request.Request(
        f"{BROKER_URL}/tasks/pending?target={SESSION_NAME}",
        headers={"Authorization": f"Bearer {API_SECRET}"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())

    items = data.get("tasks", [])
    if not items:
        sys.exit(0)

    tasks = [i for i in items if i.get("type", "task") == "task"]
    messages = [i for i in items if i.get("type") == "message"]

    output_lines = []

    # Hook 被触发了 = Claude 在活跃状态，可以消费 messages
    for m in messages:
        output_lines.append(f"[Bridge btw — reply with reply_to_dispatcher] {m['content']}")
        consume_task(m["id"])

    if event == "Stop" and tasks:
        task_list = "\n".join(
            [f"  - [{t['id']}] {t['content'][:120]}" for t in tasks]
        )
        if output_lines:
            output_lines.append("")
        output_lines.append(f"{len(tasks)} new task(s) pending:")
        output_lines.append(task_list)
        output_lines.append("")
        output_lines.append("Use fetch_pending_tasks to view details, then claim_task to claim and execute.")
        output = {
            "decision": "block",
            "reason": "\n".join(output_lines),
        }
        print(json.dumps(output))
    elif event == "PostToolUse" and tasks:
        task_list = "\n".join(
            [f"  - [{t['id']}] {t['content'][:120]}" for t in tasks]
        )
        output_lines.append(
            f"\n[Bridge] {len(tasks)} new task(s) pending. Handle after current work:\n{task_list}"
        )
        print("\n".join(output_lines))
    elif output_lines:
        print("\n".join(output_lines))

    sys.exit(0)

except Exception as e:
    print(f"check_tasks error: {e}", file=sys.stderr)
    sys.exit(1)
