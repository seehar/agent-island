// agent-island-opencode-plugin.js —— 由 AgentIsland 安装的 OpenCode 插件
// agent-island-opencode-plugin-version: 3
//
// ⚠️ 本文件由 AgentIsland 管理，勿手改：应用每次「安装集成」都会用内置副本整份覆盖。
//
// 作用：把会话生命周期、工具执行与「等待用户确认」实时上报给 notch 应用
// （unix socket）。OpenCode 的插件加载器只认纯 JS（不转译 TS），因此本文件用 JS。
//
// 安装位置：~/.config/opencode/plugins/agent-island-state.js
// 协议：连接 /tmp/agent-island.sock（可用 AGENT_ISLAND_SOCKET 覆盖）。
//   - 普通事件：发一个 JSON 对象即断开（fire-and-forget）；
//   - 审批事件：发 expects_response:true 并**保持连接**，等刘海回 {decision,reason}，
//     再按决策回写 opencode（POST /permission/{id}/reply）。
//     应用不可达 / 超时 / 决策未知 → **不回写**，由 opencode 原生 TUI 审批接管
//     （与 Claude 链路的 fail-open 一致）；
//   - 提问事件（`question.asked`）：同构的阻塞询问，上行带 `ask` 载荷（问题与选项），
//     刘海作答后回写 POST /question/{id}/reply（用户放弃 → /question/{id}/reject）。
// 版本 3（本次）：新增交互提问（opencode 的 `question` 工具）的远程作答。此前它只被
// 报成「一条看不懂的待批」——刘海显示成批准/拒绝，而那两个按钮对提问毫无意义。
// 版本 2：新增远程审批。此前只上报状态，批准只能在终端里完成。

import { execSync } from "node:child_process";
import net from "node:net";

const AGENT = "opencode";
const SOCKET_PATH = process.env.AGENT_ISLAND_SOCKET || "/tmp/agent-island.sock";

/** 等刘海决策的上限（毫秒）。opencode 服务端在审批上是 `Deferred.await` 且**没有
 *  超时**，所以超时后我们只是「不回写」，让终端里的原生审批继续兜着。 */
const DEFAULT_DECISION_TIMEOUT_MS = 120000;

/** 交互提问的工具名。应用按它把这张待批认成「要作答」而不是「要许可」
 *  （`AgentKind.opencode.interactiveToolNames`），因此两侧必须逐字一致。 */
const TOOL_QUESTION = "question";

/** 等刘海作答的上限（毫秒）。opencode 的提问同样是服务端 `Deferred.await` 且**没有
 *  超时**，所以超时后我们只是「不回写」，让终端里的原生提问继续兜着。
 *  递减链：应用 pending TTL 330s > 问答客户端 240s（本值，与 omp 的 ask 同值）>
 *  闸门客户端 120s。 */
const DEFAULT_ASK_TIMEOUT_MS = 240000;

/** opencode 的 reply 取值：`once` = 只放行这一次；`always` = 服务端把 patterns 加进
 *  已批准列表；`reject` = 拒绝。刘海目前只有「允许/拒绝」两个按钮，因此本文件只会
 *  产出 `once` / `reject`；将来加「总是允许」时在这里补 `always`。 */
const REPLY_ONCE = "once";
const REPLY_REJECT = "reject";

/** 拒绝时刘海没带理由的兜底文案（措辞由集成侧合成，应用对模型措辞零知识）。 */
const DENY_FALLBACK_REASON = "Denied on AgentIsland";

/** 不受「审批挂起期静音」影响的事件：生命周期事件维护会话行，审批应答事件是审批
 *  闭环本身（否则拒绝之后状态会一直停在 waiting_for_approval）。 */
const SUPPRESSION_EXEMPT_EVENTS = new Set([
  "session.created",
  "session.deleted",
  "permission.replied",
  "permission.v2.replied",
  "question.replied",
  "question.v2.replied",
  "question.rejected",
  "question.v2.rejected",
]);

// 串行发送，保证事件顺序。
let chain = Promise.resolve();
let reportedSessionId;
let tty;
let pid;

/** 由插件工厂注入的工作目录，用作上报的 cwd。 */
let pluginCwd;

/** 当前有在飞审批的会话 → 在飞笔数。并发审批时必须计数：用一个 Set 的话，
 *  先结束的那笔会把同会话还在挂起的另一笔的静音一起解掉。 */
