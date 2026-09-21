//
//  HookSocketServer.swift
//  AgentIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Hooks")


/// Event received from an agent's live integration (Claude Code hooks, pi/omp
/// extension, OpenCode plugin).
nonisolated struct HookEvent: Codable, Sendable {
 /// 集成侧判定「命中危险命令名单」的档位取值（`approval_kind`）；只影响刘海展示强度。
 private static let criticalApprovalKind = "critical"
 /// 集成侧的默认降级档；不是这一档就要在卡片上提示「闸门已降级」。
 private static let defaultDegradationTier = "notify-only"
 /// 会话身份三件套与 `toolUseId` 一样是 `var`：三处「复制并改写」的入口
 /// （`withToolUseId` / `withLivePending` / `owning`）都靠副本语义保真，不再走全参重建。
 var sessionId: String
 let cwd: String
 let event: String
 let status: String
 let pid: Int?
 let tty: String?
 let tool: String?
 let toolInput: [String: AnyCodable]?
 /// 工具调用 id；`var` 只为 `withToolUseId(_:)` 的副本语义（见 `sessionId` 的说明）。
 var toolUseId: String?
 let notificationType: String?
 let message: String?
 /// 集成是否要求应用回传决定（`expects_response`）。缺省 nil = 只展示，不登记待批。
 let wantsResponse: Bool?
 /// 集成侧判定的审批档位（`allow|write|exec|critical`）；只影响展示强度，缺省 nil = 老集成。
 let approvalKind: String?
 /// 集成侧烘焙的降级档（`notify-only` / `strict` / `read-only-allow`）。
 let degradation: String?
 /// 集成侧闸门是否启用；显式 false 说明「应用不在时按降级档放行」这件事发生过。
 let gateEnabled: Bool?
 /// 集成侧上报「这次审批由 Agent 自己的终端弹窗负责」（`omp_owns_approval`）。
 let ompOwnsApproval: Bool?
 /// 集成侧 `ask` 工具的问题负载（`ask`）；其它工具有待批时该字段缺省。
 let ask: AskPayload?
 /// 上报方所属 Agent；旧版 Claude hook 脚本不带该字段，按 Claude 处理。
 var agent: String?
 /// 记录文件路径，由非 Claude 集成上报，避免应用再按目录反推。
 let sessionFile: String?
 /// 子 Agent 实例标识（omp 的 job 名，如 `EchoAlpha`）。
 let subagentId: String?
 /// 子 Agent 类型名（omp 的 agent 名，如 `scout` / `sonic`）。
 let subagentAgent: String?
 /// 子 Agent 状态：`started` / `running` / `completed` / `failed` / `aborted`。
 let subagentStatus: String?
 /// 子 Agent 当前正在执行的工具名；空闲时为空。
 let subagentCurrentTool: String?
 /// 子 Agent 的任务描述（`SubagentLifecycle` 带 `description`，进度事件带 `task`）。
 let subagentTask: String?
 /// 派生该子 Agent 的父会话工具调用（task 工具的 tool_use_id）。
 var parentToolCallId: String?
 /// 子 Agent 自己的记录文件路径。
 let subagentSessionFile: String?

 enum CodingKeys: String, CodingKey {
  case sessionId = "session_id"
  case cwd, event, status, pid, tty, tool
  case toolInput = "tool_input"
  case toolUseId = "tool_use_id"
  case notificationType = "notification_type"
  case message, agent
 case wantsResponse = "expects_response"
 case approvalKind = "approval_kind"
 case degradation
 case gateEnabled = "gate_enabled"
 case ompOwnsApproval = "omp_owns_approval"
 case ask
  case sessionFile = "session_file"
  case subagentId = "subagent_id"
  case subagentAgent = "subagent_agent"
  case subagentStatus = "subagent_status"
  case subagentCurrentTool = "subagent_current_tool"
  case subagentTask = "subagent_task"
  case parentToolCallId = "parent_tool_call_id"
  case subagentSessionFile = "subagent_session_file"
 }

 /// 事件所属 Agent（缺省视为 Claude Code，兼容已安装的旧 hook 脚本）。
 var agentKind: AgentKind {
  guard let agent, let kind = AgentKind(rawValue: agent) else { return .claudeCode }
  return kind
 }

 /// 会话键：Agent + 会话 id。
 var sessionKey: SessionKey {
  SessionKey(agent: agentKind, sessionId: sessionId)
 }

 /// Create a copy with updated toolUseId
 init(
  sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?,
  tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?,
  message: String?, agent: String? = nil, sessionFile: String? = nil
 ) {
  self.init(
   sessionId: sessionId, cwd: cwd, event: event, status: status, pid: pid, tty: tty,
   tool: tool, toolInput: toolInput, toolUseId: toolUseId, notificationType: notificationType,
   message: message, agent: agent, sessionFile: sessionFile,
   subagentId: nil, subagentAgent: nil, subagentStatus: nil, subagentCurrentTool: nil,
   subagentTask: nil, parentToolCallId: nil, subagentSessionFile: nil
  )
 }

 init(
  sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?,
  tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?,
  message: String?, agent: String?, sessionFile: String?, subagentId: String?,
  subagentAgent: String?, subagentStatus: String?, subagentCurrentTool: String?,
  subagentTask: String?, parentToolCallId: String?, subagentSessionFile: String?,
  wantsResponse: Bool? = nil,
  approvalKind: String? = nil, degradation: String? = nil, gateEnabled: Bool? = nil,
  ompOwnsApproval: Bool? = nil, ask: AskPayload? = nil
 ) {
  self.sessionId = sessionId
  self.cwd = cwd
  self.event = event
  self.status = status
  self.pid = pid
  self.tty = tty
  self.tool = tool
  self.toolInput = toolInput
  self.toolUseId = toolUseId
  self.notificationType = notificationType
  self.message = message
  self.agent = agent
  self.sessionFile = sessionFile
  self.subagentId = subagentId
  self.subagentAgent = subagentAgent
  self.subagentStatus = subagentStatus
  self.subagentCurrentTool = subagentCurrentTool
  self.subagentTask = subagentTask
  self.parentToolCallId = parentToolCallId
  self.subagentSessionFile = subagentSessionFile
  self.wantsResponse = wantsResponse
  self.approvalKind = approvalKind
  self.degradation = degradation
  self.gateEnabled = gateEnabled
  self.ompOwnsApproval = ompOwnsApproval
  self.ask = ask
 }

 /// 是否为子代理总线事件（omp/pi 的 `task:subagent:*` 上报，不是会话自身的一轮活动）。
 nonisolated var isSubagentBusEvent: Bool {
  event == "SubagentLifecycle" || event == "SubagentProgress"
 }

 /// 复制一份事件，改写到另一个会话、并指定它应挂靠的父工具调用。
 ///
 /// 子代理实例上报的是「它自己派出的子代理」，事件里的 `parent_tool_call_id` 指向上一层
 /// 会话里的工具调用（本应用没有那张卡片），因此折算落点时统一改成「上报者所属卡片」。
 ///
 /// **用复制语义而不是全参重建**（评审 F2）：重建会把没列进参数的字段静默丢成默认值——
 /// 其中就有进程内的 `hasLivePending`（子代理进度事件因此又能把相位推回 `processing`，
 /// 正是本次要修的症状）以及 `expects_response` / `ask` 这类信封字段。
 nonisolated func owning(sessionKey: SessionKey, parentToolCallId: String?) -> HookEvent {
  var copy = self
  copy.sessionId = sessionKey.sessionId
  copy.agent = sessionKey.agent.rawValue
  copy.parentToolCallId = parentToolCallId ?? copy.parentToolCallId
  return copy
 }

 /// 复制事件并只替换 `toolUseId`，其余字段（含 `agent` / `sessionFile` / 子 Agent
 /// 归属）原样保留。不要用便利 init 重建：那会把 agent 与子 Agent 字段重置为 nil，
 /// 使排队中的审批被重建成 Claude 会话（幽灵会话 + 真实会话卡在等待批准）。
 func withToolUseId(_ toolUseId: String) -> HookEvent {
  var copy = self
  copy.toolUseId = toolUseId
  return copy
 }

 var sessionPhase: SessionPhase {
  if event == "PreCompact" {
   return .compacting
  }

  switch status {
  case "waiting_for_approval":
   // Note: Full PermissionContext is constructed by SessionStore, not here
   // This is just for quick phase checks
   return .waitingForApproval(
    PermissionContext(
     toolUseId: toolUseId ?? "",
     toolName: tool ?? "unknown",
     toolInput: toolInput,
     receivedAt: Date()
    ))
  case "waiting_for_input":
   return .waitingForInput
  case "running_tool", "processing", "starting":
   return .processing
  case "compacting":
   return .compacting
  default:
   return .idle
  }
 }

 /// Whether this event expects a response (permission request)
 /// 该事件是否要求应用回传决定。
 /// - Claude 旧契约：`PermissionRequest` + `waiting_for_approval`（逐字不变）。
 /// - omp / pi / opencode：`ToolApproval` + **等待态** + 显式 `expects_response`；
 ///   只展示的集成（`expects_response: false` / 缺省）不满足该条件，因此不会被
 ///   登记成待批。
 ///
 /// 三个条件都要。只认 `expects_response` 时，一条 `status != waiting_for_approval`
 /// 的信封也会被登记成待批——那条连接的卡片与相位来源（`determinePhase` 的
 /// `ToolApproval` 兜底分支）不是同一判据，长期看会漂移成「登记了但没人能撤」的
 /// 悬挂连接。集成侧三处带 `expects_response: true` 的信封（闸门 `pi-extension:1230`、
 /// 影子 ask `:1557`、opencode 插件 `:234`）status 都是 `waiting_for_approval`，
 /// 因此收紧不影响任何既有集成；真收到不合规信封时的降级是**立即关闭 fd**，
 /// 集成侧按「拿不到决定」回落自己的原生路径（不会挂住）。
 nonisolated var expectsResponse: Bool {
  if event == "PermissionRequest" && status == "waiting_for_approval" { return true }
  return event == "ToolApproval" && status == "waiting_for_approval" && wantsResponse == true
 }

 /// 交付这一条事件时，该会话**是否正有待批在等**。
 ///
 /// 由 `HookSocketServer` 在交给事件处理者之前盖章：待批是已经发生的事实（服务端还攥着
 /// 那条等应答的连接），状态上报只是描述。相位机据此把「等待审批」钉住（见
 /// `SessionStore.processHookEvent`）。**不是线上字段**：不进 `CodingKeys`，只在进程内传递。
 var hasLivePending = false

 /// 复制一份并盖上「该会话此刻有待批在等」的章。
 func withLivePending(_ value: Bool) -> HookEvent {
  var copy = self
  copy.hasLivePending = value
  return copy
 }

 /// 是否为「危险命令」档：卡片据此用警示色；未知档位一律按普通档处理。
 nonisolated var isCriticalApproval: Bool {
  approvalKind == Self.criticalApprovalKind
 }

 /// 是否要在卡片上提示「闸门已降级」：闸门未启用，或降级档不是默认档。
 nonisolated var isGateDegraded: Bool {
  if gateEnabled == false { return true }
  guard let degradation else { return false }
  return degradation != Self.defaultDegradationTier
 }
}

