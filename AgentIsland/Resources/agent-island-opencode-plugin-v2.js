// agent-island-opencode-plugin-v2.js —— OpenCode 2.x 的 AgentIsland 插件
// agent-island-opencode-plugin-version: 5
// agent-island-opencode-plugin-api: v2
//
// ⚠️ 本文件由 AgentIsland 管理，勿手改：应用每次「安装集成」都会用内置副本整份覆盖。
//
// 作用与 1.x 版（`agent-island-opencode-plugin.js`）相同：把会话生命周期、工具执行与
// 「等待用户确认」实时上报给 notch 应用（unix socket）。差异来自 OpenCode 2.x 的插件
// API：默认导出必须是 `{ id, setup(ctx) }` 而不是一个返回 hooks 的函数；事件走
// `ctx.event.subscribe()`，工具前后走 `ctx.tool.hook(...)`，审批回写走
// `ctx.permission.reply(...)`（不再需要 SDK/HTTP 兜底）。
//
// 安装位置：~/.config/opencode/plugins/agent-island-state.js
// 协议：连接 /tmp/agent-island.sock（可用 AGENT_ISLAND_SOCKET 覆盖）。
//   - 普通事件：发一个 JSON 对象即断开（fire-and-forget）；
//   - 审批事件：发 expects_response:true 并**保持连接**，等刘海回 {decision,reason}，
//     再调 ctx.permission.reply 回写。应用不可达 / 超时 / 决策未知 → **不回写**，
//     由 opencode 原生审批继续兜着（与 Claude 链路的 fail-open 一致）。
//
// 什么会上报：只有根会话（`parentID` 为空）。OpenCode 的子代理会话也是会话，按 v1 的
// 口径一律静默丢弃——否则刘海会多出一堆只跑几步就结束的幽灵行。

import { execSync } from "node:child_process";
import net from "node:net";

const AGENT = "opencode";
const SOCKET_PATH = process.env.AGENT_ISLAND_SOCKET || "/tmp/agent-island.sock";

/** 等刘海决策的上限（毫秒）。超时后只是「不回写」，原生审批继续兜着。 */
const DEFAULT_DECISION_TIMEOUT_MS = 120000;

/** 拒绝时刘海没带理由的兜底文案。 */
const DENY_FALLBACK_REASON = "Denied on AgentIsland";

/** opencode 2.x 的 permission 应答取值。 */
const REPLY_ONCE = "once";
const REPLY_REJECT = "reject";

/** 审批挂起期的普通事件静音：生命周期与审批应答除外。 */
const SUPPRESSION_EXEMPT_TYPES = new Set([
  "session.created",
  "session.deleted",
  "permission.asked",
  "permission.replied",
]);

// 串行发送，保证事件顺序。
let chain = Promise.resolve();
let pid;
let tty;
let pluginCwd;

/**
 * Paseo（`@getpaseo/server`）托管终端身份：有值时刘海可以不经 tmux 把消息写进本会话的 pty。
 * 进程启动时求值一次（环境变量在进程生命周期内不变）。
 */
const paseoTerminalId = (process.env.PASEO_TERMINAL_ID || "").trim() || undefined;
const paseoCliPath = (process.env.PASEO_HOOK_CLI || "").trim() || undefined;

/** 会话 id → 是否根会话（子代理会话不上报）。 */
const rootSessionById = new Map();
/** 会话 id → 工作目录（事件的 `location.directory` 不一定带，用它兜底）。 */
const directoryBySession = new Map();
/** 当前有在飞审批的会话 → 笔数（并发审批必须计数）。 */
const pendingRequestSessions = new Map();
/** 审批 requestID → 登记 pending 时用的会话 id。 */
const approvalSessionByRequest = new Map();
const APPROVAL_SESSION_LIMIT = 256;