const pendingRequestSessions = new Map();

/** 审批请求 id → **登记 pending 时**用的会话 id。
 *
 *  为什么不能只信应答事件里的 sessionID：应用侧是按 (agent, sessionId, toolUseId)
 *  匹配那张 pending 卡的，而 `permission.replied` 等事件里的 `sessionID` 可能缺失、
 *  也可能与登记时不是同一个（子会话、形状漂移）——一旦失配，「终端一动就收手」
 *  就失效，退化成挂到超时。所以这里以「我们登记时用的会话」为准，事件里的
 *  sessionID 只作兜底。
 *
 *  上限 256 + 读而不删：既防无界增长，也让同一次审批的多条应答事件都能命中同一条登记
 *  （新登记时淘汰最久未被碰过的那条）。 */
const approvalSessionByRequest = new Map();
const APPROVAL_SESSION_LIMIT = 256;

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

/** 从事件 properties 里取「审批请求 id」。
 *
 *  注意它**不是** `tool_use_id`：`permission.asked` 的 `id` 是 opencode 的
 *  permission id（= reply 路由里的 requestID，用它做卡片身份 + 回写地址），而
 *  `tool_use_id` 是工具调用的 id（Claude 链路用它关联 PreToolUse/PostToolUse，
 *  两者在 opencode 上是两个不同的值）。本函数只服务于「终端已审批 → 请立刻收掉
 *  挂起的卡片」这一条路径，因此刻意不复用 `approvalEventFields`。
 *
 *  字段名（opencode 1.18.27 二进制内的 zod schema 原文）：
 *  `permission.replied = {sessionID, requestID, reply}`、
 *  `permission.v2.replied = {sessionID, requestID, reply}`（同名字段，v2 的差异在
 *  asked 侧：`action`/`resources`/`save`）、
 *  `question.replied = {sessionID, requestID, answers}`、
 *  `question.rejected = {sessionID, requestID}` —— 四者都有 `requestID`。
 *  取不到（未知/畸形 payload）时返回 undefined，调用方就不带该字段。
 *
 *  @param {object} properties 事件 properties
 *  @returns {string|undefined} requestID
 */
function requestIdFrom(properties) {
  if (!properties || typeof properties !== "object") {
    return undefined;
  }
  const candidate = properties.requestID ?? properties.requestId ?? properties.id;
  if (typeof candidate === "string") {
    return candidate.length > 0 ? candidate : undefined;
  }
  if (typeof candidate === "number" && Number.isFinite(candidate)) {
    return String(candidate);
  }
  return undefined;
}

/** 审批事件 → 上报字段。
 *
 *  两代事件都要兼容：v1 `permission.asked` 的工具名在 `permission`、匹配串在
 *  `patterns`；v2 `permission.v2.asked` 在 `action` / `resources`。取不到的字段一律
 *  留 undefined（与旧版上报形状一致，不写空串——空串会被应用当成真实工具名）。
 *
 *  @param {object} payload 事件 properties
 *  @returns {{tool?: string, tool_input?: object, tool_use_id?: string}} 上报字段
 */
function approvalEventFields(payload) {
  if (!payload || typeof payload !== "object") {
    return {};
  }
  const tool = typeof payload.permission === "string" ? payload.permission : payload.action;
  const patterns = Array.isArray(payload.patterns)
    ? payload.patterns
    : Array.isArray(payload.resources)
      ? payload.resources
      : [];
  const metadata =
    payload.metadata && typeof payload.metadata === "object" ? payload.metadata : {};
  const toolInput = { patterns, metadata };
  // 把匹配串摊成人一眼能看懂的目标（与参考实现同构）：bash 是命令，edit/write 是文件。
  if (tool === "bash" && patterns.length > 0) {
    toolInput.command = patterns.join(" && ");
  }
  if ((tool === "edit" || tool === "write") && patterns.length > 0) {
    toolInput.file_path = patterns[0];
  }
  const id = payload.id;
  return {
    tool: typeof tool === "string" && tool ? tool : undefined,
    tool_input: toolInput,
    tool_use_id: typeof id === "string" && id ? id : undefined,
  };
}

