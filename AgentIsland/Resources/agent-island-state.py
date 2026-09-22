#!/usr/bin/env python3
"""
AgentIsland Hook（多来源）
- 把各 Agent CLI 的原生 hook 载荷归一成应用侧信封，经 Unix socket 上报
- `PermissionRequest` 类事件阻塞等待刘海决定，再按来源把决定翻译成该工具的 stdout 形状
- `AskUserQuestion` 另带 `ask` 负载，刘海答完由本脚本映射回 `updatedInput.answers`

契约：`agent-island-state.py --source <rawValue> [--event <原生事件名>]`，stdin 读一个 JSON
对象。`--source` 缺省 `claude`：已安装的老 hook 配置是 `python3 <path>`（不带任何参数），
那条路径必须与改造前逐字一致。来源取值与 `AgentKind.rawValue` 相同（claude / omp / pi /
opencode / codex / gemini / cursor / copilot / qoder / droid / codebuddy / kimi / cline /
grok / trae / traecli）；本脚本只服务「配置文件型」来源，omp/pi/opencode 走各自的扩展与插件。

归一表（原生事件名 → 应用侧事件名）拷贝自 CodeIsland 的
`Sources/CodeIslandCore/EventNormalizer.swift`，字段别名拷贝自它的
`Sources/CodeIslandBridge/main.swift`（copilot / cline / grok 适配）。

四层等待预算（必须严格递减，见 HookSocketServer.pendingTTL 的不变量）：
应用 pending TTL 330s > 普通审批 300s > 本脚本 ask 分支 240s > 闸门客户端 120s
"""
import json
import os
import socket
import sys
from urllib.parse import quote

# 验证用钩子：探针可以把 socket 与预算指到别处，默认值与线上一致。
SOCKET_PATH = os.environ.get("AGENT_ISLAND_SOCKET") or "/tmp/agent-island.sock"
# 普通审批（bash / edit 等）的等待上限：与改造前逐字一致。可用环境变量缩短，只为验证。
TIMEOUT_SECONDS = float(os.environ.get("AGENT_ISLAND_APPROVAL_TIMEOUT_SECONDS") or 300)
# `AskUserQuestion` 的等待上限：与 omp/pi 侧的 ask 预算（AGENT_ISLAND_ASK_TIMEOUT_MS
# 缺省 240s）取同值。取 240s 而不是 300s 的理由同 omp 侧——必须严格小于应用侧的
# pending TTL（330s）与上一档（300s），否则「谁先到点」不可判定、失败理由不可读。
ASK_TIMEOUT_SECONDS = float(os.environ.get("AGENT_ISLAND_ASK_TIMEOUT_SECONDS") or 240)
# Claude 的交互式提问工具名（其 `tool_input.questions[]` 由本脚本归一成 ask 负载）。
ASK_TOOL_NAME = "AskUserQuestion"

# 来源缺省值：老配置不带参数，按 Claude 处理。
DEFAULT_SOURCE = "claude"
# Claude 家族（与 `AgentKind.isClaudeFamily` 一致）：同一套 hook 契约 + `AskUserQuestion`。
CLAUDE_FAMILY = ("claude", "qoder", "droid", "codebuddy")
# Gemini CLI 的决定形状与 Claude 不同（`{"decision":"allow"}`）。
GEMINI_SOURCE = "gemini"
# Cline：hook 必须**立刻**输出 `{"cancel":false}`，转发在后台完成（不等决定）。
CLINE_SOURCE = "cline"
# Grok CLI 的会话目录基准（`$GROK_HOME`，缺省 `~/.grok`）。
GROK_SOURCE = "grok"

