"""
Claude Bridge - Lab Worker MCP Server
实验室端 MCP 工具，供实验室 Claude Code 使用
"""

import os
import subprocess

import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("lab-worker")

BROKER_URL = os.environ["BROKER_URL"]  # 私人服务器公网地址
API_SECRET = os.environ["API_SECRET"]

HEADERS = {"Authorization": f"Bearer {API_SECRET}"}

# 启动时就确定 session name，不每次重新检测
_SESSION_NAME = ""

def _detect_session_name() -> str:
    """检测当前进程所在的 tmux session 名"""
    # 方法 1: 环境变量（最可靠，需要在 tmux session 里设置）
    name = os.environ.get("CLAUDE_SESSION_NAME", "")
    if name:
        return name

    # 方法 2: 进程树 PID 匹配 tmux pane
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_pid} #{session_name}"],
            capture_output=True, timeout=3, text=True,
        )
        if result.returncode != 0:
            return ""
        pane_map = {}
        for line in result.stdout.strip().split("\n"):
            parts = line.split(" ", 1)
            if len(parts) == 2:
                pane_map[parts[0]] = parts[1]

        check_pid = os.getpid()
        for _ in range(50):
            if str(check_pid) in pane_map:
                return pane_map[str(check_pid)]
            try:
                with open(f"/proc/{check_pid}/stat") as f:
                    stat = f.read()
                ppid = int(stat.split(")")[1].split()[1])
                if ppid <= 1:
                    break
                check_pid = ppid
            except Exception:
                break
    except Exception:
        pass
    return ""

# 启动时检测一次
_SESSION_NAME = _detect_session_name()
if _SESSION_NAME:
    print(f"[lab-worker] Detected session: {_SESSION_NAME}", flush=True)
else:
    print("[lab-worker] WARNING: Could not detect tmux session name!", flush=True)


def _get_session_name() -> str:
    return _SESSION_NAME


@mcp.tool()
async def fetch_pending_tasks() -> str:
    """从调度服务器获取属于当前 session 的待执行任务列表。"""
    session = _get_session_name()
    if not session:
        return "错误：无法检测 tmux session 名，拒绝获取任务（防止跨 session 抢任务）。"
    params = {"target": session}
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{BROKER_URL}/tasks/pending", headers=HEADERS, params=params, timeout=15)
        resp.raise_for_status()
        data = resp.json()

    tasks = data.get("tasks", [])
    if not tasks:
        return "当前没有待执行的任务。"

    lines = []
    for t in tasks:
        lines.append(f"任务 [{t['id']}]: {t['content']}")
    return "\n---\n".join(lines)


@mcp.tool()
async def claim_task(task_id: str) -> str:
    """领取一个任务，标记为正在执行。必须在开始执行前调用。"""
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{BROKER_URL}/tasks/{task_id}/claim", headers=HEADERS, timeout=10
        )
    if resp.status_code == 200:
        return f"已领取任务 {task_id}，开始执行。"
    return f"领取失败: {resp.text}"


@mcp.tool()
async def report_result(task_id: str, result: str) -> str:
    """提交任务执行结果。result 应包含详细的执行结果和关键输出。"""
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{BROKER_URL}/tasks/{task_id}/result",
            headers=HEADERS,
            json={"result": result},
            timeout=15,
        )
    if resp.status_code == 200:
        return f"任务 {task_id} 结果已提交。"
    return f"提交失败: {resp.text}"


@mcp.tool()
async def report_failure(task_id: str, reason: str) -> str:
    """报告任务执行失败。reason 应包含错误信息和失败原因。"""
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{BROKER_URL}/tasks/{task_id}/fail",
            headers=HEADERS,
            json={"result": reason},
            timeout=15,
        )
    if resp.status_code == 200:
        return f"已报告任务 {task_id} 失败。"
    return f"报告失败: {resp.text}"


@mcp.tool()
async def reply_to_dispatcher(message: str) -> str:
    """回传消息给调度中心。用于回复 btw 询问、汇报进度、回答问题等。"""
    session = _get_session_name() or "unknown"
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{BROKER_URL}/log",
            headers=HEADERS,
            json={"source": session, "message": message},
            timeout=10,
        )
    if resp.status_code == 200:
        return "已回传给调度中心。"
    return f"回传失败: {resp.text}"


@mcp.tool()
async def upload_file_to_broker(file_path: str) -> str:
    """把实验室本地文件上传到 broker 文件存储，供 dispatcher 下载或发给用户。
    file_path: 实验室服务器上的本地文件绝对路径。
    """
    if not os.path.exists(file_path):
        return f"文件不存在: {file_path}"
    filename = os.path.basename(file_path)
    async with httpx.AsyncClient(timeout=120) as client:
        with open(file_path, "rb") as f:
            resp = await client.post(
                f"{BROKER_URL}/files/upload",
                headers=HEADERS,
                files={"file": (filename, f)},
                data={"filename": filename},
            )
            resp.raise_for_status()
            data = resp.json()
    return f"已上传: {data['filename']} ({data['size']} bytes)"


@mcp.tool()
async def download_file_from_broker(filename: str, save_path: str = "") -> str:
    """从 broker 文件存储下载文件到实验室本地。
    filename: broker 上的文件名。
    save_path: 保存路径。留空则保存到当前工作目录。
    """
    if not save_path:
        save_path = os.path.join(os.getcwd(), filename)
    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.get(
            f"{BROKER_URL}/files/{filename}",
            headers=HEADERS,
        )
        resp.raise_for_status()
        with open(save_path, "wb") as f:
            f.write(resp.content)
    return f"已下载到: {save_path} ({len(resp.content)} bytes)"


@mcp.tool()
async def check_context_usage() -> str:
    """查看当前 session 的 context 使用情况（通过 /context 命令）。"""
    import time, re

    session = _get_session_name()
    if not session:
        return "无法检测 session 名"

    try:
        subprocess.run(["tmux", "send-keys", "-t", session, "/context", "Enter"], timeout=3)
        time.sleep(3)
        output = subprocess.check_output(
            ["tmux", "capture-pane", "-t", session, "-p", "-S", "-50"],
            timeout=3
        ).decode()

        info = []
        for line in output.split("\n"):
            m = re.search(r'(\d+k)/(\d+k)', line)
            if m:
                info.append(f"Total: {m.group(1)}/{m.group(2)}")
            for keyword in ["Messages:", "Free space:", "Autocompact"]:
                if keyword in line:
                    m2 = re.search(r'([\d.]+k?\s*tokens?\s*\([\d.]+%\))', line)
                    if m2:
                        info.append(f"{keyword} {m2.group(1)}")

        if info:
            return f"[{session}] Context:\n" + "\n".join(info)
        else:
            return f"[{session}] 解析失败"
    except Exception as e:
        return f"错误: {e}"


if __name__ == "__main__":
    mcp.run(transport="stdio")