/** 审批上行信封：刘海据此登记一张待批卡片，并因为 `expects_response:true` 保留
 *  连接等我们回写决定。
 *
 *  `event`/`status`/`session_id`/`tool`/`cwd` 沿用旧字段；
 *  `expects_response`/`agent`/`tool_use_id` 是本次新增的三个字段。
 *
 *  @param {object} fields approvalEventFields 的结果
 *  @param {string} sessionId 会话 id
 *  @param {string} cwd 工作目录
 *  @returns {object} 上行信封
 */
function approvalPayload(fields, sessionId, cwd) {
  return {
    event: "ToolApproval",
    status: "waiting_for_approval",
    session_id: sessionId,
    cwd,
    pid,
    tty,
    agent: AGENT,
    expects_response: true,
    tool: fields && fields.tool,
    tool_input: fields && fields.tool_input,
    tool_use_id: fields && fields.tool_use_id,
  };
}

/** opencode 的 `QuestionInfo` → 应用 `ask` 载荷里的问题。
 *
 *  opencode 的问题**没有 id**（`{question, header, options, multiple?, custom?}`），
 *  而应用以 id 作键回传答案、opencode 以**问题顺序**收答，因此 id 用序号合成
 *  （`q0`…），回写时再按序还原。取不到的字段留 undefined（应用侧缺省即 false），
 *  与 omp/Claude 的信封形状保持一致。
 *
 *  @param {Array} questions 事件里的 questions
 *  @returns {Array} 应用 `ask` 载荷的 questions
 */
function askQuestionsFrom(questions) {
  if (!Array.isArray(questions)) {
    return [];
  }
  return questions.map((item, index) => {
    const question = item && typeof item === "object" ? item : {};
    const options = Array.isArray(question.options) ? question.options : [];
    return {
      id: `q${index}`,
      question: typeof question.question === "string" ? question.question : "",
      header:
        typeof question.header === "string" && question.header.length > 0
          ? question.header
          : undefined,
      multi_select: question.multiple === true,
      free_text: question.custom === true,
      options: options
        .filter((option) => option && typeof option.label === "string")
        .map((option) => ({
          label: option.label,
          description:
            typeof option.description === "string" ? option.description : undefined,
        })),
    };
  });
}

/** 提问事件 → 上报字段。
 *
 *  `tool_use_id` 取事件的 `id`（opencode 的 question id = reply/reject 路由里的
 *  requestID），与审批同一约定：应用按 (会话, tool_use_id) 登记那张卡，而「终端先
 *  答」的收手事件（`question.replied` / `question.rejected`）里也只有 requestID。
 *
 *  @param {object} payload 事件 properties
 *  @returns {{tool_use_id?: string, tool_input?: object, questions: Array}} 上报字段
 */
function askEventFields(payload) {
  if (!payload || typeof payload !== "object") {
    return { questions: [] };
  }
  const id = payload.id;
  return {
    tool_use_id: typeof id === "string" && id.length > 0 ? id : undefined,
    // 原始问题进 tool_input 只为人看得懂（卡片不用它），形状与 opencode 事件一致。
    tool_input: { questions: Array.isArray(payload.questions) ? payload.questions : [] },
    questions: askQuestionsFrom(payload.questions),
  };
}

/** 提问上行信封：与审批信封同构，只是多一个 `ask` 载荷（应用据此换成作答卡）。
 *
 *  @param {object} fields askEventFields 的结果
 *  @param {string} sessionId 会话 id
 *  @param {string} cwd 工作目录
 *  @returns {object} 上行信封
 */
function askPayload(fields, sessionId, cwd) {
  return {
    event: "ToolApproval",
    status: "waiting_for_approval",
    session_id: sessionId,
    cwd,
    pid,
    tty,
    agent: AGENT,
    expects_response: true,
    tool: TOOL_QUESTION,
    tool_input: fields && fields.tool_input,
    tool_use_id: fields && fields.tool_use_id,
    ask: { questions: (fields && fields.questions) || [] },
  };
}

/** 刘海下行决策 → opencode 的 reply body。
 *
 *  - `allow` → `{reply:"once"}`；
 *  - `deny`  → `{reply:"reject", message:<理由或兜底文案>}`；
 *  - 其它（含应用不可达/超时得到的 undefined、未知 decision）→ undefined，
 *    表示**不回写**，交给 opencode 原生 TUI 审批。
 *
 *  @param {object|undefined} response 刘海回传的 {decision, reason?}
 *  @returns {{reply: string, message?: string}|undefined} reply body
 */
