#!/usr/bin/env python3
"""
AgentIsland Hook
- Sends session state to AgentIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app
- `AskUserQuestion` 另带 `ask` 负载，刘海答完由本脚本映射回 `updatedInput.answers`

四层等待预算（必须严格递减，见 HookSocketServer.pendingTTL 的不变量）：
应用 pending TTL 330s > 普通审批 300s > 本脚本 ask 分支 240s > 闸门客户端 120s
"""
import json
import os
import socket
import sys

# 验证用钩子：探针可以把 socket 与预算指到别处，默认值与线上一致。
SOCKET_PATH = os.environ.get("AGENT_ISLAND_SOCKET") or "/tmp/agent-island.sock"
# 普通审批（bash / edit 等）的等待上限：与改造前逐字一致。
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
# `AskUserQuestion` 的等待上限：与 omp/pi 侧的 ask 预算（AGENT_ISLAND_ASK_TIMEOUT_MS
# 缺省 240s）取同值。取 240s 而不是 300s 的理由同 omp 侧——必须严格小于应用侧的
# pending TTL（330s）与上一档（300s），否则「谁先到点」不可判定、失败理由不可读。
ASK_TIMEOUT_SECONDS = float(os.environ.get("AGENT_ISLAND_ASK_TIMEOUT_SECONDS") or 240)
# Claude 的交互式提问工具名（其 `tool_input.questions[]` 由本脚本归一成 ask 负载）。
ASK_TOOL_NAME = "AskUserQuestion"


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def send_event(state, timeout=None):
    """Send event to app, return response if any

    ``timeout`` 为本次等待的上限（秒）；缺省用普通审批的 300s。
    """
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS if timeout is None else timeout)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def build_ask_payload(tool_input):
    """把 `AskUserQuestion` 的 `tool_input.questions[]` 归一成应用侧的 `ask` 负载。

    Claude 的问题形状（2.1.263 二进制内的 zod schema）：
    ``{question, header, options:[{label, description, preview?}], multiSelect}``，
    扩展宿主还会带 ``kind``（choice/text/number）、``description``、``placeholder``、
    ``min``/``max``/``step``/``defaultValue``/``unit``——没有 ``id`` 字段。

    因此 `id` 用**问题正文**：Claude 自己的答案键就是问题正文
    （``outputSchema.answers = "question text -> answer string"``，工具结果的
    ``mapToolResultToToolResultBlockParam`` 也是按 ``answers[question.question]`` 取），
    且输入 schema 的 refine 硬性要求同一调用内问题正文唯一
    （"Question texts must be unique, ..."），因此它天然是稳定且唯一的 id，
    回传时不需要再做 id → 正文的映射，也就不会出现两者对不上的情况。

    自由文本一律置真：Claude 的原生弹窗对任何问题都提供自定义输入（"Other"），
    刘海要能表达同一件事；`kind` 为 text/number 的问题没有选项，更是只能靠它作答。
    认不出形状时返回 None，调用方退回今天的 allow/deny 行为。
    """
    if not isinstance(tool_input, dict):
        return None
    questions = tool_input.get("questions")
    if not isinstance(questions, list):
        return None

    items = []
    for question in questions:
        if not isinstance(question, dict):
            continue
        text = question.get("question")
        if not isinstance(text, str) or text.strip() == "":
            continue

        item = {
            "id": text,
            "question": text,
            "multi_select": question.get("multiSelect") is True,
            "free_text": True,
        }
        header = question.get("header")
        if isinstance(header, str) and header.strip() != "":
            item["header"] = header

        options = question.get("options")
        if isinstance(options, list):
            normalized = []
            for option in options:
                if not isinstance(option, dict):
                    continue
                label = option.get("label")
                if not isinstance(label, str) or label == "":
                    continue
                entry = {"label": label}
                description = option.get("description")
                if isinstance(description, str) and description.strip() != "":
                    entry["description"] = description
                normalized.append(entry)
            if normalized:
                item["options"] = normalized

        items.append(item)

    if not items:
        return None
    return {"questions": items}