/** 进程级单例哨兵。
 *
 *  OpenCode 2.x 会**按位置**加载插件（每个项目目录各一份实例），同一个 `setup` 因此会
 *  被调用多次：事件会重复上报（实测一次提示词收到 4 条、创建会话收到 2 条），审批
 *  还会同时挂出多张卡。用 `globalThis` 上的哨兵只让第一个实例接管，其余实例直接返回
 *  （不注册 hook、不订阅事件）；拥有者卸载时清掉哨兵，下一次加载可以重新接管。 */
const SINGLETON_KEY = Symbol.for("agent-island.opencode.plugin.v2");
const SINGLETON_TOKEN = Symbol("agent-island.opencode.instance");

function detectTty() {
  try {
    const out = execSync(`ps -p ${process.pid} -o tty=`, { encoding: "utf8", timeout: 800 }).trim();
    if (out && out !== "?" && out !== "-") {
      return out.startsWith("/dev/") ? out.slice("/dev/".length) : out;
    }
  } catch {
    // 忽略：拿不到 tty 只是无法从刘海聚焦终端。
  }
  return undefined;
}

function debugLog(message) {
  if (process.env.AGENT_ISLAND_DEBUG === "1") {
    console.error(`[agent-island] ${message}`);
  }
}

function stringOrUndefined(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** 发送一条事件；永不抛错，永不阻塞 Agent。 */
function send(payload) {
  const sessionId = payload.session_id;
  if (!sessionId) {
    return Promise.resolve();
  }
  const body = {
    session_id: sessionId,
    cwd: payload.cwd || directoryBySession.get(sessionId) || pluginCwd || process.cwd(),
    pid,
    tty,
    paseo_terminal_id: paseoTerminalId,
    paseo_cli_path: paseoCliPath,
    agent: AGENT,
    ...payload,
  };

  const attempt = () => {
    const { promise, resolve } = Promise.withResolvers();
    const socket = net.createConnection(SOCKET_PATH, () => {
      socket.write(JSON.stringify(body));
      socket.end();
    });
    const finish = () => {
      socket.destroy();
      resolve();
    };
    socket.setTimeout(400, finish);
    socket.on("data", finish);
    socket.on("error", finish);
    socket.on("end", finish);
    socket.on("close", resolve);
    return promise;
  };

  chain = chain.then(attempt).catch(() => {});
  return chain;
}

function beginApproval(sessionId) {
  pendingRequestSessions.set(sessionId, (pendingRequestSessions.get(sessionId) || 0) + 1);
}

function endApproval(sessionId) {
  const count = (pendingRequestSessions.get(sessionId) || 0) - 1;
  if (count > 0) {
    pendingRequestSessions.set(sessionId, count);
  } else {
    pendingRequestSessions.delete(sessionId);
  }
}

function rememberApprovalSession(requestId, sessionId) {
  if (!requestId || !sessionId) {
    return;
  }
  approvalSessionByRequest.delete(requestId);
  approvalSessionByRequest.set(requestId, sessionId);
  while (approvalSessionByRequest.size > APPROVAL_SESSION_LIMIT) {
    const oldest = approvalSessionByRequest.keys().next().value;
    approvalSessionByRequest.delete(oldest);
  }
}

function registeredApprovalSession(requestId) {
  return requestId ? approvalSessionByRequest.get(requestId) : undefined;
}

/** 决策等待时长：环境变量 > 缺省值（安装的插件没有 options 入口）。 */
function decisionBudget(envName, fallback) {
  const fromEnv = Number(process.env[envName]);
  return Number.isFinite(fromEnv) && fromEnv > 0 ? fromEnv : fallback;
}

/** 向刘海发起一次阻塞询问，返回下行决策。**永不抛错**。 */
function requestDecision(payload, timeoutMs) {
  const budget = Number(timeoutMs) > 0 ? Number(timeoutMs) : DEFAULT_DECISION_TIMEOUT_MS;
  return new Promise((resolve) => {
    let settled = false;
    let buffer = "";
    let socket;

    const finish = (value) => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        if (socket) {
          socket.destroy();
        }
      } catch {
        // 忽略：连接已经断掉时 destroy 也可能抛错。
      }
      resolve(value);
    };

    try {
      socket = net.createConnection(SOCKET_PATH);
    } catch {
      resolve(undefined);
      return;
    }

    // 先注册监听再 write；写完不 end()（半关闭会让服务端丢掉应答）。
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      try {
        const parsed = JSON.parse(buffer);
        finish(parsed && typeof parsed === "object" ? parsed : undefined);
      } catch {
        // 应答还没收齐：继续攒。
      }
    });
    socket.on("error", () => finish(undefined));
    socket.on("close", () => finish(undefined));
    socket.setTimeout(budget, () => finish(undefined));
    socket.on("connect", () => {
      try {
        socket.write(JSON.stringify(payload));
      } catch {
        finish(undefined);
      }
    });
  });
}