// MARK: - Ask 负载（交互式提问）

/// `ask` 工具给出的一个选项。
nonisolated struct AskOption: Codable, Equatable, Sendable {
 /// 选项文本；用户选中的就是这个文本，回传时原样带回。
 let label: String
 /// 选项的补充说明（副标题）。
 let description: String?

 init(label: String, description: String? = nil) {
  self.label = label
  self.description = description
 }
}

/// `ask` 工具提出的一个问题。
nonisolated struct AskQuestion: Codable, Equatable, Sendable {
 /// 问题 id；作答字典的键就是它。
 let id: String
 /// 问题正文。
 let question: String
 /// 问题的短标题（可缺省）。
 let header: String?
 /// 是否多选；缺省按单选。
 let multiSelect: Bool
 /// 是否允许自由文本作答（可缺省）。
 let freeText: Bool
 /// 候选选项；空数组表示只能自由文本作答。
 let options: [AskOption]

 init(
  id: String, question: String, header: String? = nil, multiSelect: Bool = false,
  freeText: Bool = false, options: [AskOption] = []
 ) {
  self.id = id
  self.question = question
  self.header = header
  self.multiSelect = multiSelect
  self.freeText = freeText
  self.options = options
 }

 /// 载荷里这两个开关可能缺省，按 false 处理；选项缺省按空数组。
 private enum CodingKeys: String, CodingKey {
  case id, question, header
  case multiSelect = "multi_select"
  case freeText = "free_text"
  case options
 }

 init(from decoder: Decoder) throws {
  let container = try decoder.container(keyedBy: CodingKeys.self)
  id = try container.decode(String.self, forKey: .id)
  question = try container.decode(String.self, forKey: .question)
  header = try container.decodeIfPresent(String.self, forKey: .header)
  multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
  freeText = try container.decodeIfPresent(Bool.self, forKey: .freeText) ?? false
  options = try container.decodeIfPresent([AskOption].self, forKey: .options) ?? []
 }
}