def join_answer(labels):
    """把多选答案编码成 Claude 接受的形式：逗号连接，含 ", " 或引号的项加 JSON 引号。

    与 Claude 自身对话框的编码逐字一致（``labels.map(l => l.includes(", ") ||
    l.includes('"') ? JSON.stringify(l) : l).join(", ")``）；解析侧
    （``f2n``）按 ", " 切分、对 ``"`` 开头的段做 JSON.parse，因此这是唯一的规范形态。
    """
    parts = []
    for label in labels:
        if ", " in label or '"' in label:
            parts.append(json.dumps(label, ensure_ascii=False))
        else:
            parts.append(label)
    return ", ".join(parts)


def build_updated_input(tool_input, answers):
    """把应用侧的 `answers`（问题正文 → 选中的 label 列表）映射成 Claude 的 `updatedInput`。

    `questions` 必须**原样**带上：Claude 的 ``mapToolResultToToolResultBlockParam``
    直接对它调 ``.map()``，缺这个键会抛 "undefined is not an object"。
    映射不出任何答案时返回 None（调用方回落原生弹窗，而不是发一份空答案）。
    """
    if not isinstance(tool_input, dict) or not isinstance(answers, dict):
        return None
    questions = tool_input.get("questions")
    if not isinstance(questions, list):
        return None

    mapped = {}
    for question in questions:
        if not isinstance(question, dict):
            continue
        text = question.get("question")
        if not isinstance(text, str):
            continue
        values = answers.get(text)
        if isinstance(values, list):
            labels = [value for value in values if isinstance(value, str) and value != ""]
            if labels:
                mapped[text] = join_answer(labels)
        elif isinstance(values, str) and values != "":
            mapped[text] = values

    if not mapped:
        return None
    updated = dict(tool_input)
    updated["questions"] = questions
    updated["answers"] = mapped
    return updated


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # `AskUserQuestion`：把问题一并发出，刘海可以就地作答。旧版应用不认识
        # `ask` 字段会忽略它、只回 allow/deny，因此不需要版本协商。
        ask_payload = None
        if data.get("tool_name") == ASK_TOOL_NAME:
            ask_payload = build_ask_payload(tool_input)
            if ask_payload:
                state["ask"] = ask_payload

        # Send to app and wait for decision（ask 分支用更短的预算，见常量处的不变量）
        response = send_event(state, ASK_TIMEOUT_SECONDS if ask_payload else None)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via AgentIsland",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "answer" and ask_payload:
                # 刘海答完：把「问题正文 → 答案字符串」映射回 Claude 的 updatedInput，
                # 走 PermissionRequest 的 allow 通道直接满足这次交互（不再弹原生提问）。
                # `updatedInput` 里必须原样带上 questions（缺它会崩，见 build_updated_input）。
                updated_input = build_updated_input(tool_input, response.get("answers"))
                if updated_input:
                    output = {
                        "hookSpecificOutput": {
                            "hookEventName": "PermissionRequest",
                            "decision": {
                                "behavior": "allow",
                                "updatedInput": updated_input,
                            },
                        }
                    }
                    print(json.dumps(output))
                # 映射不出答案（畸形负载 / 问题正文对不上）：不输出，回落原生弹窗
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # Turn ended via API error (rate limit, auth, billing). Mark waiting
        # so the user sees it's done (not stuck), with the error surfaced
        state["status"] = "waiting_for_input"
        state["stop_error"] = data.get("error") or data.get("message")

    elif event == "SubagentStart":
        # A subagent task is beginning — main session is still processing
        state["status"] = "processing"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - main session continues processing
        state["status"] = "processing"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        # Compaction finished — return to processing so UI exits .compacting phase
        state["status"] = "processing"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