# 原生事件名 → 应用侧事件名。拷贝自 CodeIsland `EventNormalizer.normalize(_:)`
# （`Sources/CodeIslandCore/EventNormalizer.swift`），补上 Cline 的 Task* 四项。
# 三处 CodeIsland 自己的名字在应用侧词汇表里没有，按其语义折到最接近的事件：
#   TaskRoundComplete（Cline TaskComplete/TaskCancel）= 单轮结束 → Stop
#   AfterAgentResponse（Trae afterAgentResponse）= 助手回复完毕 → Stop
#   AgentTurnSettled（Hermes post_llm_call）= 一轮模型回复落地、不代表结束 → Notification
EVENT_ALIASES = {
    # Cursor（camelCase）
    "beforeSubmitPrompt": "UserPromptSubmit",
    "beforeShellExecution": "PreToolUse",
    "afterShellExecution": "PostToolUse",
    "beforeReadFile": "PreToolUse",
    "afterFileEdit": "PostToolUse",
    "beforeMCPExecution": "PreToolUse",
    "afterMCPExecution": "PostToolUse",
    "afterAgentThought": "Notification",
    "afterAgentResponse": "Stop",
    "stop": "Stop",
    # Gemini
    "BeforeTool": "PermissionRequest",
    "AfterTool": "PostToolUse",
    "BeforeAgent": "SubagentStart",
    "AfterAgent": "SubagentStop",
    # GitHub Copilot CLI
    "sessionStart": "SessionStart",
    "sessionEnd": "SessionEnd",
    "userPromptSubmitted": "UserPromptSubmit",
    "preToolUse": "PreToolUse",
    "postToolUse": "PostToolUse",
    "errorOccurred": "Notification",
    # Kiro CLI（camelCase，按 agent 作用域）
    "agentSpawn": "SessionStart",
    "userPromptSubmit": "UserPromptSubmit",
    # TraeCli（snake_case）
    "session_start": "SessionStart",
    "session_end": "SessionEnd",
    "user_prompt_submit": "UserPromptSubmit",
    "pre_tool_use": "PreToolUse",
    "post_tool_use": "PostToolUse",
    "post_tool_use_failure": "PostToolUseFailure",
    "permission_request": "PermissionRequest",
    "permission_denied": "PermissionDenied",
    # Grok 在一轮以 API 错误结束时发 StopFailure，两种拼写都折到 Stop（都是终态）
    "stop_failure": "Stop",
    "StopFailure": "Stop",
    "subagent_start": "SubagentStart",
    "subagent_stop": "SubagentStop",
    "pre_compact": "PreCompact",
    "post_compact": "PostCompact",
    "notification": "Notification",
    # Hermes（Nous Research）：snake_case，但与 Claude/Gemini 已经分叉
    "pre_tool_call": "PreToolUse",
    "post_tool_call": "PostToolUse",
    "pre_llm_call": "UserPromptSubmit",
    "post_llm_call": "Notification",
    "on_session_start": "SessionStart",
    "on_session_end": "SessionEnd",
    "on_session_reset": "SessionEnd",
    # Cline（VSCode 扩展）
    "TaskStart": "SessionStart",
    "TaskResume": "UserPromptSubmit",
    "TaskComplete": "Stop",
    "TaskCancel": "Stop",
}

# 原生事件名里出现这些拼写时，说明这一轮是以错误结束的（Stop 分支另带 stop_error）。
STOP_FAILURE_EVENTS = ("StopFailure", "stop_failure")


def is_grok_runtime():
    """是否处在 Grok CLI 的 hook 子进程里。

    Grok 会给它派生的每个 hook 子进程设 `GROK_SESSION_ID` / `GROK_HOOK_EVENT`；
    空白值按「没设」处理（与上游同判据）。
    """
    for key in ("GROK_SESSION_ID", "GROK_HOOK_EVENT"):
        value = os.environ.get(key)
        if isinstance(value, str) and value.strip() != "":
            return True
    return False


def is_grok_runtime_duplicate(source):
    """这条上报是否属于「Grok 导入的他人 hook」造成的重复投递。

    Grok CLI 会**导入** `~/.claude/settings.json` 与 `~/.cursor/hooks.json` 里的
    hooks，于是同一个动作会经三条通路各报一次（Grok 自己的 + 导入的 Claude + 导入的
    Cursor）。审批类事件是阻塞的，重复投递会让刘海多出一张没人能撤的待批卡，因此
    在 Grok 运行时里**只放行 `--source grok`**（`GrokHookForwardingPolicy.shouldForward`
    的同一判据：`!isGrokRuntime || source == "grok"`）。
    """
    return is_grok_runtime() and source != GROK_SOURCE


