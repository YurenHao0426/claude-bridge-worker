#!/bin/bash
# 一键重启所有 worker session + poller
set -euo pipefail

BRIDGE_DIR="${CLAUDE_BRIDGE_DIR:-$HOME/claude-bridge}"
SESSIONS_FILE="$BRIDGE_DIR/.sessions"

cd "$BRIDGE_DIR"
source .env 2>/dev/null
export BROKER_URL API_SECRET

# 重启所有 session
if [ -f "$SESSIONS_FILE" ]; then
    while IFS=$'\t' read -r SESSION PROJECT_DIR; do
        [ -z "$SESSION" ] && continue
        if tmux has-session -t "$SESSION" 2>/dev/null; then
            echo "$SESSION 已在运行，跳过"
        else
            tmux new-session -d -s "$SESSION"
            if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
                tmux send-keys -t "$SESSION" "cd $PROJECT_DIR" Enter
                sleep 1
            fi
            tmux send-keys -t "$SESSION" "claude --continue" Enter
            echo "$SESSION 已启动 (项目: $PROJECT_DIR)"
        fi
    done < "$SESSIONS_FILE"
else
    echo "没有 .sessions 文件，跳过 session 创建"
fi

# 杀掉旧 poller，启动新的
pkill -f "poll_and_notify.sh" 2>/dev/null || true
pkill -f "execute_commands.sh" 2>/dev/null || true
sleep 1
nohup bash -c "while true; do bash $BRIDGE_DIR/poll_and_notify.sh >> /tmp/claude-bridge.log 2>&1; bash $BRIDGE_DIR/execute_commands.sh >> /tmp/claude-bridge-cmd.log 2>&1; sleep 15; done" &
echo "poller 已启动 (PID: $!)"

echo "完成。"