function replyBodyFromDecision(response) {
  if (!response || typeof response !== "object") {
    return undefined;
  }
  if (response.decision === "allow") {
    return { reply: REPLY_ONCE };
  }
  if (response.decision === "deny") {
    const reason = typeof response.reason === "string" ? response.reason.trim() : "";
    return { reply: REPLY_REJECT, message: reason || DENY_FALLBACK_REASON };
  }
  return undefined;
}

/** 刘海作答 → opencode 的 reply body。
 *
 *  opencode 的 `QuestionAnswer` 是「数组的数组」，**顺序即问题顺序**（每个元素是
 *  该题选中的 label 列表）。应用回传的答案是「问题 id → 选中项」，因此这里按顺序
 *  还原。应用侧「键缺失 = 未作答」与「空数组 = 多选一个都没选」两种语义，在 opencode
 *  这边都表达为「该题没有选中项」（空数组）——它自己的提问工具也是这么收的。
 *
 *  只认 `answer`：其余决定返回 undefined，由调用方决定走哪条路由（`deny` → reject；
 *  `allow` / 未知取值 → 不回写）。
 *
 *  @param {Array} questions askEventFields 的问题集（顺序与 opencode 一致）
 *  @param {object|undefined} response 刘海回传的 {decision, answers?}
 *  @returns {{answers: string[][]}|undefined} reply body
 */
function questionReplyBody(questions, response) {
  if (!response || typeof response !== "object" || response.decision !== "answer") {
    return undefined;
  }
  const answers =
    response.answers && typeof response.answers === "object" ? response.answers : {};
  return {
    answers: (questions || []).map((question, index) => {
      const value = answers[question && question.id ? question.id : `q${index}`];
      return Array.isArray(value) ? value.filter((label) => typeof label === "string") : [];
    }),
  };
}

/** 回写路由模板：两代 opencode 的差异只在「v2 多了 sessionID 一层」，审批与提问
 *  各有自己的资源名（提问还有独立的 reject 路由，没有 body）。
 *  `{sessionID}` / `{requestID}` 由 `routeTarget` 填充。 */
const REPLY_ROUTES = {
  permissionReply: {
    v1: "/permission/{requestID}/reply",
    v2: "/api/session/{sessionID}/permission/{requestID}/reply",
  },
  questionReply: {
    v1: "/question/{requestID}/reply",
    v2: "/api/session/{sessionID}/question/{requestID}/reply",
  },
  questionReject: {
    v1: "/question/{requestID}/reject",
    v2: "/api/session/{sessionID}/question/{requestID}/reject",
  },
};

/** 回写地址。
 *
 *  @param {string} route REPLY_ROUTES 的键
 *  @param {string} version "v1" | "v2"
 *  @param {{requestId: string, sessionId: string, serverPort: number}} target 目标
 *  @returns {{heyApiUrl: string, heyApiPath: object, url: string}} 回写地址
 */
function routeTarget(route, version, target) {
  const port = Number(target && target.serverPort) > 0 ? Number(target && target.serverPort) : 4096;
  const requestId = encodeURIComponent((target && target.requestId) || "");
  const sessionId = encodeURIComponent((target && target.sessionId) || "");
  const routes = REPLY_ROUTES[route] || {};
  const template = routes[version === "v2" ? "v2" : "v1"] || "";
  return {
    heyApiUrl: template,
    heyApiPath:
      version === "v2"
        ? { sessionID: target && target.sessionId, requestID: target && target.requestId }
        : { requestID: target && target.requestId },
    url: `http://localhost:${port}${template
      .replace("{sessionID}", sessionId)
      .replace("{requestID}", requestId)}`,
  };
}

/** 审批回写地址（`reply:"once"|"reject"` 走同一个路由）。 */
function replyTarget(version, target) {
  return routeTarget("permissionReply", version, target);
}

/** 提问作答回写地址（body 为 `{answers}`）。 */
function questionReplyTarget(version, target) {
  return routeTarget("questionReply", version, target);
}

/** 提问放弃回写地址（无 body）。 */
function questionRejectTarget(version, target) {
  return routeTarget("questionReject", version, target);
}

/** 由宿主注入的 serverUrl 解析 opencode 本地端口（取不到时按 4096）。 */
function parseServerPort(serverUrl) {
  const port = Number(serverUrl && serverUrl.port);
  return Number.isInteger(port) && port > 0 ? port : 4096;
}

