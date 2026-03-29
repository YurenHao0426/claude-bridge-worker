#!/bin/bash
# Claude Bridge Worker - 一键部署脚本
# 用法: bash setup.sh --broker-url URL --api-secret SECRET --session NAME [--project-dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === 解析参数 ===
BROKER_URL=""
API_SECRET=""
SESSION_NAME=""
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --broker-url) BROKER_URL="$2"; shift 2 ;;
        --api-secret) API_SECRET="$2"; shift 2 ;;
        --session) SESSION_NAME="$2"; shift 2 ;;
        --project-dir) PROJECT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$BROKER_URL" ] || [ -z "$API_SECRET" ] || [ -z "$SESSION_NAME" ]; then
    echo "用法: bash setup.sh --broker-url URL --api-secret SECRET --session NAME [--project-dir DIR]"
    echo ""
    echo "  --broker-url   中转服务器地址 (如 http://131.153.232.145:8000)"
    echo "  --api-secret   API 认证密钥"
    echo "  --session      tmux session 名 (如 claude, claude2, worker1)"
    echo "  --project-dir  工作目录 (可选，默认 ~/)"
    exit 1
fi

PROJECT_DIR="${PROJECT_DIR:-$HOME}"
BRIDGE_DIR="$HOME/claude-bridge"

echo "=== Claude Bridge Worker Setup ==="
echo "Broker:  $BROKER_URL"
echo "Session: $SESSION_NAME"
echo "Project: $PROJECT_DIR"
echo ""