def parse_args(argv):
    """解析 `--source <rawValue> [--event <原生事件名>]`，缺省来源 `claude`。

    手写解析而不是 argparse：argparse 遇到不认识的参数会往 stderr 打用法并以 2 退出，
    而本脚本任何情况下都不能以非 0 退出（工具侧会把非 0 记成 hook 失败）。
    """
    source = DEFAULT_SOURCE
    event = None
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--source" and index + 1 < len(argv):
            source = argv[index + 1] or DEFAULT_SOURCE
            index += 2
            continue
        if arg == "--event" and index + 1 < len(argv):
            event = argv[index + 1] or None
            index += 2
            continue
        if arg.startswith("--source="):
            source = arg.split("=", 1)[1] or DEFAULT_SOURCE
        elif arg.startswith("--event="):
            event = arg.split("=", 1)[1] or None
        index += 1
    return source, event


def read_stdin():
    """读 stdin 里的一个 JSON 对象；读不到或解析失败都返回空 dict。

    改造前这里解析失败会 `exit(1)`；非 0 退出会被工具侧记成 hook 失败，因此改成空载荷。
    """
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return {}
    if not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def first_string(container, keys):
    """从映射里按顺序取第一个非空字符串；没有就返回 None。

    只要求容器有 `get`（dict 与 `os.environ` 都满足），因此环境变量兜底也能走同一个函数。
    """
    getter = getattr(container, "get", None)
    if getter is None:
        return None
    for key in keys:
        value = getter(key)
        if isinstance(value, str) and value.strip() != "":
            return value
    return None


def nested_mapping(container, key):
    """取一层嵌套对象（不是 dict 就返回空 dict）。"""
    if not isinstance(container, dict):
        return {}
    value = container.get(key)
    return value if isinstance(value, dict) else {}


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


def send_event(state, timeout=None, wait=None):
    """Send event to app, return response if any

    ``timeout`` 为本次等待的上限（秒）；缺省用普通审批的 300s。
    ``wait`` 显式指定是否等应答；缺省按状态判（与改造前逐字一致）。Cline 的后台转发传
    False：它的 hook 必须立刻返回，任何等待都违反它的契约。
    """
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS if timeout is None else timeout)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        waiting = state.get("status") == "waiting_for_approval" if wait is None else wait
        if waiting:
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def resolve_event_name(data, event_tag):
    """原生事件名：**stdin 自带事件名时一律以 stdin 为准**，`--event` 只是兜底。

    兜底存在的理由：个别工具的部分事件不在 stdin 放事件名，只能由安装器把事件名写进
    命令（现在是 Gemini / Cursor / Trae IDE / Copilot 这四家；TraeCli 的托管项是
    「单一命令 + matchers 列全部事件」，事件名走 stdin，安装器不给它加 `--event`）。

    字段别名与顺序沿用 CodeIsland bridge：`hook_event_name` → `hookEventName`（Grok）
    → `eventName` → `event` → `hookName`（Cline）。
    """
    event = first_string(data, ("hook_event_name", "hookEventName", "eventName", "event"))
    if event is None:
        event = first_string(data, ("hookName",))
    return event or event_tag or ""


def normalize_event(native_event):
    """原生事件名 → 应用侧事件名（归一表里没有就原样返回）。"""
    return EVENT_ALIASES.get(native_event, native_event)


def resolve_session_id(data, source):
    """会话 id：`session_id` → `sessionId` → `conversationId` → `taskId` → `payload.*`
    → `data.*`，都缺时用 `<source>-ppid-<ppid>` 兜底（与 CodeIsland bridge 的兜底同形）。

    第三方来源各有各的字段名：Cursor/Grok/Copilot 用 `sessionId`，Google Antigravity
    用 `conversationId`，Cline 用 `taskId`（见 CodeIsland bridge 的适配段）。
    """
    found = first_string(data, ("session_id", "sessionId", "conversationId", "taskId"))
    if found is None:
        for wrapper in ("payload", "data"):
            found = first_string(
                nested_mapping(data, wrapper), ("session_id", "sessionId", "conversationId")
            )
            if found:
                break
    return found or "%s-ppid-%d" % (source, os.getppid())