/// `ask` 工具的完整问题集（信封里的 `ask` 字段）。
nonisolated struct AskPayload: Codable, Equatable, Sendable {
 let questions: [AskQuestion]
}

/// Response to send back to the hook
nonisolated struct HookResponse: Codable {
 /// `allow` / `deny` / `ask` 三个取值的语义逐字不变；`answer` 是 `ask` 工具的回答。
 let decision: String
 /// 提问作答（`decision == "answer"`）：键为问题 id，值为选中的 label 或自由文本。
 /// 其余决定一律为 nil。
 let answers: [String: [String]]?
 let reason: String?

 private enum CodingKeys: String, CodingKey {
  case decision, answers, reason
 }

 /// 手写编码而不是用合成的：它写死了「哪些键会出现」这条契约——缺省的字段一律不
 /// 出现在字节里（因此 `allow` / `deny` / `ask` 的字段集合与加 `answers` 之前相同），
 /// 也是消融实验唯一需要改的一行。键的**顺序**不在这里决定，由写回时用的
 /// `sortedKeys` 编码器保证（见 `responseEncoder`）。
 /// - Parameter encoder: 目标编码器。
 func encode(to encoder: Encoder) throws {
  var container = encoder.container(keyedBy: CodingKeys.self)
  try container.encode(decision, forKey: .decision)
  try container.encodeIfPresent(answers, forKey: .answers)
  try container.encodeIfPresent(reason, forKey: .reason)
 }
}

// MARK: - 作答决定

/// 把用户在刘海上做出的选择折成回传决定。纯函数、无状态，因此「选择 → 答案 JSON」
/// 这一段可以脱离 UI 独立验证。
nonisolated enum AskAnswerBuilder {
 /// 集成侧据此把答案交给模型继续。
 static let decisionAnswer = "answer"
 /// 用户放弃作答：沿用既有 deny 语义，Agent 按「拒绝/未作答」继续。
 static let decisionDeny = "deny"

 /// 归一化一个回传决定：`allow` / `deny` / `ask` **原样透传**（既有语义逐字不变，
 /// 编码结果里不会多出 `answers` 键）；`answer` 且**一个键都没有**时折成 `deny`。
 /// 放在服务端这一层是为了让「整题都没答」不可能以 `answer` 发出去——写回 socket 前必过这里。
 /// 注意「值为空数组」不是「没答」：那是多选题的「明确一个都不选」，要原样发出（见 `response`）。
 static func normalized(
  decision: String, answers: [String: [String]]?, reason: String?
 ) -> HookResponse {
  guard decision == decisionAnswer else {
   return HookResponse(decision: decision, answers: nil, reason: reason)
  }
  return response(answers: answers ?? [:], reason: reason)
 }

 /// 由「问题 id → 答案」构造回传响应。
 ///
 /// **不变量（与集成侧冻结的语义，逐条对应）**：
 /// * **键存在** = 该题被作答；
 /// * **值为空数组** = 多选题的「明确一个都不选」，必须**原样**带着走；
 /// * **键缺失** = 该题未作答。
 /// 因此这里**不再过滤空数组**：把空数组当「没答」会让「明确不选」退化成「缺键」，
 /// 集成侧就再也区分不出这两件事了。
 ///
 /// 只有**所有键都缺失**（字典为空：用户直接跳过，或自由文本只输了空白）时才不发
 /// `answer`——那才是「放弃作答」，折成 `deny` 更接近用户意图，也让集成侧的闸门走
 /// 既有的拒绝分支。
 static func response(answers: [String: [String]], reason: String? = nil) -> HookResponse {
  guard !answers.isEmpty else {
   return HookResponse(decision: decisionDeny, answers: nil, reason: reason)
  }
  return HookResponse(decision: decisionAnswer, answers: answers, reason: reason)
 }
}

/// 待批许可的字典键：会话（Agent + 会话 id）+ 会话内的工具调用 id。
/// 只用裸 `toolUseId` 当键会让不同 Agent / 会话的同名 id 互相覆盖或误关。
struct PendingPermissionKey: Hashable {
 let key: SessionKey
 let toolUseId: String
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
 /// 该许可所属的会话；日志与失败回调都按它归属。
 let key: SessionKey
 let toolUseId: String
 let clientSocket: Int32
 let event: HookEvent
 let receivedAt: Date
}

/// 待批卡片要用的展示档位。全部取自集成上报的信封；缺省表示老集成没报，
/// 卡片按「普通档 + 闸门正常」渲染。
struct PendingApprovalDisplay: Equatable, Sendable {
 /// 危险命令档 → 卡片用警示色。
 let isCritical: Bool
 /// 需要在卡片上提示「闸门已降级」。
 let isGateDegraded: Bool
 /// 要展示的降级档名；`nil` = 集成没报档位。
 let degradedTier: String?
 /// 这次审批由 Agent 自己的终端弹窗负责（让位信号）。
 let terminalIsAsking: Bool

