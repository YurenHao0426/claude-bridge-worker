#!/bin/bash
# Detect tmux session name via PID tree (not tmux display-message which returns last attached)
cd "$(dirname "$0")"
source .env 2>/dev/null

# Detect session by walking PID tree up to tmux pane
detect_session() {
    local pane_pids
    pane_pids=$(tmux list-panes -a -F "#{pane_pid} #{session_name}" 2>/dev/null) || return
    local check_pid=$$
    for i in $(seq 1 50); do
        local match
        match=$(echo "$pane_pids" | grep "^${check_pid} " | head -1 | cut -d' ' -f2)
        if [ -n "$match" ]; then
            echo "$match"
            return
        fi
        local ppid
        ppid=$(awk '{print $4}' /proc/${check_pid}/stat 2>/dev/null) || return
        [ "$ppid" -le 1 ] && return
        check_pid=$ppid
    done
}

export SESSION_NAME=$(detect_session)
if [ -z "$SESSION_NAME" ]; then
    export SESSION_NAME="unknown"
fi
exec python3 /home/yurenh2/claude-bridge/check_tasks.py
