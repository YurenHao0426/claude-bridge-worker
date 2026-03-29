#!/bin/bash
# MCP server 启动 wrapper：检测 tmux session name 并传给 python
# 用进程树反查 pane PID → session name

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 检测 session name: 遍历 PID 往上找
detect_session() {
    local check_pid=$$
    local pane_pids
    pane_pids=$(tmux list-panes -a -F "#{pane_pid} #{session_name}" 2>/dev/null) || return

    for i in $(seq 1 50); do
        local match
        match=$(echo "$pane_pids" | grep "^${check_pid} " | head -1 | cut -d' ' -f2)
        if [ -n "$match" ]; then
            echo "$match"
            return
        fi
        # 获取 PPID
        local ppid
        ppid=$(awk '{print $4}' /proc/${check_pid}/stat 2>/dev/null) || return
        [ "$ppid" -le 1 ] && return
        check_pid=$ppid
    done
}

export CLAUDE_SESSION_NAME=$(detect_session)
exec python3 "$SCRIPT_DIR/mcp_lab_worker.py"