 init(event: HookEvent) {
  isCritical = event.isCriticalApproval
  isGateDegraded = event.isGateDegraded
  degradedTier = event.degradation
  terminalIsAsking = event.ompOwnsApproval == true
 }
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (SessionKey, String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
 static let shared = HookSocketServer()
 static let socketPath = "/tmp/agent-island.sock"

 /// 本进程是否赢得了这条 socket 的归属（`bind` 成功才算）。败者不启动服务。
 /// 见 `startServer()` 的 bind 分支：这条 socket 是**单实例资源**，跑测试的宿主进程
 /// 绝不能把它抢走。
 private var ownsListener = false

 private var serverSocket: Int32 = -1
 private var acceptSource: DispatchSourceRead?
 private var eventHandler: HookEventHandler?
 private var permissionFailureHandler: PermissionFailureHandler?
 private let queue = DispatchQueue(label: "com.celestial.AgentIsland.socket", qos: .userInitiated)

 /// Pending permission requests indexed by (会话, toolUseId)
 private var pendingPermissions: [PendingPermissionKey: PendingPermission] = [:]
 private let permissionsLock = NSLock()

 /// 仍被服务端持有的客户端连接数；只在 `queue` 上读写（并发观测用）
 private var openClientCount = 0

 /// 待批许可的存活上限：超时视为「问了没人答」，关闭 fd 并走失败回调。
 ///
 /// **不变量：本值必须大于集成侧最长的客户端等待预算**，否则应用会先收割，卡片凭空
 /// 消失、作答无门。集成侧目前有两处预算：
 /// * 工具审批闸门：等用户点击 120s（`AGENT_ISLAND_*_TOOL_TIMEOUT_MS`）；
 /// * `ask` 作答：240s（`AGENT_ISLAND_ASK_TIMEOUT_MS` 缺省 240s；超时后集成侧不撤
 ///   终端里的提问，转而等 Agent 原生弹窗）。
 /// 取 330s（> 300s，留 30s 余量）；四层链条必须严格递减：
 /// app pending TTL 330s > omp 服务端 toolCallTimeoutMs 300s > ask 客户端 240s > 闸门客户端 120s。
 /// 闸门那条路径不受本值影响：它靠工具结束时的
 /// `PostToolUse` / `PostToolUseFailure` 撤卡，不依赖 TTL。
 /// 环境变量 `AGENT_ISLAND_PENDING_TTL_SECONDS` 可覆盖（验证用钩子）。
 private let pendingTTL: TimeInterval = {
  // 项目内自有 `ProcessInfo`（进程树）会遮蔽 Foundation 的同名类型，故显式限定
  guard let raw = Foundation.ProcessInfo.processInfo.environment["AGENT_ISLAND_PENDING_TTL_SECONDS"],
   let seconds = TimeInterval(raw), seconds > 0
  else { return 330 }
  return seconds
 }()

 /// 待批许可的 TTL 收割器（`stop()` 时取消）
 private var reaperTimer: DispatchSourceTimer?

 /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
 /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
 /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
 private var toolUseIdCache: [String: [String]] = [:]
 private let cacheLock = NSLock()

 private init() {}

 /// Start the socket server
 func start(
  onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil
 ) {
  queue.async { [weak self] in
   self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
  }
 }

 private func startServer(
  onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?
 ) {
  guard serverSocket < 0 else { return }

  // 测试宿主**绝不**绑这条 socket：它和真实应用共用同一个路径，unlink + rebind 会把用户
  // 正在用的那条连接面整条抢过来，让「闸门请求送不到任何人手里」——集成侧只会等到客户端
  // 预算耗尽，然后被静默拒绝（实测：`xcodebuild test` 的宿主就干过这件事）。
  guard !AppEnvironment.isRunningTests else {
   logger.info("Skipping hook socket server (running in a test host)")
   return
  }

  eventHandler = onEvent
  permissionFailureHandler = onPermissionFailure

  serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
  guard serverSocket >= 0 else {
   logger.error("Failed to create socket: \(errno)")
   return
  }

  let flags = fcntl(serverSocket, F_GETFL)
  _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  Self.socketPath.withCString { ptr in
   withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
    let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
     .assumingMemoryBound(to: CChar.self)
    strcpy(pathBufferPtr, ptr)
   }
  }

  var bindResult = withUnsafePointer(to: &addr) { ptr in
   ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
    bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }

  // 先绑、后清（评审 F5）：无条件 `unlink` + `bind` 会留下「探活 → unlink → bind」的竞态
  // 窗口——两份实例同时启动时，后者能把前者刚绑好的 dentry 删掉，路径指向后者，而前者
  // 自认持有监听却已不可达，退出时还会把后者的路径摘掉。
  if bindResult != 0, errno == EADDRINUSE {
   // 路径被占：有活着的监听者就不抢（这正是「测试宿主/第二实例静默夺走连接面」的根因），
   // 只是上次崩溃留下的死 socket 才清掉重绑。
   if Self.listenerIsAlive(at: Self.socketPath) {
    logger.error(
     "Another AgentIsland instance already listens on \(Self.socketPath, privacy: .public); this instance will not rebind it (a relaunch is needed to take over)"
    )
    close(serverSocket)
    serverSocket = -1
    return
   }
   unlink(Self.socketPath)
   bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
     bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
   }
  }

  guard bindResult == 0 else {
   logger.error("Failed to bind socket: \(errno)")
   close(serverSocket)
   serverSocket = -1
   return
  }

  ownsListener = true

  chmod(Self.socketPath, 0o600)

  guard listen(serverSocket, 32) == 0 else {
   logger.error("Failed to listen: \(errno)")
   close(serverSocket)
   serverSocket = -1
   return
  }

  logger.info("Listening on \(Self.socketPath, privacy: .public)")

  acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
  acceptSource?.setEventHandler { [weak self] in
   self?.acceptConnection()
  }
  acceptSource?.setCancelHandler { [weak self] in
   if let fd = self?.serverSocket, fd >= 0 {
    close(fd)
    self?.serverSocket = -1
   }
  }
  acceptSource?.resume()