/** 决策等待时长：插件 options（opencode 配置里的 `[路径, options]`）> 环境变量 >
 *  缺省值。环境变量与 pi 系扩展同名同义（`AGENT_ISLAND_ASK_TIMEOUT_MS` 等），
 *  主要供离线 harness 把等待缩短；两侧都不能把预算填成 0 或负数。 */
function decisionBudget(options, key, envName, fallback) {
  const fromOptions = Number(options && options[key]);
  if (Number.isFinite(fromOptions) && fromOptions > 0) {
    return fromOptions;
  }
  const fromEnv = Number(process.env[envName]);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return fallback;
}

/** 审批决定的等待时长；缺省 120s。 */
function approvalTimeout(options) {
  return decisionBudget(
    options,
    "approvalTimeoutMs",
    "AGENT_ISLAND_GATE_TIMEOUT_MS",
    DEFAULT_DECISION_TIMEOUT_MS
  );
}

/** 作答的等待时长；缺省 240s。 */
function askTimeout(options) {
  return decisionBudget(
    options,
    "askTimeoutMs",
    "AGENT_ISLAND_ASK_TIMEOUT_MS",
    DEFAULT_ASK_TIMEOUT_MS
  );
}

/** 诊断日志：默认静默。
 *
 *  插件跑在 opencode 自己的进程里，默认往 stderr 打字会污染 TUI，因此故障路径
 *  沿用本文件既有的「静默失败」约定，只在 AGENT_ISLAND_DEBUG=1 时输出。 */
function debugLog(message) {
  if (process.env.AGENT_ISLAND_DEBUG === "1") {
    console.error(`[agent-island] ${message}`);
  }
}

/** 会话进入「有审批在飞」状态。 */
function beginApproval(sessionId) {
  pendingRequestSessions.set(sessionId, (pendingRequestSessions.get(sessionId) || 0) + 1);
}

/** 会话的一笔审批结束（计数归零才解除静音）。 */
function endApproval(sessionId) {
  const count = (pendingRequestSessions.get(sessionId) || 0) - 1;
  if (count > 0) {
    pendingRequestSessions.set(sessionId, count);
  } else {
    pendingRequestSessions.delete(sessionId);
  }
}

/** 记下某个 requestID 是我们用哪个会话登记 pending 的（登记 pending 时调用）。 */
function rememberApprovalSession(requestId, sessionId) {
  if (!requestId || !sessionId) {
    return;
  }
  // 先删后插：让它落到 Map 插入序的末尾，超限淘汰时先淘汰最久没被碰过的。
  approvalSessionByRequest.delete(requestId);
  approvalSessionByRequest.set(requestId, sessionId);
  while (approvalSessionByRequest.size > APPROVAL_SESSION_LIMIT) {
    const oldest = approvalSessionByRequest.keys().next().value;
    approvalSessionByRequest.delete(oldest);
  }
}

/** 取 requestID 对应的登记会话；没登记过则 undefined。
 *
 *  刻意**读而不删**：同一次审批可能被多条应答事件引用（重放/重试），删掉就会让后
 *  一条退回事件字段、重新失配。条目由容量上限兜底（新登记时淘汰最久未用的）。 */
function registeredApprovalSession(requestId) {
  if (!requestId) {
    return undefined;
  }
  return approvalSessionByRequest.get(requestId);
}

/** 向刘海发起一次阻塞询问，返回下行决策。**永不抛错**。
 *
 *  socket 纪律（docs/approval-multi-agent.md §5.2 的三条实测 E1/E2/E3）：
 *  1. `data`/`error`/`close` 必须**先于** `write()` 注册；
 *  2. 写完**不要 `end()`**（半关闭会让部分服务端丢掉应答，实测 E3 的负控）；
 *  3. 累积 `data` 直到 `JSON.parse` 成功（应答没有长度前缀，可能分片到达）；
 *  4. 拿到决策、超时或出错后一律 `destroy()`，否则 fd 泄漏；
 *  5. 任何异常都解析为 undefined = 让 opencode 原生 TUI 审批接管。
 *
 *  @param {object} payload 上行信封（含 expects_response:true）
 *  @param {number} [timeoutMs] 等待上限
 *  @returns {Promise<object|undefined>} 刘海回传的 {decision, reason?}
 */
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

    // ① 先注册监听，再 write。
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      try {
        const parsed = JSON.parse(buffer);
        finish(parsed && typeof parsed === "object" ? parsed : undefined);
      } catch {
        // 应答还没收齐：继续攒，等下一个 data 或超时。
      }
    });
    socket.on("error", () => finish(undefined));
    socket.on("close", () => finish(undefined));
    socket.setTimeout(budget, () => finish(undefined));

    socket.on("connect", () => {
      try {
        // ② 写完不 end()：保持连接，等刘海回写决策。
        socket.write(JSON.stringify(payload));
      } catch {
        finish(undefined);
      }
    });
  });
}

