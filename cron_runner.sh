#!/bin/bash
# Claude Bridge Worker - Cron Runner
# 由 setup.sh 生成实际路径，这里用占位符
# 功能: 1) 健康检查+自动重启 2) 任务通知 3) 命令执行

export PATH="$HOME/miniconda3/bin:$HOME/.local/bin:/usr/bin:/bin:$PATH"

BRIDGE_DIR="${CLAUDE_BRIDGE_DIR:-$HOME/claude-bridge}"
cd "$BRIDGE_DIR" || exit 1
source .env 2>/dev/null
export BROKER_URL API_SECRET

AUTH="Authorization: Bearer $API_SECRET"
SESSIONS_FILE="$BRIDGE_DIR/.sessions"  # 每行: session_name project_dir

# === 健康检查 + 自动重启 ===
if [ -f "$SESSIONS_FILE" ]; then
    while IFS=$'\t' read -r SESSION_NAME PROJECT_DIR; do
        [ -z "$SESSION_NAME" ] && continue

        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "$(date): Session $SESSION_NAME 不存在，重新创建..."

            # 重建 tmux session
            tmux new-session -d -s "$SESSION_NAME"
            if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
                tmux send-keys -t "$SESSION_NAME" "cd $PROJECT_DIR" Enter
                sleep 1
            fi
            tmux send-keys -t "$SESSION_NAME" "claude --continue" Enter

            # 通知 manager
            curl -sf -X POST \
                -H "$AUTH" \
                -H "Content-Type: application/json" \
                -d "{\"source\": \"system\", \"message\": \"Worker $SESSION_NAME ($(hostname)) 被系统杀掉后已自动重启，工作目录: ${PROJECT_DIR:-$HOME}\"}" \
                "$BROKER_URL/log" 2>/dev/null || true

            echo "$(date): Session $SESSION_NAME 已重启并通知 manager"
        fi
    done < "$SESSIONS_FILE"
fi

# === 任务通知 + 命令执行 (每15秒一轮，共4轮) ===
for i in 0 1 2 3; do
    bash "$BRIDGE_DIR/poll_and_notify.sh" >> /tmp/claude-bridge.log 2>&1
    bash "$BRIDGE_DIR/execute_commands.sh" >> /tmp/claude-bridge-cmd.log 2>&1
    [ $i -lt 3 ] && sleep 15
done
