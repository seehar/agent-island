// agent-island-opencode-plugin.js —— 由 Vibe Notch（Claude Island）安装的 OpenCode 插件
//
// 作用：把会话生命周期、工具执行与「等待用户确认」实时上报给 notch 应用
// （unix socket）。OpenCode 的插件加载器只认纯 JS（不转译 TS），因此本文件用 JS。
//
// 安装位置：~/.config/opencode/plugins/agent-island-state.js
// 协议：连接 /tmp/claude-island.sock（可用 AGENT_ISLAND_SOCKET 覆盖），
// 发送一个 JSON 对象即断开。应用不可用时静默失败。

import { execSync } from "node:child_process";
import net from "node:net";

const AGENT = "opencode";
const SOCKET_PATH = process.env.AGENT_ISLAND_SOCKET || "/tmp/claude-island.sock";

// 串行发送，保证事件顺序。
let chain = Promise.resolve();
let reportedSessionId;
let tty;
let pid;

function detectTty() {
  try {
    const out = execSync(`ps -p ${process.pid} -o tty=`, { encoding: "utf8", timeout: 800 }).trim();
    if (out && out !== "?" && out !== "-") {
      return out.startsWith("/dev/") ? out.slice("/dev/".length) : out;
    }
  } catch {
    // 忽略：拿不到 tty 只是无法从 notch 聚焦终端。
  }
  return undefined;
}

/** 发送一条事件；永不抛错，永不阻塞 Agent。子会话（父 id 不同）的事件一律忽略。 */
function send(payload) {
  const sessionId = payload.session_id || reportedSessionId;
  if (!sessionId) {
    return Promise.resolve();
  }
  if (reportedSessionId && sessionId !== reportedSessionId) {
    return Promise.resolve();
  }

  const body = {
    session_id: sessionId,
    cwd: payload.cwd || process.cwd(),
    pid,
    tty,
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

/** 从事件 properties 里取会话 id。 */
function sessionIdFrom(properties) {
  if (!properties || typeof properties !== "object") {
    return undefined;
  }
  if (typeof properties.sessionID === "string") {
    return properties.sessionID;
  }
  if (properties.info && typeof properties.info.id === "string") {
    return properties.info.id;
  }
  if (properties.session && typeof properties.session.id === "string") {
    return properties.session.id;
  }
  return undefined;
}

export const AgentIslandPlugin = async () => {
  if (pid === undefined) {
    pid = process.pid;
    tty = detectTty();
  }

  return {
    // 用户提交消息 → 会话进入处理中（根会话即由用户操作的那个）
    "chat.message": async ({ sessionID }) => {
      if (sessionID) {
        reportedSessionId = sessionID;
      }
      await send({ event: "UserPromptSubmit", status: "processing", session_id: sessionID });
    },

    // 工具执行前后 → 与 Claude 的 PreToolUse/PostToolUse 对齐
    "tool.execute.before": async (input, output) => {
      const sessionId = input?.sessionID || reportedSessionId;
      if (sessionId) {
        reportedSessionId = sessionId;
      }
      await send({
        event: "PreToolUse",
        status: "running_tool",
        session_id: sessionId,
        tool: input?.tool,
        tool_input: output?.args,
        tool_use_id: input?.callID,
      });
    },

    "tool.execute.after": async (input) => {
      await send({
        event: "PostToolUse",
        status: "processing",
        session_id: input?.sessionID || reportedSessionId,
        tool: input?.tool,
        tool_use_id: input?.callID,
      });
    },

    // 等待用户确认：应用只展示状态，批准仍在 OpenCode 内完成
    "permission.ask": async (input) => {
      await send({
        event: "ToolApproval",
        status: "waiting_for_approval",
        session_id: input?.sessionID || reportedSessionId,
        tool: input?.tool || input?.permission,
        tool_use_id: input?.callID,
      });
    },

    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      const sessionId = sessionIdFrom(properties);
      if (sessionId) {
        reportedSessionId = sessionId;
      }

      switch (type) {
        case "session.created":
          // 会话创建是服务端全局事件：把它当作根会话锚点后立即上报
          if (sessionId) {
            reportedSessionId = sessionId;
          }
          await send({ event: "SessionStart", status: "idle", session_id: sessionId });
          break;
        case "session.idle":
          await send({ event: "Stop", status: "waiting_for_input", session_id: sessionId });
          break;
        case "permission.asked":
        case "question.asked":
          await send({ event: "ToolApproval", status: "waiting_for_approval", session_id: sessionId });
          break;
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          await send({ event: "PostToolUse", status: "processing", session_id: sessionId });
          break;
        case "session.deleted":
          await send({ event: "SessionEnd", status: "ended", session_id: sessionId });
          break;
        default:
          break;
      }
    },
  };
};