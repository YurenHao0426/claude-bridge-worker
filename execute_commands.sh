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

    # 只执行属于本机的命令（target 在 .sessions 里，或者 create_worker 的 host 匹配）
    if [ "$ACTION" = "create_worker" ]; then
        CMD_HOST=$(echo "$PARAMS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null)
        MY_HOST=$(hostname)
        if [ -n "$CMD_HOST" ] && [ "$CMD_HOST" != "$MY_HOST" ]; then
            echo "$(date): Skipping $CMD_ID - host $CMD_HOST != $MY_HOST"
            continue
        fi
    else
        if ! grep -q "^${TARGET}$(printf '\t')" "$SCRIPT_DIR/.sessions" 2>/dev/null; then
            echo "$(date): Skipping $CMD_ID - $TARGET not in local .sessions"
            continue
        fi
    fi

    # 检查 tmux session 存在
    # create_worker 不需要 session 已存在
    if [ "$ACTION" != "create_worker" ]; then
        if ! tmux has-session -t "$TARGET" 2>/dev/null; then
            curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
                -d "{\"result\": \"ERROR: tmux session $TARGET not found\"}" \
                "$BROKER_URL/commands/$CMD_ID/done" >/dev/null 2>&1
            continue
        fi
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

        create_worker)
            SESSION_NAME=$(echo "$PARAMS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_name',''))")
            DIR=$(echo "$PARAMS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path',''))")
            SLACK_CH=$(echo "$PARAMS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slack_channel',''))")
            if [ -z "$SESSION_NAME" ] || [ -z "$DIR" ]; then
                RESULT="ERROR: missing session_name or path"
            elif tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
                RESULT="OK: session $SESSION_NAME already exists"
            else
                # 用交互式脚本创建，自动处理弹窗
                RESULT=$(bash "$SCRIPT_DIR/create_worker.sh" "$SESSION_NAME" "$DIR" "$BROKER_URL" "$API_SECRET" "$SLACK_CH" 2>&1 | tail -1)
            fi
            ;;

        stop)
            tmux send-keys -t "$TARGET" "/exit" Enter
            sleep 3
            tmux kill-session -t "$TARGET" 2>/dev/null || true
            # 从 .sessions 移除
            grep -v "^${TARGET}$(printf '\t')" "$SCRIPT_DIR/.sessions" > "${SCRIPT_DIR}/.sessions.tmp" 2>/dev/null || true
            mv "${SCRIPT_DIR}/.sessions.tmp" "$SCRIPT_DIR/.sessions"
            RESULT="OK: $TARGET stopped and removed"
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
