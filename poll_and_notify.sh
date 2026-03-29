#!/bin/bash
# 极简 cron：只负责唤醒闲置的 Claude session
# 有 pending 任务就发一个 "check"，hook 会处理剩下的一切
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi
export BROKER_URL API_SECRET

for SESSION in claude claude2 claude3; do
    tmux has-session -t "$SESSION" 2>/dev/null || continue

    # 问 broker 这个 session 有没有 pending 任务
    COUNT=$(curl -sf -H "Authorization: Bearer $API_SECRET" \
        "$BROKER_URL/tasks/pending?target=$SESSION" 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('tasks',[])))" 2>/dev/null \
        || echo "0")

    if [ "$COUNT" -gt 0 ]; then
        # 只发一个简短提示，不带任何 content
        tmux send-keys -t "$SESSION" "请检查新任务" Enter
        echo "$(date): poked $SESSION ($COUNT pending)"
    fi
done