/** 把回写 body 交给 opencode。**永不抛错**。
 *
 *  优先走宿主注入的 SDK 客户端（`client._client`，@hey-api/client-fetch），失败
 *  回落到本地 HTTP。两层都失败就只留诊断日志：**不回写**，原生 TUI 接管。
 *
 *  @param {{heyApiUrl: string, heyApiPath: object, url: string}} target 回写地址
 *  @param {object|undefined} body 回写 body（reject 路由没有 body）
 *  @param {object} transport 回写通道（SDK 客户端 + 端口）
 *  @returns {Promise<boolean>} 是否回写成功
 */
async function postReply(target, body, transport) {
  const heyApi = transport && transport.heyApi;
  if (heyApi && typeof heyApi.request === "function") {
    try {
      await heyApi.request({
        method: "POST",
        url: target.heyApiUrl,
        path: target.heyApiPath,
        body,
      });
      return true;
    } catch {
      // 回落 fetch。
    }
  }
  try {
    await fetch(target.url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return true;
  } catch {
    return false;
  }
}

/** 把审批决策回写给 opencode。
 *
 *  @param {{requestId: string, sessionId: string, version: string, body: object,
 *           transport: object}} request 回写参数
 *  @returns {Promise<boolean>} 是否回写成功
 */
async function replyPermission(request) {
  const target = replyTarget(request.version, {
    requestId: request.requestId,
    sessionId: request.sessionId,
    serverPort: request.transport && request.transport.serverPort,
  });
  return postReply(target, request.body, request.transport);
}

/** 一次完整的远程审批：问刘海 → 按决策回写 opencode。
 *
 *  三条「不回写」的路径（与 Claude 链路的 fail-open 一致，交给原生 TUI 审批）：
 *  ① 应用不可达或超时（requestDecision 返回 undefined）；
 *  ② 决策不是 allow/deny；
 *  ③ 回写两层都失败。
 *  另外事件里连 `id`（= requestID）都取不到时无从回写，直接返回。
 *
 *  @param {{fields: object, sessionId: string, version: string, transport: object}} request
 *  @returns {Promise<void>} 永不 reject
 */
async function runApproval(request) {
  const requestId = request.fields && request.fields.tool_use_id;
  if (!requestId || !request.sessionId) {
    return;
  }
  beginApproval(request.sessionId);
  // 与「登记 pending」同一时刻记下会话归属：应用侧此刻才会认出这张卡。
  rememberApprovalSession(requestId, request.sessionId);
  let response;
  try {
    response = await requestDecision(
      approvalPayload(request.fields, request.sessionId, pluginCwd || process.cwd()),
      request.transport && request.transport.timeoutMs
    );
  } finally {
    endApproval(request.sessionId);
  }
  const body = replyBodyFromDecision(response);
  if (!body) {
    return;
  }
  const ok = await replyPermission({
    requestId,
    sessionId: request.sessionId,
    version: request.version,
    body,
    transport: request.transport,
  });
  if (!ok) {
    debugLog(`回写审批失败（requestID=${requestId}），改由 opencode 原生审批接管`);
  }
}

/** 一次完整的远程作答：问刘海 → 按决定回写 opencode（`answer` → reply，
 *  `deny` → reject）。
 *
 *  四条「不回写」的路径（与审批的 fail-open 一致，交给终端里的原生提问）：
 *  ① 事件里取不到 requestID / 会话 / 问题集；② 应用不可达或超时（决策为 undefined）；
 *  ③ 决定不是 `answer` / `deny`（含老应用回传的 `allow`——放行对提问没有意义）；
 *  ④ 回写两层都失败。
 *
 *  @param {{fields: object, sessionId: string, version: string, transport: object}} request
 *  @returns {Promise<void>} 永不 reject
 */
async function runAsk(request) {
  const requestId = request.fields && request.fields.tool_use_id;
  const questions = (request.fields && request.fields.questions) || [];
  if (!requestId || !request.sessionId || questions.length === 0) {
    return;
  }
  beginApproval(request.sessionId);
  // 与「登记 pending」同一时刻记下会话归属：应用侧此刻才会认出这张卡。
  rememberApprovalSession(requestId, request.sessionId);
  let response;
  try {
    response = await requestDecision(
      askPayload(request.fields, request.sessionId, pluginCwd || process.cwd()),
      request.transport && request.transport.askTimeoutMs
    );
  } finally {
    endApproval(request.sessionId);
  }
  if (!response || typeof response !== "object") {
    return;
  }
  const target = {
    requestId,
    sessionId: request.sessionId,
    serverPort: request.transport && request.transport.serverPort,
  };
  if (response.decision === "deny") {
    const ok = await postReply(
      questionRejectTarget(request.version, target),
      undefined,
      request.transport
    );
    if (!ok) {
      debugLog(`回写「放弃作答」失败（requestID=${requestId}），改由 opencode 原生提问接管`);
    }
    return;
  }
  const body = questionReplyBody(questions, response);
  if (!body) {
    return;
  }
  const ok = await postReply(questionReplyTarget(request.version, target), body, request.transport);
  if (!ok) {
    debugLog(`回写作答失败（requestID=${requestId}），改由 opencode 原生提问接管`);
  }
}

export const AgentIslandPlugin = async (input, options) => {
  if (pid === undefined) {
    pid = process.pid;
    tty = detectTty();
  }
  pluginCwd = (input && input.directory) || process.cwd();

  // 回写通道（宿主注入）：SDK 客户端优先，失败回落到本地 HTTP。
  const transport = {
    serverPort: parseServerPort(input && input.serverUrl),
    heyApi: input && input.client && input.client._client,
    timeoutMs: approvalTimeout(options),
    askTimeoutMs: askTimeout(options),
  };

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

    // 等待用户确认：**仅状态上报**。opencode 1.18.27 的运行期没有调用这个 hook
    // （类型与文档都在，但二进制内除文档串外没有调用点），所以决策不依赖它；
    // 真正的远程审批走下面的 event handler。
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

      // 审批事件优先处理并 return：它不能被下面的「挂起期静音」吃掉——同一个会话
      // 可能并发多笔审批（并行工具调用），静音只针对普通事件。
      if (type === "permission.asked" || type === "permission.v2.asked") {
        const version = type === "permission.v2.asked" ? "v2" : "v1";
        const fields = approvalEventFields(properties);
        // ① 先按旧行为把卡片打出来（fire-and-forget，走 send() 的串行链）。
        //    与下面的阻塞询问共用同一套身份字段，应用才能把两张卡认成同一张。
        await send({
          event: "ToolApproval",
          status: "waiting_for_approval",
          session_id: sessionId,
          tool: fields.tool,
          tool_input: fields.tool_input,
          tool_use_id: fields.tool_use_id,
        });
        // ② 再发起阻塞询问：新增的独立函数，不进 send() 的串行链，也不 await
        //    （否则会把事件总线堵在审批上）。决策与回写都在 runApproval 内部完成。
        void runApproval({ fields, sessionId, version, transport }).catch(() => {});
        return;
      }

      // 交互提问（`question`）走与审批同构的阻塞询问：上行带 `ask` 载荷，刘海作答
      // 后回写 `/question/{id}/reply|reject`。与审批同理，它不能被下面的「挂起期静音」
      // 吃掉，因此也在这里优先处理并 return。
      if (type === "question.asked" || type === "question.v2.asked") {
        const version = type === "question.v2.asked" ? "v2" : "v1";
        const fields = askEventFields(properties);
        if (fields.tool_use_id && fields.questions.length > 0) {
          // 不进 send() 的串行链、也不 await（否则会把事件总线堵在提问上）。
          // 这条阻塞信封自己就是「等待作答」的状态上报，卡片与相位都来自它。
          void runAsk({ fields, sessionId, version, transport }).catch(() => {});
          return;
        }
        // 身份或问题集取不到：退回旧行为（只上报状态，作答仍在终端）。此时带上工具名，
        // 应用会给出「去终端作答」的提示而不是一枚对提问毫无意义的批准按钮。
        await send({
          event: "ToolApproval",
          status: "waiting_for_approval",
          session_id: sessionId,
          tool: TOOL_QUESTION,
        });
        return;
      }

      // 该会话有审批挂起时，不再上报它的普通事件（避免刷屏）。生命周期事件与
      // 审批应答事件除外：前者维护会话行，后者是审批闭环本身。
      const exemptFromSuppression = SUPPRESSION_EXEMPT_EVENTS.has(type);
      if (
        sessionId &&
        pendingRequestSessions.has(sessionId) &&
        exemptFromSuppression === false
      ) {
        return;
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
        case "permission.replied":
        case "permission.v2.replied":
        case "question.replied":
        case "question.v2.replied":
        case "question.rejected":
        case "question.v2.rejected": {
          // 带上 requestID 的目的是「终端一动就收手」：应用侧靠它认出我们挂着的那张
          // 卡片并立刻关闭它的 socket，本文件的 requestDecision 随即收到 close →
          // 返回 undefined → 不 reply（终端既然已经决定，我们就不该再插一手）。
          // 六种应答事件（permission.replied / permission.v2.replied / question.replied /
          // question.v2.replied / question.rejected / question.v2.rejected）的 payload 里
          // 都有 requestID；取不到时字段自然缺席。
          const requestId = requestIdFrom(properties);
          // 会话归属以「登记 pending 时」为准：匹配键是
          // (agent, sessionId, toolUseId)，事件里的 sessionID 缺失或与登记时不同
          // 都会让应用侧找不到那张卡，收手就失效。
          // 三级兜底：登记时用的会话 → 事件里的 sessionID → 当前正在跟踪的根会话。
          // 最后一级不是可选项：send() 里 `...payload` 会用 payload.session_id 覆盖
          // 它自己算出的兜底值，带上 undefined 就会把 session_id 整段丢掉
          // （JSON.stringify 忽略 undefined），应用侧照样匹配不到。
          const replySessionId =
            registeredApprovalSession(requestId) || sessionId || reportedSessionId;
          if (replySessionId) {
            // send() 会按 reportedSessionId 过滤（子会话事件一律忽略），这里先对齐，
            // 否则「事件声称的会话」会把这条本该发出的收手通知拦掉。
            reportedSessionId = replySessionId;
          }
          await send({
            event: "PostToolUse",
            status: "processing",
            session_id: replySessionId,
            tool_use_id: requestId,
          });
          break;
        }
        case "session.deleted":
          await send({ event: "SessionEnd", status: "ended", session_id: sessionId });
          break;
        default:
          break;
      }
    },
  };
};

