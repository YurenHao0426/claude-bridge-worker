#!/bin/bash
# 极简 poller：唤醒闲置的 Claude session
# 从 .sessions 文件读取 session 列表（不再硬编码）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi
export BROKER_URL API_SECRET

SESSIONS_FILE="$SCRIPT_DIR/.sessions"
[ -f "$SESSIONS_FILE" ] || exit 0

while IFS=$'\t' read -r SESSION PROJECT_DIR; do
    [ -z "$SESSION" ] && continue
    tmux has-session -t "$SESSION" 2>/dev/null || continue

    COUNT=$(curl -sf -H "Authorization: Bearer $API_SECRET" \
        "$BROKER_URL/tasks/pending?target=$SESSION" 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('tasks',[])))" 2>/dev/null \
        || echo "0")

    if [ "$COUNT" -gt 0 ]; then
        tmux send-keys -t "$SESSION" "请检查新任务" Enter
        echo "$(date): poked $SESSION ($COUNT pending)"
    fi
done < "$SESSIONS_FILE"