/** v2 的审批请求 → 上报字段。
 *
 *  `action` 是权限动作名（`bash` / `edit` / …），`resources` 是被触碰的目标
 *  （bash 是命令，edit/write 是文件）。把它们摊成人能看懂的形状，供刘海分类与展示。 */
function approvalFields(data) {
  const action = stringOrUndefined(data && data.action);
  const resources = Array.isArray(data && data.resources) ? data.resources : [];
  const metadata =
    data && data.metadata && typeof data.metadata === "object" ? data.metadata : {};
  const input = { resources, metadata };
  // v2 的 shell 动作名是 `shell`（v1 叫 `bash`）：两种都摊成 `command`，刘海才能
  // 按命令预览与危险命令判定。
  if ((action === "bash" || action === "shell") && resources.length > 0) {
    input.command = resources.join(" && ");
  }
  if ((action === "edit" || action === "write") && resources.length > 0) {
    input.file_path = resources[0];
  }
  const source = data && data.source && typeof data.source === "object" ? data.source : {};
  return {
    tool: action,
    tool_input: input,
    tool_use_id: stringOrUndefined(data && data.id),
    call_id: stringOrUndefined(source.id),
  };
}

function approvalPayload(fields, sessionId) {
  return {
    event: "ToolApproval",
    status: "waiting_for_approval",
    session_id: sessionId,
    cwd: directoryBySession.get(sessionId) || pluginCwd || process.cwd(),
    pid,
    tty,
    paseo_terminal_id: paseoTerminalId,
    paseo_cli_path: paseoCliPath,
    agent: AGENT,
    expects_response: true,
    tool: fields.tool,
    tool_input: fields.tool_input,
    tool_use_id: fields.tool_use_id,
  };
}

/** 一次完整的远程审批：问刘海 → 用 `ctx.permission.reply` 回写。
 *
 *  三条「不回写」路径（交给 opencode 原生审批）：应用不可达/超时、决策未知、
 *  回写抛错。事件里取不到 requestID 时无从回写，直接返回。 */
async function runApproval(context, data) {
  const sessionId = stringOrUndefined(data && data.sessionID);
  const fields = approvalFields(data);
  const requestId = fields.tool_use_id;
  if (!sessionId || !requestId) {
    return;
  }

  // 先把卡片打出来（fire-and-forget），与 v1 的信封形状一致。
  await send({
    event: "ToolApproval",
    status: "waiting_for_approval",
    session_id: sessionId,
    tool: fields.tool,
    tool_input: fields.tool_input,
    tool_use_id: requestId,
  });

  beginApproval(sessionId);
  rememberApprovalSession(requestId, sessionId);
  let response;
  try {
    response = await requestDecision(
      approvalPayload(fields, sessionId),
      decisionBudget("AGENT_ISLAND_GATE_TIMEOUT_MS", DEFAULT_DECISION_TIMEOUT_MS)
    );
  } finally {
    endApproval(sessionId);
  }
  if (!response || typeof response !== "object") {
    return;
  }

  try {
    if (response.decision === "allow") {
      await context.permission.reply({
        sessionID: sessionId,
        requestID: requestId,
        decision: REPLY_ONCE,
      });
    } else if (response.decision === "deny") {
      const reason = typeof response.reason === "string" ? response.reason.trim() : "";
      await context.permission.reply({
        sessionID: sessionId,
        requestID: requestId,
        decision: REPLY_REJECT,
        message: reason || DENY_FALLBACK_REASON,
      });
    }
  } catch (error) {
    debugLog(`回写审批失败（requestID=${requestId}）：${String(error)}`);
  }
}