# === 1. 安装文件 ===
echo "[1/7] 安装 bridge 文件..."
mkdir -p "$BRIDGE_DIR"
cp "$SCRIPT_DIR"/mcp_lab_worker.py "$BRIDGE_DIR/"
cp "$SCRIPT_DIR"/start_mcp.sh "$BRIDGE_DIR/"
cp "$SCRIPT_DIR"/check_tasks.py "$BRIDGE_DIR/"
cp "$SCRIPT_DIR"/poll_and_notify.sh "$BRIDGE_DIR/"
cp "$SCRIPT_DIR"/execute_commands.sh "$BRIDGE_DIR/"
cp "$SCRIPT_DIR"/cron_runner.sh "$BRIDGE_DIR/"
cp "$SCRIPT_DIR"/CLAUDE.md "$BRIDGE_DIR/"
chmod +x "$BRIDGE_DIR"/*.sh "$BRIDGE_DIR"/check_tasks.py

# 写 .env
cat > "$BRIDGE_DIR/.env" << EOF
BROKER_URL=$BROKER_URL
API_SECRET=$API_SECRET
EOF

echo "  文件已安装到 $BRIDGE_DIR"

# === 2. 安装 Python 依赖 ===
echo "[2/7] 安装 Python 依赖..."
pip install httpx "mcp[cli]" 2>&1 | tail -1 || echo "  ⚠️ pip 安装失败，请手动安装: pip install httpx 'mcp[cli]'"

# === 3. 注册 MCP server ===
echo "[3/7] 注册 MCP server..."
# 先删除旧的（如果有）
claude mcp remove lab-worker -s user 2>/dev/null || true
claude mcp add --scope user lab-worker \
    -e "API_SECRET=$API_SECRET" \
    -e "BROKER_URL=$BROKER_URL" \
    -- bash "$BRIDGE_DIR/start_mcp.sh"
echo "  MCP server 已注册"

# === 4. 配置 hooks ===
echo "[4/7] 配置 hooks..."
HOOK_CMD="BROKER_URL=$BROKER_URL API_SECRET=$API_SECRET bash $BRIDGE_DIR/check_tasks.py"

python3 << PYEOF
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(settings_path) as f:
        s = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    s = {}

# 确保 permissions 存在
if "permissions" not in s:
    s["permissions"] = {"allow": []}
perms = s["permissions"].get("allow", [])

# 加 MCP tool 权限
for tool in [
    "mcp__lab-worker__fetch_pending_tasks",
    "mcp__lab-worker__claim_task",
    "mcp__lab-worker__report_result",
    "mcp__lab-worker__report_failure",
    "mcp__lab-worker__reply_to_dispatcher",
    "mcp__lab-worker__upload_file_to_broker",
    "mcp__lab-worker__download_file_from_broker",
    "mcp__lab-worker__check_context_usage",
]:
    if tool not in perms:
        perms.append(tool)
s["permissions"]["allow"] = perms

# 配置 hooks
hook_cmd = "BROKER_URL=$BROKER_URL API_SECRET=$API_SECRET SESSION_NAME=\$(tmux display-message -p '#S' 2>/dev/null || echo unknown) python3 $BRIDGE_DIR/check_tasks.py"
s["hooks"] = {
    "Stop": [{"hooks": [{"type": "command", "command": hook_cmd, "timeout": 15}]}],
    "PostToolUse": [{"matcher": "Bash|Edit|Write|Read", "hooks": [{"type": "command", "command": hook_cmd, "timeout": 15}]}],
}

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
print("  hooks 和权限已配置")
PYEOF

# === 5. 配置 cron ===
echo "[5/7] 配置 cron..."

# cron_runner.sh 已在 package 中，只需设置环境变量
export CLAUDE_BRIDGE_DIR="$BRIDGE_DIR"

# 添加 cron（去重）
CRON_CMD="CLAUDE_BRIDGE_DIR=$BRIDGE_DIR $BRIDGE_DIR/cron_runner.sh"
(crontab -l 2>/dev/null | grep -v claude-bridge; echo "* * * * * $CRON_CMD") | crontab -
echo "  cron 已配置 (每15秒轮询 + 自动重启)"

# === 6. 部署 CLAUDE.md ===
echo "[6/7] 部署 CLAUDE.md..."
# 全局位置：直接覆盖（这里不会有项目描述）
mkdir -p "$HOME/.claude"
cp "$BRIDGE_DIR/CLAUDE.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null || true

# 项目目录：如果已有 CLAUDE.md 则追加，不覆盖
if [ -d "$PROJECT_DIR" ] && [ "$PROJECT_DIR" != "$HOME" ]; then
    if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
        # 检查是否已经包含 bridge 内容
        if ! grep -q "Claude Bridge" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
            echo "" >> "$PROJECT_DIR/CLAUDE.md"
            echo "---" >> "$PROJECT_DIR/CLAUDE.md"
            echo "" >> "$PROJECT_DIR/CLAUDE.md"
            cat "$BRIDGE_DIR/CLAUDE.md" >> "$PROJECT_DIR/CLAUDE.md"
            echo "  已追加 bridge 指令到 $PROJECT_DIR/CLAUDE.md"
        else
            echo "  $PROJECT_DIR/CLAUDE.md 已包含 bridge 指令，跳过"
        fi
    else
        cp "$BRIDGE_DIR/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
        echo "  已创建 $PROJECT_DIR/CLAUDE.md"
    fi
fi
echo "  全局 CLAUDE.md 已部署到 ~/.claude/"

# === 7. 启动 tmux session + Claude Code ===
echo "[7/7] 启动 worker..."
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "  tmux session '$SESSION_NAME' 已存在，跳过创建"
else
    tmux new-session -d -s "$SESSION_NAME"
    if [ "$PROJECT_DIR" != "$HOME" ]; then
        tmux send-keys -t "$SESSION_NAME" "cd $PROJECT_DIR" Enter
        sleep 1
    fi
    tmux send-keys -t "$SESSION_NAME" "claude --continue" Enter
    echo "  tmux session '$SESSION_NAME' 已创建并启动 Claude Code"
fi

# 记录 session 信息（供 cron 健康检查 + 自动重启用）
SESSIONS_FILE="$BRIDGE_DIR/.sessions"
# 去重后追加
grep -v "^${SESSION_NAME}$(printf '\t')" "$SESSIONS_FILE" 2>/dev/null > "${SESSIONS_FILE}.tmp" || true
echo -e "${SESSION_NAME}\t${PROJECT_DIR}" >> "${SESSIONS_FILE}.tmp"
mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
echo "  session 已注册到 $SESSIONS_FILE"

# === 8. 向 broker 注册 ===
echo ""
echo "向 broker 注册新 worker..."
HOSTNAME=$(hostname)
curl -sf -X POST \
    -H "Authorization: Bearer $API_SECRET" \
    -H "Content-Type: application/json" \
    -d "{\"source\": \"system\", \"message\": \"新 worker 上线: session=$SESSION_NAME, host=$HOSTNAME, dir=$PROJECT_DIR\"}" \
    "$BROKER_URL/log" 2>/dev/null && echo "  已通知 dispatcher" || echo "  通知失败（broker 可能未运行）"

echo ""
echo "=== 部署完成 ==="
echo ""
echo "Worker 信息:"
echo "  Session:  $SESSION_NAME"
echo "  Project:  $PROJECT_DIR"
echo "  Bridge:   $BRIDGE_DIR"
echo "  Broker:   $BROKER_URL"
echo ""
echo "常用操作:"
echo "  tmux attach -t $SESSION_NAME     # 查看 worker"
echo "  tmux send-keys -t $SESSION_NAME /exit Enter  # 停止 worker"
echo "  bash $SCRIPT_DIR/setup.sh ...    # 重新部署"
