#!/bin/bash
# 轮询 broker 命令队列，执行系统级命令（切换项目、重启等）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi
export BROKER_URL API_SECRET

AUTH="Authorization: Bearer $API_SECRET"
CLAUDE_MD_SRC="$SCRIPT_DIR/CLAUDE.md"

# 拉取待执行命令
DATA=$(curl -sf -H "$AUTH" "$BROKER_URL/commands/pending" 2>/dev/null) || exit 0

echo "$DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for cmd in d.get('commands', []):
    params = json.loads(cmd['params']) if isinstance(cmd['params'], str) else cmd['params']
    print(cmd['id'] + '\t' + cmd['target'] + '\t' + cmd['action'] + '\t' + json.dumps(params))
" 2>/dev/null | while IFS=$'\t' read -r CMD_ID TARGET ACTION PARAMS; do

    echo "$(date): Executing command $CMD_ID: $ACTION on $TARGET"

    # 检查 tmux session 存在
    if ! tmux has-session -t "$TARGET" 2>/dev/null; then
        curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
            -d "{\"result\": \"ERROR: tmux session $TARGET not found\"}" \
            "$BROKER_URL/commands/$CMD_ID/done" >/dev/null 2>&1
        continue
    fi

    case "$ACTION" in
        switch_project)
            DIR=$(echo "$PARAMS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('directory',''))")
            if [ -z "$DIR" ]; then
                curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
                    -d '{"result": "ERROR: no directory specified"}' \
                    "$BROKER_URL/commands/$CMD_ID/done" >/dev/null 2>&1
                continue
            fi

            # 创建目录（如果不存在）
            mkdir -p "$DIR"

            # 复制 CLAUDE.md
            cp "$CLAUDE_MD_SRC" "$DIR/CLAUDE.md" 2>/dev/null || true

            # /exit 当前 claude
            tmux send-keys -t "$TARGET" "/exit" Enter
            sleep 5

            # cd 到新目录
            tmux send-keys -t "$TARGET" "cd $DIR" Enter
            sleep 1

            # 启动 claude --continue
            tmux send-keys -t "$TARGET" "claude --continue" Enter
            sleep 3

            RESULT="OK: $TARGET switched to $DIR"
            ;;

        restart)
            # /exit 当前 claude
            tmux send-keys -t "$TARGET" "/exit" Enter
            sleep 5

            # claude --continue（在同一目录）
            tmux send-keys -t "$TARGET" "claude --continue" Enter
            sleep 3

            RESULT="OK: $TARGET restarted"
            ;;

        *)
            RESULT="ERROR: unknown action $ACTION"
            ;;
    esac

    # 汇报完成
    python3 -c "
import json, urllib.request
req = urllib.request.Request(
    '$BROKER_URL/commands/$CMD_ID/done',
    data=json.dumps({'result': '$RESULT'}).encode(),
    headers={'Authorization': 'Bearer $API_SECRET', 'Content-Type': 'application/json'},
    method='POST',
)
urllib.request.urlopen(req, timeout=10)
" 2>/dev/null || true

    echo "$(date): Command $CMD_ID done: $RESULT"
done
