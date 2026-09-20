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
 let sessionId: String
 let cwd: String
 let event: String
 let status: String
 let pid: Int?
 let tty: String?
 let tool: String?
 let toolInput: [String: AnyCodable]?
 /// 工具调用 id；`var` 只为 `withToolUseId(_:)` 的副本语义，其余字段保持不可变。
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
 /// 上报方所属 Agent；旧版 Claude hook 脚本不带该字段，按 Claude 处理。
 let agent: String?
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
 let parentToolCallId: String?
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
  ompOwnsApproval: Bool? = nil
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
 }

 /// 是否为子代理总线事件（omp/pi 的 `task:subagent:*` 上报，不是会话自身的一轮活动）。
 nonisolated var isSubagentBusEvent: Bool {
  event == "SubagentLifecycle" || event == "SubagentProgress"
 }

 /// 复制一份事件，改写到另一个会话、并指定它应挂靠的父工具调用。
 ///
 /// 子代理实例上报的是「它自己派出的子代理」，事件里的 `parent_tool_call_id` 指向上一层
 /// 会话里的工具调用（本应用没有那张卡片），因此折算落点时统一改成「上报者所属卡片」。
 nonisolated func owning(sessionKey: SessionKey, parentToolCallId: String?) -> HookEvent {
  HookEvent(
   sessionId: sessionKey.sessionId, cwd: cwd, event: event, status: status, pid: pid, tty: tty,
   tool: tool, toolInput: toolInput, toolUseId: toolUseId, notificationType: notificationType,
   message: message, agent: sessionKey.agent.rawValue, sessionFile: sessionFile,
   subagentId: subagentId, subagentAgent: subagentAgent, subagentStatus: subagentStatus,
   subagentCurrentTool: subagentCurrentTool, subagentTask: subagentTask,
   parentToolCallId: parentToolCallId ?? self.parentToolCallId,
   subagentSessionFile: subagentSessionFile
  )
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
 /// - omp / pi / opencode：`ToolApproval` + 显式 `expects_response`；只展示的集成
 ///   不满足该条件，因此不会被登记成待批。
 nonisolated var expectsResponse: Bool {
  if event == "PermissionRequest" && status == "waiting_for_approval" { return true }
  return event == "ToolApproval" && wantsResponse == true
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

/// Response to send back to the hook
struct HookResponse: Codable {
 let decision: String  // "allow", "deny", or "ask"
 let reason: String?
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
 /// 默认 150s；环境变量 `AGENT_ISLAND_PENDING_TTL_SECONDS` 可覆盖（验证用钩子）。
 private let pendingTTL: TimeInterval = {
  // 项目内自有 `ProcessInfo`（进程树）会遮蔽 Foundation 的同名类型，故显式限定
  guard let raw = Foundation.ProcessInfo.processInfo.environment["AGENT_ISLAND_PENDING_TTL_SECONDS"],
   let seconds = TimeInterval(raw), seconds > 0
  else { return 150 }
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

  eventHandler = onEvent
  permissionFailureHandler = onPermissionFailure

  unlink(Self.socketPath)

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

  let bindResult = withUnsafePointer(to: &addr) { ptr in
   ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
    bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }

  guard bindResult == 0 else {
   logger.error("Failed to bind socket: \(errno)")
   close(serverSocket)
   serverSocket = -1
   return
  }

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
 func stop() {
  acceptSource?.cancel()
  acceptSource = nil
  unlink(Self.socketPath)

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
 func respondToPermission(key: SessionKey, toolUseId: String, decision: String, reason: String? = nil) {
  queue.async { [weak self] in
   self?.sendPermissionResponse(key: key, toolUseId: toolUseId, decision: decision, reason: reason)
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
  logger.debug(
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

  for (pendingKey, pending) in expired {
   logger.warning(
    "Reaped pending permission after \(String(format: "%.1f", self.pendingTTL), privacy: .public)s - agent:\(pendingKey.key.agent.rawValue, privacy: .public) session:\(pendingKey.key.sessionId.prefix(8), privacy: .public) tool:\(pendingKey.toolUseId.prefix(12), privacy: .public)"
   )
   closeClient(pending.clientSocket)
   permissionFailureHandler?(pending.key, pending.toolUseId)
  }
 }

 // MARK: - Tool Use ID Cache

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

   // 展示档位只在集成真的报了的时候记一条：既是可回溯的审计痕迹，也让
   // 「危险命令 / 降级放行 / 终端正在询问」在应用侧可被独立核查。
   if updatedEvent.isCriticalApproval || updatedEvent.isGateDegraded
    || updatedEvent.ompOwnsApproval == true
   {
    logger.info(
     "Pending approval display - kind:\(updatedEvent.approvalKind ?? "-", privacy: .public) tier:\(updatedEvent.degradation ?? "-", privacy: .public) gate:\(updatedEvent.gateEnabled.map { String($0) } ?? "-", privacy: .public) critical:\(String(updatedEvent.isCriticalApproval), privacy: .public) degraded:\(String(updatedEvent.isGateDegraded), privacy: .public) asking:\(String(updatedEvent.ompOwnsApproval == true), privacy: .public)"
    )
   }

   eventHandler?(updatedEvent)
   return
  } else {
   closeClient(clientSocket)
  }

  eventHandler?(event)
 }

 private func sendPermissionResponse(
  key: SessionKey, toolUseId: String, decision: String, reason: String?
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

  let response = HookResponse(decision: decision, reason: reason)
  guard let data = try? JSONEncoder().encode(response) else {
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

 private func sendPermissionResponseBySession(key: SessionKey, decision: String, reason: String?) {
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

  let response = HookResponse(decision: decision, reason: reason)
  guard let data = try? JSONEncoder().encode(response) else {
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