  startReaperTimer()
 }

 /// Stop the socket server
 ///
 /// 只撤自己那份：**没赢过 bind 的进程不许 unlink**，否则会把正主儿正在服务的 socket 文件
 /// 摘掉，正主儿此后收不到任何连接，而路径看起来又是「存在但没人应答」。
 func stop() {
  acceptSource?.cancel()
  acceptSource = nil

  if ownsListener {
   unlink(Self.socketPath)
   ownsListener = false
  }

  reaperTimer?.cancel()
  reaperTimer = nil

  permissionsLock.lock()
  let cancelled = pendingPermissions.values
  pendingPermissions.removeAll()
  permissionsLock.unlock()

  for pending in cancelled {
   closeClient(pending.clientSocket)
  }
 }

 /// Respond to a pending permission request by (会话, toolUseId)
 ///
 /// `answers` 只为 `ask` 工具的作答（`decision == "answer"`）提供；其余决定传 nil，
 /// 编码结果里就不会出现 `answers` 键，老信封的字节形态逐字不变。
 func respondToPermission(
  key: SessionKey, toolUseId: String, decision: String, answers: [String: [String]]? = nil,
  reason: String? = nil
 ) {
  queue.async { [weak self] in
   self?.sendPermissionResponse(
    key: key, toolUseId: toolUseId, decision: decision, answers: answers, reason: reason)
  }
 }

 /// Respond to permission by session (finds the most recent pending for that session)
 func respondToPermissionBySession(key: SessionKey, decision: String, reason: String? = nil) {
  queue.async { [weak self] in
   self?.sendPermissionResponseBySession(key: key, decision: decision, reason: reason)
  }
 }

 /// Cancel all pending permissions for a session (when the agent stops waiting)
 func cancelPendingPermissions(key: SessionKey) {
  queue.async { [weak self] in
   self?.cleanupPendingPermissions(key: key)
  }
 }

 /// Check if there's a pending permission request for a session
 func hasPendingPermission(key: SessionKey) -> Bool {
  permissionsLock.lock()
  defer { permissionsLock.unlock() }
  return pendingPermissions.values.contains { $0.key == key }
 }

 /// Get the pending permission details for a session (if any)
 func getPendingPermission(key: SessionKey) -> (
  toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?
 )? {
  permissionsLock.lock()
  defer { permissionsLock.unlock() }
  guard let pending = pendingPermissions.values.first(where: { $0.key == key }) else {
   return nil
  }
  return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
 }

 /// 待批卡片的展示档位（危险命令 / 闸门降级 / 让位）；该会话没有待批时返回 nil。
 func pendingApprovalDisplay(key: SessionKey) -> PendingApprovalDisplay? {
  permissionsLock.lock()
  defer { permissionsLock.unlock() }
  guard let pending = pendingPermissions.values.first(where: { $0.key == key }) else {
   return nil
  }
  return PendingApprovalDisplay(event: pending.event)
 }

 /// 该会话待批的工具若带 `ask` 负载，返回它的问题集；其余情况（无待批、或待批
 /// 工具没有提问负载）返回 nil。视图在「每次会话发布都重查」的既有路径里取用，
 /// 不另开轮询。
 func pendingAsk(key: SessionKey) -> AskPayload? {
  permissionsLock.lock()
  defer { permissionsLock.unlock() }
  guard let pending = pendingPermissions.values.first(where: { $0.key == key }) else {
   return nil
  }
  return pending.event.ask
 }

 /// Cancel a specific pending permission by (会话, toolUseId)：终端里自己批了 / 工具已完成
 func cancelPendingPermission(key: SessionKey, toolUseId: String) {
  queue.async { [weak self] in
   self?.cleanupSpecificPermission(key: key, toolUseId: toolUseId)
  }
 }

 private func cleanupSpecificPermission(key: SessionKey, toolUseId: String) {
  let pendingKey = PendingPermissionKey(key: key, toolUseId: toolUseId)
  permissionsLock.lock()
  guard let pending = pendingPermissions.removeValue(forKey: pendingKey) else {
   permissionsLock.unlock()
   return
  }
  permissionsLock.unlock()

  logger.debug(
   "Tool completed externally, closing socket for \(key.sessionId.prefix(8), privacy: .public) agent:\(key.agent.rawValue, privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)"
  )
  closeClient(pending.clientSocket)
 }

 private func cleanupPendingPermissions(key: SessionKey) {
  permissionsLock.lock()
  let matching = pendingPermissions.filter { $0.key.key == key }
  let removed = matching.map { $0.key }
  for pendingKey in removed {
   pendingPermissions.removeValue(forKey: pendingKey)
  }
  permissionsLock.unlock()

  for (pendingKey, pending) in matching {
   logger.debug(
    "Cleaning up stale permission for \(key.sessionId.prefix(8), privacy: .public) agent:\(key.agent.rawValue, privacy: .public) tool:\(pendingKey.toolUseId.prefix(12), privacy: .public)"
   )
   closeClient(pending.clientSocket)
  }
 }

 // MARK: - Pending Permission Reaper

 /// 这条路径上是否已有活着的监听者。
 ///
 /// 判据是**连一下**而不是看文件是否存在：上次崩溃会留下一个死 socket 文件，那种情况必须
 /// 允许接管。探针自身带 50ms 上限（非阻塞 + `poll`）：它在串行 socket 队列上同步调用，
 /// 不能因为对端 accept backlog 排满而把整条集成面挂住（评审 F6）。
 private static func listenerIsAlive(at path: String) -> Bool {
  let probe = socket(AF_UNIX, SOCK_STREAM, 0)
  guard probe >= 0 else { return false }
  defer { close(probe) }

  let flags = fcntl(probe, F_GETFL)
  _ = fcntl(probe, F_SETFL, flags | O_NONBLOCK)

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  path.withCString { ptr in
   _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
    strcpy(
     UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), ptr)
   }
  }
  let result = withUnsafePointer(to: &addr) { ptr in
   ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
    connect(probe, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }
  if result == 0 { return true }
  guard errno == EINPROGRESS else { return false }

  var descriptor = pollfd(fd: probe, events: Int16(POLLOUT), revents: 0)
  guard poll(&descriptor, 1, 50) > 0 else { return false }
  var error: Int32 = 0
  var length = socklen_t(MemoryLayout<Int32>.size)
  guard getsockopt(probe, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
  return error == 0
 }

 /// 关闭客户端连接并维护连接计数（只在 `queue` 上调用）
 private func closeClient(_ fd: Int32) {
  openClientCount = max(0, openClientCount - 1)
  close(fd)
 }

 /// 当前待批许可数与持有的连接数。只在 `queue` 上调用（两者的写都发生在该串行队列上）。
 private var pendingStats: (pending: Int, open: Int) {
  (pendingPermissions.count, openClientCount)
 }

 /// 启动 TTL 收割器：以 min(5s, TTL/3) 为间隔扫描超时未决的许可
 private func startReaperTimer() {
  guard reaperTimer == nil else { return }
  let interval = max(1.0, min(5.0, pendingTTL / 3))
  let timer = DispatchSource.makeTimerSource(queue: queue)
  timer.schedule(deadline: .now() + interval, repeating: interval)
  timer.setEventHandler { [weak self] in
   self?.reapExpiredPending()
  }
  timer.resume()
  reaperTimer = timer
  // 用 info 而不是 debug：TTL 是与集成侧预算对齐的策略值（见 pendingTTL 的不变量），
  // 必须在持久化的统一日志里可查——上一次「TTL 小于集成侧等待预算」的错配就是因为
  // 这个值在运行的机器上读不到。
  logger.info(
   "Pending permission reaper started (TTL: \(String(format: "%.1f", self.pendingTTL), privacy: .public)s)"
  )
 }

 /// 收割超时未决的许可：关闭 fd、移除条目，并通过失败回调让会话离开等待态。
 private func reapExpiredPending() {
  let now = Date()
  permissionsLock.lock()
  let expired = pendingPermissions.filter { now.timeIntervalSince($0.value.receivedAt) > pendingTTL }
  for pendingKey in expired.keys {
   pendingPermissions.removeValue(forKey: pendingKey)
  }
  permissionsLock.unlock()

  let seconds = String(format: "%.1f", self.pendingTTL)
  for (pendingKey, pending) in expired {
   // 收割 = 「问了没人答」。给集成一条**显式拒绝**再关连接：原来只关 fd，集成侧只能报
   // 「AgentIsland is no longer available」——与应用真的崩了/退出了不可区分，排查时会把
   // 方向带偏到「版本错配 / 进程死了」（实测踩到）。理由原文也会回灌给模型。
   let reason = "No decision on AgentIsland within \(seconds)s — denied."
   logger.warning(
    "Reaped pending permission after \(seconds, privacy: .public)s - agent:\(pendingKey.key.agent.rawValue, privacy: .public) session:\(pendingKey.key.sessionId.prefix(8), privacy: .public) tool:\(pendingKey.toolUseId.prefix(12), privacy: .public) reason:\(reason, privacy: .public)"
   )
   respondToExpired(pending, reason: reason)
  }
 }

 /// 给超时未决的待批写回一条显式拒绝，再关连接。
 ///
 /// 失败回调照旧要发：会话得离开「等待审批」，否则卡片会一直挂在列表里。
 private func respondToExpired(_ pending: PendingPermission, reason: String) {
  let response = AskAnswerBuilder.normalized(
   decision: AskAnswerBuilder.decisionDeny, answers: nil, reason: reason)
  if let data = try? Self.responseEncoder.encode(response) {
   data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    let written = write(pending.clientSocket, baseAddress, data.count)
    if written < 0 {
     logger.error(
      "Write failed for reaped pending - agent:\(pending.key.agent.rawValue, privacy: .public) errno:\(errno, privacy: .public)"
     )
    } else if written < data.count {
     // 这里是「问了没人答」唯一的通道，短写会让对端 JSON 解析失败（等于退回旧行为），必须留痕。
     logger.error(
      "Short write for reaped pending - agent:\(pending.key.agent.rawValue, privacy: .public) wrote:\(written, privacy: .public)/\(data.count, privacy: .public)"
     )
    }
   }
  }
  closeClient(pending.clientSocket)
  permissionFailureHandler?(pending.key, pending.toolUseId)
 }

 // MARK: - Tool Use ID Cache

 /// 写回响应的编码器。
 ///
 /// `.sortedKeys` 不是审美而是必需：`JSONEncoder` 的对象键顺序由内部字典决定，实测
 /// 同一字段集合在不同进程里会产出不同顺序（`{"decision":…,"answers":…}` 与
 /// `{"answers":…,"decision":…}` 都出现过，`deny` 的 `reason` 也会跑到前面）。
 /// 写回 socket 的字节是跨进程契约的一部分，排序后每次都是同一串字节，才谈得上
 /// 逐字节断言、抓包比对与排查。
 private static let responseEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  return encoder
 }()

 /// Encoder with sorted keys for deterministic cache keys
 private static let sortedEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  return encoder
 }()

 /// Generate cache key from event properties
 private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?)
  -> String
 {
  let inputStr: String
  if let input = toolInput,
   let data = try? Self.sortedEncoder.encode(input),
   let str = String(data: data, encoding: .utf8)
  {
   inputStr = str
  } else {
   inputStr = "{}"
  }
  return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
 }

 /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
 private func cacheToolUseId(event: HookEvent) {
  guard let toolUseId = event.toolUseId else { return }

  let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

  cacheLock.lock()
  if toolUseIdCache[key] == nil {
   toolUseIdCache[key] = []
  }
  toolUseIdCache[key]?.append(toolUseId)
  cacheLock.unlock()

  logger.debug(
   "Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)"
  )
 }

 /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
 private func popCachedToolUseId(event: HookEvent) -> String? {
  let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

  cacheLock.lock()
  defer { cacheLock.unlock() }

  guard var queue = toolUseIdCache[key], !queue.isEmpty else {
   return nil
  }

  let toolUseId = queue.removeFirst()

  if queue.isEmpty {
   toolUseIdCache.removeValue(forKey: key)
  } else {
   toolUseIdCache[key] = queue
  }

  logger.debug(
   "Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)"
  )
  return toolUseId
 }

 /// Clean up cache entries for a session (on session end)
 private func cleanupCache(sessionId: String) {
  cacheLock.lock()
  let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
  for key in keysToRemove {
   toolUseIdCache.removeValue(forKey: key)
  }
  cacheLock.unlock()

  if !keysToRemove.isEmpty {
   logger.debug(
    "Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)"
   )
  }
 }

 // MARK: - Private

 private func acceptConnection() {
  let clientSocket = accept(serverSocket, nil, nil)
  guard clientSocket >= 0 else { return }

  var nosigpipe: Int32 = 1
  setsockopt(
   clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

  openClientCount += 1
  let stats = pendingStats
  logger.debug(
   "Client connected (open: \(stats.open, privacy: .public), pending: \(stats.pending, privacy: .public))"
  )

  handleClient(clientSocket)
 }

 private func handleClient(_ clientSocket: Int32) {
  let flags = fcntl(clientSocket, F_GETFL)
  _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

  var allData = Data()
  var buffer = [UInt8](repeating: 0, count: 131072)
  var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

  // 读窗口：首个字节到达后 50ms 静默即结束读，总预算 2s。此前「从连接建立起
  // 0.5s」会让「连上后稍晚才写」的客户端丢事件（多 Agent 并发下更易发生）。
  let startTime = Date()
  while Date().timeIntervalSince(startTime) < 2.0 {
   let pollResult = poll(&pollFd, 1, 50)

   if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
    let bytesRead = read(clientSocket, &buffer, buffer.count)

    if bytesRead > 0 {
     allData.append(contentsOf: buffer[0..<bytesRead])
    } else if bytesRead == 0 {
     break
    } else if errno != EAGAIN && errno != EWOULDBLOCK {
     break
    }
   } else if pollResult == 0 {
    if !allData.isEmpty {
     break
    }
   } else {
    break
   }
  }

  guard !allData.isEmpty else {
   closeClient(clientSocket)
   return
  }

  let data = allData

  guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
   logger.warning(
    "Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
   closeClient(clientSocket)
   return
  }

  logger.debug(
   "Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

  if event.event == "PreToolUse" {
   cacheToolUseId(event: event)
  }

  if event.event == "SessionEnd" {
   cleanupCache(sessionId: event.sessionId)
  }

  // 「终结这条待批」的事件必须**先撤批、再盖章**（评审 F1）：`PostToolUse` /
  // `PostToolUseFailure` 的 status 也是 `processing`，若它们带着「这条会话有待批在等」
  // 的章进状态机，相位就会被钉在 waitingForApproval——工具明明已经跑完/被拒，行上却还
  // 挂着点了没用的 Allow/Deny。撤批与盖章在同一条串行队列上，先后因此是确定的；
  // 会话监视器随后那次撤批（按同一个 tool_use_id）会命中空条目，是无害的重复调用。
  if (event.event == "PostToolUse" || event.event == "PostToolUseFailure"),
   let toolUseId = event.toolUseId
  {
   cleanupSpecificPermission(key: event.sessionKey, toolUseId: toolUseId)
  }

  if event.expectsResponse {
   let toolUseId: String
   if let eventToolUseId = event.toolUseId {
    toolUseId = eventToolUseId
   } else if let cachedToolUseId = popCachedToolUseId(event: event) {
    toolUseId = cachedToolUseId
   } else {
    logger.warning(
     "Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit"
    )
    closeClient(clientSocket)
    eventHandler?(event)
    return
   }

   // 用原事件做副本、只替换 toolUseId：保留 agent / sessionFile / 子 Agent 归属。
   let updatedEvent = event.withToolUseId(toolUseId)
   let sessionKey = event.sessionKey
   let pendingKey = PendingPermissionKey(key: sessionKey, toolUseId: toolUseId)

   logger.debug(
    "Permission request - keeping socket open for \(sessionKey.sessionId.prefix(8), privacy: .public) agent:\(sessionKey.agent.rawValue, privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)"
   )

   let pending = PendingPermission(
    key: sessionKey,
    toolUseId: toolUseId,
    clientSocket: clientSocket,
    event: updatedEvent,
    receivedAt: Date()
   )
   permissionsLock.lock()
   let replaced = pendingPermissions.updateValue(pending, forKey: pendingKey)
   let pendingTotal = pendingPermissions.count
   permissionsLock.unlock()

   if let replaced {
    // 同键重发（集成重试）：旧 fd 不关会泄漏，且永远等不到应答。
    logger.warning(
     "Replacing existing pending permission - agent:\(sessionKey.agent.rawValue, privacy: .public) session:\(sessionKey.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)"
    )
    closeClient(replaced.clientSocket)
   }

   logger.info(
    "Pending permission registered - agent:\(sessionKey.agent.rawValue, privacy: .public) session:\(sessionKey.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) pending:\(pendingTotal, privacy: .public)"
   )

   // `ask` 工具：登记时把解析出的问题/选项规模记一条，便于在没跑起界面时
   // 用日志独立核查「信封里的 ask 真的被解析出来了」。
   if let ask = updatedEvent.ask {
    let optionCount = ask.questions.reduce(0) { $0 + $1.options.count }
    let multiCount = ask.questions.filter(\.multiSelect).count
    let freeTextCount = ask.questions.filter(\.freeText).count
    logger.info(
     "Pending ask registered - agent:\(sessionKey.agent.rawValue, privacy: .public) session:\(sessionKey.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) questions:\(ask.questions.count, privacy: .public) options:\(optionCount, privacy: .public) multi:\(multiCount, privacy: .public) freeText:\(freeTextCount, privacy: .public)"
    )
   }

   // 展示档位只在集成真的报了的时候记一条：既是可回溯的审计痕迹，也让
   // 「危险命令 / 降级放行 / 终端正在询问」在应用侧可被独立核查。
   if updatedEvent.isCriticalApproval || updatedEvent.isGateDegraded
    || updatedEvent.ompOwnsApproval == true
   {
    logger.info(
     "Pending approval display - kind:\(updatedEvent.approvalKind ?? "-", privacy: .public) tier:\(updatedEvent.degradation ?? "-", privacy: .public) gate:\(updatedEvent.gateEnabled.map { String($0) } ?? "-", privacy: .public) critical:\(String(updatedEvent.isCriticalApproval), privacy: .public) degraded:\(String(updatedEvent.isGateDegraded), privacy: .public) asking:\(String(updatedEvent.ompOwnsApproval == true), privacy: .public)"
    )
   }

   eventHandler?(updatedEvent.withLivePending(hasPendingPermission(key: sessionKey)))
   return
  } else {
   closeClient(clientSocket)
  }

  // 普通事件也带上「这条会话此刻有没有待批」：闸门版集成先发闸门信封、后发 PreToolUse，
  // 那条 PreToolUse 若不带这个事实就会把「等待审批」推回 processing（实测 74ms）。
  eventHandler?(event.withLivePending(hasPendingPermission(key: event.sessionKey)))
 }

 private func sendPermissionResponse(
  key: SessionKey, toolUseId: String, decision: String, answers: [String: [String]]?,
  reason: String?
 ) {
  permissionsLock.lock()
  let pendingKey = PendingPermissionKey(key: key, toolUseId: toolUseId)
  guard let pending = pendingPermissions.removeValue(forKey: pendingKey) else {
   permissionsLock.unlock()
   logger.debug(
    "No pending permission for agent:\(key.agent.rawValue, privacy: .public) toolUseId: \(toolUseId.prefix(12), privacy: .public)"
   )
   return
  }
  permissionsLock.unlock()

  let response = AskAnswerBuilder.normalized(
   decision: decision, answers: answers, reason: reason)
  guard let data = try? Self.responseEncoder.encode(response) else {
   closeClient(pending.clientSocket)
   permissionFailureHandler?(pending.key, pending.toolUseId)
   return
  }

  let age = Date().timeIntervalSince(pending.receivedAt)
  logger.info(
   "Sending response: \(decision, privacy: .public) for \(key.sessionId.prefix(8), privacy: .public) agent:\(key.agent.rawValue, privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)"
  )

  var writeSuccess = false
  data.withUnsafeBytes { bytes in
   guard let baseAddress = bytes.baseAddress else {
    logger.error("Failed to get data buffer address")
    return
   }
   let result = write(pending.clientSocket, baseAddress, data.count)
   if result < 0 {
    logger.error("Write failed with errno: \(errno)")
   } else {
    logger.debug("Write succeeded: \(result) bytes")
    writeSuccess = true
   }
  }

  closeClient(pending.clientSocket)

  if !writeSuccess {
   permissionFailureHandler?(pending.key, pending.toolUseId)
  }
 }

 private func sendPermissionResponseBySession(
  key: SessionKey, decision: String, answers: [String: [String]]? = nil, reason: String?
 ) {
  permissionsLock.lock()
  let matchingPending = pendingPermissions.values
   .filter { $0.key == key }
   .sorted { $0.receivedAt > $1.receivedAt }
   .first

  guard let pending = matchingPending else {
   permissionsLock.unlock()
   logger.debug(
    "No pending permission for session: \(key.sessionId.prefix(8), privacy: .public) agent:\(key.agent.rawValue, privacy: .public)"
   )
   return
  }

  pendingPermissions.removeValue(
   forKey: PendingPermissionKey(key: pending.key, toolUseId: pending.toolUseId))
  permissionsLock.unlock()

  let response = AskAnswerBuilder.normalized(
   decision: decision, answers: answers, reason: reason)
  guard let data = try? Self.responseEncoder.encode(response) else {
   closeClient(pending.clientSocket)
   permissionFailureHandler?(pending.key, pending.toolUseId)
   return
  }

  let age = Date().timeIntervalSince(pending.receivedAt)
  logger.info(
   "Sending response: \(decision, privacy: .public) for \(key.sessionId.prefix(8), privacy: .public) agent:\(key.agent.rawValue, privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)"
  )

  var writeSuccess = false
  data.withUnsafeBytes { bytes in
   guard let baseAddress = bytes.baseAddress else {
    logger.error("Failed to get data buffer address")
    return
   }
   let result = write(pending.clientSocket, baseAddress, data.count)
   if result < 0 {
    logger.error("Write failed with errno: \(errno)")
   } else {
    logger.debug("Write succeeded: \(result) bytes")
    writeSuccess = true
   }
  }

  closeClient(pending.clientSocket)

  if !writeSuccess {
   permissionFailureHandler?(pending.key, pending.toolUseId)
  }
 }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
nonisolated struct AnyCodable: Codable, @unchecked Sendable {
 /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
 nonisolated(unsafe) let value: Any

 /// Initialize with any value
 init(_ value: Any) {
  self.value = value
 }

 /// Decode from JSON
 init(from decoder: Decoder) throws {
  let container = try decoder.singleValueContainer()

  if container.decodeNil() {
   value = NSNull()
  } else if let bool = try? container.decode(Bool.self) {
   value = bool
  } else if let int = try? container.decode(Int.self) {
   value = int
  } else if let double = try? container.decode(Double.self) {
   value = double
  } else if let string = try? container.decode(String.self) {
   value = string
  } else if let array = try? container.decode([AnyCodable].self) {
   value = array.map { $0.value }
  } else if let dict = try? container.decode([String: AnyCodable].self) {
   value = dict.mapValues { $0.value }
  } else {
   throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
  }
 }

 /// Encode to JSON
 func encode(to encoder: Encoder) throws {
  var container = encoder.singleValueContainer()

  switch value {
  case is NSNull:
   try container.encodeNil()
  case let bool as Bool:
   try container.encode(bool)
  case let int as Int:
   try container.encode(int)
  case let double as Double:
   try container.encode(double)
  case let string as String:
   try container.encode(string)
  case let array as [Any]:
   try container.encode(array.map { AnyCodable($0) })
  case let dict as [String: Any]:
   try container.encode(dict.mapValues { AnyCodable($0) })
  default:
   throw EncodingError.invalidValue(
    value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
  }
 }
}