/** 内部入口：给离线 harness（/tmp/ai-approve/p2-probe）与调试脚本用。
 *
 *  刻意**不新增导出**，而是挂在唯一的导出函数上：opencode 1.18.27 的插件加载器
 *  要求模块里的**每一个导出都是函数**（实测：多一个对象导出会直接报
 *  `Plugin export is not a function` 并整份拒绝加载），所以内部件只能挂在函数上。
 *  插件对外形态（`AgentIslandPlugin` 仍是唯一导出、仍是函数）保持不变。
 *
 *  纯函数（可离线断言）：approvalEventFields / requestIdFrom / approvalPayload /
 *  replyBodyFromDecision / replyTarget / askEventFields / askQuestionsFrom /
 *  askPayload / questionReplyBody / questionReplyTarget / questionRejectTarget /
 *  routeTarget；
 *  带 I/O 的：requestDecision / replyPermission / runApproval / postReply /
 *  respondToQuestion（= runAsk）；
 *  状态：pendingRequestSessions（在飞审批的会话 → 笔数）、
 *  approvalSessionByRequest（requestID → 登记时的会话）。
 */
AgentIslandPlugin.internals = {
  approvalEventFields,
  requestIdFrom,
  rememberApprovalSession,
  registeredApprovalSession,
  approvalSessionByRequest,
  approvalPayload,
  replyBodyFromDecision,
  replyTarget,
  requestDecision,
  replyPermission,
  runApproval,
  pendingRequestSessions,
  askEventFields,
  askQuestionsFrom,
  askPayload,
  questionReplyBody,
  questionReplyTarget,
  questionRejectTarget,
  routeTarget,
  postReply,
  approvalTimeout,
  askTimeout,
  respondToQuestion: runAsk,
};