/** 判断一个会话是不是根会话；结果缓存。取不到会话信息时按根会话处理（宁可多报）。 */
async function isRootSession(context, sessionId) {
  if (rootSessionById.has(sessionId)) {
    return rootSessionById.get(sessionId);
  }
  let isRoot = true;
  try {
    const info = await context.session.get({ sessionID: sessionId });
    isRoot = !(info && info.parentID);
    const directory = info && typeof info.directory === "string" ? info.directory : undefined;
    if (directory) {
      directoryBySession.set(sessionId, directory);
    }
  } catch {
    // 取不到：按根会话处理。
  }
  rootSessionById.set(sessionId, isRoot);
  return isRoot;
}

/** 处理一条公共事件。 */
async function handleEvent(context, event) {
  const type = event && event.type;
  const data = (event && event.data) || {};
  const sessionId = stringOrUndefined(data.sessionID);
  if (!type || !sessionId) {
    return;
  }

  // 每条事件都尽量记下它所在的位置：`session.created` 之外的事件也可能来自别的
  // 项目（后台服务同时服务多个目录），缺了它就只能退回插件实例自己的目录。
  const eventDirectory = stringOrUndefined(event.location && event.location.directory);
  if (eventDirectory && !directoryBySession.has(sessionId)) {
    directoryBySession.set(sessionId, eventDirectory);
  }

  if (type === "session.created") {
    const parentId = stringOrUndefined(data.parentID);
    rootSessionById.set(sessionId, parentId === undefined);
    const directory =
      (data.location && stringOrUndefined(data.location.directory)) ||
      (event.location && stringOrUndefined(event.location.directory));
    if (directory) {
      directoryBySession.set(sessionId, directory);
    }
    if (parentId === undefined) {
      await send({
        event: "SessionStart",
        status: "idle",
        session_id: sessionId,
        cwd: directory,
      });
    }
    return;
  }

  if (type === "session.deleted") {
    if (await isRootSession(context, sessionId)) {
      await send({ event: "SessionEnd", status: "ended", session_id: sessionId });
    }
    rootSessionById.delete(sessionId);
    directoryBySession.delete(sessionId);
    return;
  }

  // 审批必须最先处理：它不能被挂起期的普通事件静音吃掉。
  if (type === "permission.asked") {
    if (!(await isRootSession(context, sessionId))) {
      return;
    }
    // 交互提问（action `question`）走 2.x 的 form 通道，插件这一侧没有可回传的
    // 作答载荷：只上报「等待作答」，让刘海给出「去终端作答」的提示，
    // 不给出一副对提问毫无意义的 Allow/Deny。
    if (stringOrUndefined(data.action) === "question") {
      await send({
        event: "ToolApproval",
        status: "waiting_for_approval",
        session_id: sessionId,
        tool: "question",
      });
      return;
    }
    void runApproval(context, data).catch(() => {});
    return;
  }

  if (type === "permission.replied") {
    const requestId = stringOrUndefined(data.requestID);
    const replySessionId = registeredApprovalSession(requestId) || sessionId;
    await send({
      event: "PostToolUse",
      status: "processing",
      session_id: replySessionId,
      tool_use_id: requestId,
    });
    return;
  }

  if (pendingRequestSessions.has(sessionId) && !SUPPRESSION_EXEMPT_TYPES.has(type)) {
    return;
  }

  if (!(await isRootSession(context, sessionId))) {
    return;
  }

  switch (type) {
    case "session.execution.started":
      await send({ event: "UserPromptSubmit", status: "processing", session_id: sessionId });
      break;
    case "session.execution.succeeded":
    case "session.execution.failed":
    case "session.execution.interrupted":
    case "session.idle":
      await send({ event: "Stop", status: "waiting_for_input", session_id: sessionId });
      break;
    case "session.compaction.started":
      await send({ event: "PreCompact", status: "compacting", session_id: sessionId });
      break;
    case "session.compaction.ended":
      await send({ event: "PostCompact", status: "processing", session_id: sessionId });
      break;
    default:
      break;
  }
}