def resolve_cwd(data, source):
    """工作目录：`cwd` → `workspaceRoot`（Grok）→ Grok 的 `GROK_WORKSPACE_ROOT`
    → 本进程的 cwd（Gemini 这类 payload 不带 cwd 的来源靠它兜底）。"""
    cwd = first_string(data, ("cwd", "workspaceRoot"))
    if cwd is None and source == GROK_SOURCE:
        cwd = first_string(os.environ, ("GROK_WORKSPACE_ROOT",))
    return cwd or os.getcwd()


def resolve_tool(data):
    """工具名与入参：各来源字段名不同，按 CodeIsland bridge 的适配顺序取。

    工具名：`tool_name` → `toolName`（Copilot/Cursor）→ `preToolUse.toolName` /
    `postToolUse.toolName`（Cline）。
    入参：`tool_input` → `toolInput` → `toolArgs`（Copilot 的 JSON 字符串）→
    `preToolUse.parameters` / `postToolUse.parameters`（Cline）。
    """
    tool_name = first_string(data, ("tool_name", "toolName"))
    if tool_name is None:
        for wrapper in ("preToolUse", "postToolUse"):
            tool_name = first_string(nested_mapping(data, wrapper), ("toolName", "tool_name"))
            if tool_name:
                break

    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = data.get("toolInput")
    if not isinstance(tool_input, dict):
        raw_args = first_string(data, ("toolArgs",))
        if raw_args:
            try:
                parsed_args = json.loads(raw_args)
            except ValueError:
                parsed_args = None
            if isinstance(parsed_args, dict):
                tool_input = parsed_args
    if not isinstance(tool_input, dict):
        for wrapper in ("preToolUse", "postToolUse"):
            parameters = nested_mapping(data, wrapper).get("parameters")
            if isinstance(parameters, dict):
                tool_input = parameters
                break
    return tool_name, tool_input if isinstance(tool_input, dict) else {}


def resolve_session_file(data, source, session_id, cwd):
    """记录文件路径：`transcript_path` → `transcriptPath`；Grok 的 payload 不带记录
    路径，但它的会话布局是确定的，按 `$GROK_HOME/sessions/<编码后的 cwd>/<会话 id>/
    chat_history.jsonl` 自行拼接（与 CodeIsland bridge 同一条公式）。"""
    found = first_string(data, ("transcript_path", "transcriptPath"))
    if found:
        return found
    if source != GROK_SOURCE:
        return None
    raw_home = os.environ.get("GROK_HOME") or ""
    if raw_home == "~":
        grok_home = os.path.expanduser("~")
    elif raw_home.startswith("~/"):
        grok_home = os.path.join(os.path.expanduser("~"), raw_home[2:])
    elif raw_home:
        grok_home = raw_home
    else:
        grok_home = os.path.join(os.path.expanduser("~"), ".grok")
    return "%s/sessions/%s/%s/chat_history.jsonl" % (
        grok_home, quote(cwd, safe="-._~"), session_id
    )


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


def apply_event(state, event, native_event, data, tool_name, tool_input, ask_payload):
    """按应用侧事件名推导 `status` 与随行字段，返回这条事件是否要上报。

    分支语义逐条沿用改造前 Claude 分支（所以不带参数的 Claude 路径行为不变）；
    `status` 取值见 `HookEvent.determinePhase`。返回 False 表示**不上报**
    （`Notification(permission_prompt)` 就是如此：`PermissionRequest` 那一路信息更全）。
    """
    if event == "UserPromptSubmit":
        # User just sent a message - the agent is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # `AskUserQuestion`：把问题一并发出，刘海可以就地作答。旧版应用不认识
        # `ask` 字段会忽略它、只回 allow/deny，因此不需要版本协商。
        if ask_payload:
            state["ask"] = ask_payload

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            return False
        if notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"
        if native_event in STOP_FAILURE_EVENTS:
            # 一轮以 API 错误（限流/鉴权/计费）结束：仍是终态，但把错误一并带上
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

    return True