/** 插件定义：OpenCode 2.x 只认 `{ id, setup(ctx) }`。 */
const AgentIslandPluginV2 = {
  id: "agent-island",
  async setup(context) {
    // 只有第一个实例订阅公共事件流（它是全局的，每个位置都订阅会让事件重复上报）；
    // 工具 / 提示词 hook 则**每个位置都要注册**——它们按位置生效，跳过的位置里
    // 工具调用就再也报不出来。
    const isOwner = globalThis[SINGLETON_KEY] === undefined;
    if (isOwner) {
      globalThis[SINGLETON_KEY] = SINGLETON_TOKEN;
    }

    if (pid === undefined) {
      pid = process.pid;
      tty = detectTty();
    }
    // 只记第一个（订阅事件流的）实例的目录：同一进程里多个位置的实例共享模块级
    // 变量，后加载的位置不能把兜底目录改走。真正的事件目录优先（见 handleEvent）。
    if (!pluginCwd) {
      pluginCwd = (context && context.location && context.location.directory) || process.cwd();
    }

    // 工具执行前后 → 与 Claude 的 PreToolUse/PostToolUse 对齐。
    await context.tool.hook("execute.before", (event) => {
      const sessionId = stringOrUndefined(event && event.sessionID);
      if (!sessionId) {
        return;
      }
      void isRootSession(context, sessionId).then((isRoot) => {
        if (!isRoot) {
          return;
        }
        return send({
          event: "PreToolUse",
          status: "running_tool",
          session_id: sessionId,
          tool: event.tool,
          tool_input: event.input,
          tool_use_id: event.id,
        });
      });
    });

    await context.tool.hook("execute.after", (event) => {
      const sessionId = stringOrUndefined(event && event.sessionID);
      if (!sessionId) {
        return;
      }
      void isRootSession(context, sessionId).then((isRoot) => {
        if (!isRoot) {
          return;
        }
        return send({
          event: "PostToolUse",
          status: "processing",
          session_id: sessionId,
          tool: event.tool,
          tool_use_id: event.id,
        });
      });
    });

    // 用户提交提示词 → 会话进入处理中。子代理会话同样是「提示词」，必须先判根会话，
    // 否则刘海会为每个子代理冒出一行。
    await context.session.hook("prompt", (event) => {
      const sessionId = stringOrUndefined(event && event.sessionID);
      if (!sessionId) {
        return;
      }
      void isRootSession(context, sessionId).then((isRoot) => {
        if (!isRoot) {
          return;
        }
        return send({ event: "UserPromptSubmit", status: "processing", session_id: sessionId });
      });
    });

    let controller;
    if (isOwner) {
      controller = new AbortController();
      void (async () => {
        try {
          for await (const event of context.event.subscribe({ signal: controller.signal })) {
            await handleEvent(context, event);
          }
        } catch {
          // 插件卸载 / 流中断：静默。
        }
      })();
    }

    return () => {
      if (controller) {
        controller.abort();
      }
      // 只有订阅者拥有哨兵；其它位置的实例卸载时不能把它清掉。
      if (isOwner && globalThis[SINGLETON_KEY] === SINGLETON_TOKEN) {
        delete globalThis[SINGLETON_KEY];
      }
    };
  },
};

export default AgentIslandPluginV2;