def emit_decision(source, response, tool_input, ask_payload):
    """把应用的决定翻译成该来源的 stdout 形状；拿不到决定时不输出任何内容。

    不输出 = 回落工具自己的原生审批（Claude 家族与 Codex 是 fail-open、Gemini 是弹它
    自己的确认框），这是「应用不在 / 超时」时唯一安全的语义。
    """
    if not response:
        return
    decision = response.get("decision", "ask")
    reason = response.get("reason", "")
    if decision not in ("allow", "deny", "answer"):
        return

    updated_input = None
    if decision == "answer":
        # 刘海答完：把「问题正文 → 答案字符串」映射回 `updatedInput`，走 allow 通道直接
        # 满足这次交互（不再弹原生提问）。映射不出答案就不输出，回落原生弹窗。
        if not ask_payload:
            return
        updated_input = build_updated_input(tool_input, response.get("answers"))
        if updated_input is None:
            return

    allow = decision != "deny"
    if source == GEMINI_SOURCE:
        print(json.dumps({"decision": "allow" if allow else "deny"}))
        return

    decision_payload = {"behavior": "allow" if allow else "deny"}
    if not allow:
        decision_payload["message"] = reason or "Denied by user via AgentIsland"
    elif updated_input is not None:
        decision_payload["updatedInput"] = updated_input
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision_payload,
        }
    }
    print(json.dumps(output))


def forward_in_background(state):
    """Cline 的转发：交给 fork 出来的后台子进程，父进程立刻返回。

    子进程把 stdout/stderr 换成 /dev/null，避免它拖住 hook 读取方（Cline 要求 hook
    立刻输出并退出），也避免任何输出混进 Cline 解析的那一行 JSON。
    """
    try:
        child = os.fork()
    except OSError:
        send_event(state, wait=False)
        return
    if child != 0:
        return
    try:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
    except OSError:
        pass
    send_event(state, wait=False)
    os._exit(0)


def main():
    source, event_tag = parse_args(sys.argv[1:])

    if source == CLINE_SOURCE:
        # Cline 的每个 hook 都必须立刻输出合法 JSON —— 即使这条事件不上报（协议要求）。
        # 因此先答 `{"cancel":false}`，再决定要不要转发。
        sys.stdout.write('{"cancel":false}')
        sys.stdout.flush()
        if is_grok_runtime_duplicate(source):
            return
    elif is_grok_runtime_duplicate(source):
        # Grok 导入的 Claude / Cursor hook：整条丢弃（不连 socket、不写 stdout）。
        return

    data = read_stdin()

    native_event = resolve_event_name(data, event_tag)
    event = normalize_event(native_event)
    tool_name, tool_input = resolve_tool(data)

    state = {
        "session_id": resolve_session_id(data, source),
        "cwd": resolve_cwd(data, source),
        "event": event,
        "agent": source,
    }
    if source == CLINE_SOURCE:
        # Cline 的 hook 由 VSCode 派生的临时 shell 拉起：ppid 不是常驻进程，报上去会被
        # 应用的存活检查秒回收（CodeIsland 同样清掉这个 pid）。因此不带 pid / tty。
        pass
    else:
        state["pid"] = os.getppid()
        state["tty"] = get_tty()

    session_file = resolve_session_file(data, source, state["session_id"], state["cwd"])
    if session_file:
        state["session_file"] = session_file

    ask_payload = None
    if event == "PermissionRequest" and source in CLAUDE_FAMILY and tool_name == ASK_TOOL_NAME:
        ask_payload = build_ask_payload(tool_input)

    if source == CLINE_SOURCE:
        # cancel 已在开头答过：这里只决定要不要把这条事件交给后台子进程转发（不等决定）。
        reported = apply_event(
            state, event, native_event, data, tool_name, tool_input, ask_payload
        )
        if reported:
            forward_in_background(state)
        return

    if not apply_event(state, event, native_event, data, tool_name, tool_input, ask_payload):
        return

    if state.get("status") == "waiting_for_approval":
        # 阻塞审批：登记待批并等刘海决定（ask 分支用更短的预算，见常量处的不变量）。
        state["expects_response"] = True
        response = send_event(state, ASK_TIMEOUT_SECONDS if ask_payload else None)
        emit_decision(source, response, tool_input, ask_payload)
        return

    # 非阻塞事件：只上报，不等应答。
    send_event(state)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        # 任何异常都不得变成非 0 退出码：工具侧会把非 0 记成 hook 失败。
        pass
    sys.exit(0)
