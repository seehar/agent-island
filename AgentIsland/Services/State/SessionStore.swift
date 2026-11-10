//
//  SessionStore.swift
//  AgentIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Session")

    // MARK: - State

    /// 全部会话，按 (Agent, 会话 id) 索引
    private var sessions: [SessionKey: SessionState] = [:]

    /// 待同步的记录读取任务（按会话键去抖）
    private var pendingSyncs: [SessionKey: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let key, let toolUseId):
            await processPermissionApproved(key: key, toolUseId: toolUseId)

        case .permissionDenied(let key, let toolUseId, let reason):
            await processPermissionDenied(key: key, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let key, let toolUseId):
            await processSocketFailure(key: key, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let key):
            await processInterrupt(key: key)

        case .clearDetected(let key):
            await processClearDetected(key: key)

        case .sessionEnded(let key):
            await processSessionEnd(key: key)

        case .loadHistory(let key, let cwd):
            await loadHistoryFromFile(key: key, cwd: cwd)

        case .historyLoaded(
            let key, let messages, let completedTools, let toolResults, let structuredResults,
            let conversationInfo):
            await processHistoryLoaded(
                key: key,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let key, let toolUseId, let result):
            await processToolCompleted(key: key, toolUseId: toolUseId, result: result)
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ rawEvent: HookEvent) async {
        guard let event = resolveSubagentOwnership(rawEvent) else { return }
        let key = event.sessionKey
        var session = sessions[key] ?? createSession(from: event)

        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        if let sessionFile = event.sessionFile {
            session.transcriptPath = sessionFile
        }
        // Paseo 托管终端身份：有它就能在**不经 tmux** 的前提下把刘海的消息写进本会话的 pty。
        if let paseoTerminalId = event.paseoTerminalId {
            session.paseoTerminalId = paseoTerminalId
        }
        if let paseoCliPath = event.paseoCliPath {
            session.paseoCliPath = paseoCliPath
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            // 「已结束的会话」档位：立即档等于结束就移除；其余档把会话留在列表里，
            // 由 recheckAllSessions 按保留窗口收割（此前这里无条件移除，
            // 导致该档位与 .ended 分支全都不可达）。
            guard PreferenceStore.read(SessionRetention.self).keepsEndedSessions else {
                sessions.removeValue(forKey: key)
                cancelPendingSync(key: key)
                return
            }
            if session.phase.canTransition(to: .ended) {
                session.phase = .ended
            }
            sessions[key] = session
            cancelPendingSync(key: key)
            return
        }

        // 子 Agent 总线事件描述的是「派出去的子 Agent」，不是会话自身的一轮活动，
        // 因此不参与相位推导与工具跟踪，只更新子 Agent 表。
        if event.event == "SubagentLifecycle" || event.event == "SubagentProgress" {
            SessionHookReducers.processSubagentBusEvent(event: event, session: &session)
            sessions[key] = session
            publishState()
            return
        }

        // 已结束的行可以被新一轮活动复活：`--resume` 会用同一个会话 id 继续，
        // 而相位表里 .ended 是终态（事件驱动转不出去）。这里显式做一次「重开」，
        // 先回空闲态，再由下面那张表决定这次事件该去哪里。
        if session.phase == .ended {
            session.phase = .idle
        }

        let newPhase = event.determinePhase()

        // 有活着的待批时，状态类事件不许把相位从「等待审批」拉走。
        //
        // 闸门版集成**先发闸门信封、后发 PreToolUse**（两条独立连接、彼此不保序）：实测
        // PreToolUse 会在 74ms 后把相位推回 `processing`，卡片随之消失——而应用还攥着那条
        // 连接等一个再也点不到的决定，工具一直挂到客户端预算耗尽被静默拒绝，用户侧毫无反馈
        // （这正是「工具调用没反应」那条报障的根因）。待批是**已经发生的事实**（服务端持有
        // 那条 fd），状态上报只是描述，冲突时以事实为准。
        let heldByPending = SessionPhase.statusUpdateBlockedByPending(
            current: session.phase, next: newPhase, hasLivePending: event.hasLivePending)

        if heldByPending {
            Self.logger.debug(
                "Keeping waitingForApproval: \(event.event, privacy: .public) arrived while a pending decision is live"
            )
        } else if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug(
                "Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring"
            )
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug(
                "Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval"
            )
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        SessionHookReducers.processToolTracking(event: event, session: &session)
        SessionHookReducers.processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState.finishTurn()
        }

        sessions[key] = session
        publishState()

        if event.shouldSyncFile {
            scheduleFileSync(key: key, cwd: event.cwd)
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            agent: event.agentKind,
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            transcriptPath: event.sessionFile,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // 稍后根据进程树更新
            phase: .idle,
            paseoTerminalId: event.paseoTerminalId,
            paseoCliPath: event.paseoCliPath
        )
    }

    /// 子代理总线事件的落点折算。
    ///
    /// 子代理不是应用认识的会话：omp 的扩展把整棵子代理树的 `task:subagent:*` 都挂在根
    /// 会话名下上报，事件里的 `parent_tool_call_id` 是**派发它的那个会话**里的工具调用——
    /// 根会话派出的子代理能直接对上卡片；「子代理再派出的子代理」对不上（那张卡在上一层
    /// 会话里，本应用不渲染）。因此这里按子代理记录文件的目录层级反查归属：
    /// `<父会话文件去后缀>/<实例名>.jsonl`（可嵌套多层），沿目录往上找到已知会话，并把
    /// 挂靠卡片取成「派出它的那个子代理」的卡片，让孙代理与它的父辈同列。
    /// 认不出来的一律丢弃——宁可少一条计数，也不凭空造出一个不存在的会话。
    private func resolveSubagentOwnership(_ event: HookEvent) -> HookEvent? {
        guard event.isSubagentBusEvent else { return event }

        let key =
            sessions[event.sessionKey] != nil
            ? event.sessionKey
            : sessionKey(forSubagentTranscript: event.subagentSessionFile)
        guard let key, let session = sessions[key] else {
            Self.logger.debug(
                "Dropping subagent event \(event.subagentId ?? "?", privacy: .public): unknown session"
            )
            return nil
        }

        if let toolCallId = event.parentToolCallId,
            session.chatItems.contains(where: { $0.id == toolCallId })
        {
            return key == event.sessionKey
                ? event
                : event.owning(sessionKey: key, parentToolCallId: toolCallId)
        }

        let spawnerCardId = spawnerCard(for: event.subagentSessionFile, in: session)
        Self.logger.debug(
            "Subagent \(event.subagentId ?? "?", privacy: .public) -> session \(key.sessionId.prefix(8), privacy: .public) card \(spawnerCardId?.prefix(12) ?? "-", privacy: .public)"
        )
        return event.owning(sessionKey: key, parentToolCallId: spawnerCardId)
    }

    /// 沿子代理记录文件的目录层级往上找已知会话。
    ///
    /// 记录布局是 `<bucket>/<根会话文件名去后缀>/<实例名>.jsonl`，子代理再派子代理时
    /// 继续往下嵌套，因此目录名逐级等于「上一层会话的文件名」。
    private func sessionKey(forSubagentTranscript path: String?) -> SessionKey? {
        guard let path, !path.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while directory.path.count > 1 {
            let candidate = directory.path + ".jsonl"
            if let match = sessions.first(where: { $0.value.transcriptPath == candidate })?.key {
                return match
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// 派出该子代理的卡片：记录文件的目录名就是派出者（根会话或上层子代理）的名字。
    private func spawnerCard(for path: String?, in session: SessionState) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let spawnerName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return session.subagentState.subagents[spawnerName]?.parentToolCallId
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(key: SessionKey, toolUseId: String) async {
        guard var session = sessions[key] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(
                PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,  // We don't have the input stored in chatItems
                    receivedAt: nextPending.timestamp
                ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug(
                    "Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[key] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(
        key: SessionKey, toolUseId: String, result: ToolCompletionResult
    ) async {
        guard var session = sessions[key] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
            case .toolCall(let tool) = existingItem.type,
            tool.status == .success || tool.status == .error || tool.status == .interrupted
        {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
                case .toolCall(var tool) = session.chatItems[i].type
            {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug(
                    "Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)"
                )
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(
                    PermissionContext(
                        toolUseId: nextPending.id,
                        toolName: nextPending.name,
                        toolInput: nil,
                        receivedAt: nextPending.timestamp
                    ))
                session.phase = newPhase
                Self.logger.debug(
                    "Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)"
                )
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[key] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (
        id: String, name: String, timestamp: Date
    )? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(key: SessionKey, toolUseId: String, reason: String?) async
    {
        guard var session = sessions[key] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(
                PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug(
                    "Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)"
                )
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[key] = session
    }

    private func processSocketFailure(key: SessionKey, toolUseId: String) async {
        guard var session = sessions[key] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(
                PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug(
                    "Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)"
                )
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[key] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.key] else { return }

        // 用记录里的信息刷新会话概要（摘要、最后一条消息等）
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.key.sessionId,
            agent: payload.key.agent,
            cwd: session.cwd
        )
        session.conversationInfo = conversationInfo

        if session.needsClearReconciliation {
            reconcileAfterClear(&session, messages: payload.messages)
        }

        applyMessagesToHistory(payload, session: &session)

        // 全量同步（记录被重写或首次读取）要按时间重排；增量追加天然有序，不必排。
        if !payload.isIncremental {
            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            key: payload.key,
            session: &session,
            structuredResults: payload.structuredResults
        )

        populateSubagentRunsFromTaskResults(session: &session)

        sessions[payload.key] = session

        await emitToolCompletionEvents(
            key: payload.key,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// `/clear` 之后的对账：只保留「记录里还在的条目」与「最近 2 秒内刚建的占位条目」
    /// （`/clear` 之后立刻发生的新工具调用由 hook 先建占位，记录稍后才写到）。
    private func reconcileAfterClear(_ session: inout SessionState, messages: [ChatMessage]) {
        // /clear 之后的对账：只保留「记录里还在的条目」与「最近 2 秒内刚建的占位条目」
        // （/clear 之后立刻发生的新工具调用由 hook 先建占位，记录稍后才写到）。
        // Build set of valid IDs from the payload messages
        var validIds = Set<String>()
        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                switch block {
                case .toolUse(let tool):
                    validIds.insert(tool.id)
                case .text, .thinking, .image, .interrupted:
                    let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                    validIds.insert(itemId)
                }
            }
        }

        // Filter chatItems to only keep valid items OR items that are very recent
        // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
        let cutoffTime = Date().addingTimeInterval(-2)
        let previousCount = session.chatItems.count
        session.chatItems = session.chatItems.filter { item in
            validIds.contains(item.id) || item.timestamp > cutoffTime
        }

        // Also reset tool tracker
        session.toolTracker = ToolTracker()
        session.subagentState = SubagentState()

        session.needsClearReconciliation = false
        // `Logger` 的插值是 autoclosure：直接在里面读 `inout` 参数会被拒（escaping autoclosure
        // captures 'inout' parameter），先取出来再打。
        let keptCount = session.chatItems.count
        Self.logger.debug("Clear reconciliation: kept \(keptCount) of \(previousCount) items")
    }

    /// 把本轮读到的消息并入 `chatItems`：已存在的工具行保留其状态/结果，只刷新名字与入参；
    /// 其余块按 `createChatItem` 的规则新建。全量同步要按时间重排，增量追加天然有序。
    private func applyMessagesToHistory(_ payload: FileUpdatePayload, session: inout SessionState) {
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in payload.messages {
            for (blockIndex, block) in message.content.enumerated() {
                if case .toolUse(let tool) = block {
                    if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                        if case .toolCall(let existingTool) = session.chatItems[idx].type {
                            session.chatItems[idx] = ChatHistoryItem(
                                id: tool.id,
                                type: .toolCall(
                                    ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools,
                                        subagentRuns: existingTool.subagentRuns
                                    )),
                                timestamp: message.timestamp
                            )
                        }
                        continue
                    }
                }

                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: payload.completedToolIds,
                    toolResults: payload.toolResults,
                    structuredResults: payload.structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }
    }

    /// 用子 Agent 自己的记录补齐 Task/Agent 工具内部的工具调用列表
    private func populateSubagentToolsFromAgentFiles(
        key: SessionKey,
        session: inout SessionState,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                tool.isSubagentContainer,
                let structuredResult = structuredResults[session.chatItems[i].id],
                case .task(let taskResult) = structuredResult,
                !taskResult.agentId.isEmpty
            else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.subagentTools(
                sessionId: key.sessionId,
                agent: key.agent,
                agentId: taskResult.agentId,
                cwd: session.cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug(
                "Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)"
            )
        }
    }

    /// 记录侧兜底：从 task 工具结果文本里还原它派生的子 Agent 名单。
    ///
    /// 只在卡片上还没有子 Agent 行时使用（应用重启、读取历史、或实时集成缺席）。
    /// omp 的 task 结果是纯文本清单，名字取自它自己的 job 名，因此与实时上报的
    /// `subagent_id` 同源——实时事件到达后会按同一个 id 覆盖成真实状态。
    private func populateSubagentRunsFromTaskResults(session: inout SessionState) {
        for index in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[index].type,
                tool.isSubagentContainer,
                tool.subagentRuns.isEmpty
            else { continue }

            let names = GenericToolResultBuilder.subagentNames(fromTaskResult: tool.result)
            guard !names.isEmpty else { continue }

            // 结果已经完整落到卡片上时，子 Agent 必然已经结束；否则按运行中处理。
            let status: SubagentRunStatus = tool.status == .success ? .completed : .running
            tool.subagentRuns = names.map { name in
                SubagentRun(
                    id: name,
                    agent: nil,
                    status: status,
                    currentTool: nil,
                    task: nil,
                    sessionFile: nil,
                    parentToolCallId: session.chatItems[index].id,
                    // 记录侧兜底没有独立时间戳：以卡片的时刻为「证据时刻」，卡片一直
                    // 停在运行时，超过窗口同样不再计入运行数。
                    lastEvidence: session.chatItems[index].timestamp
                )
            }
            session.chatItems[index] = ChatHistoryItem(
                id: session.chatItems[index].id,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        key: SessionKey,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ToolResultPayload],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(key: key, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ToolResultPayload],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty text blocks — assistant turns with only tool calls
            // produce empty text blocks that would render as orphan dots/gaps.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(
                    id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(
                    ToolCallItem(
                        name: tool.name,
                        input: tool.input,
                        status: status,
                        result: resultText,
                        structuredResult: structuredResults[tool.id],
                        subagentTools: [],
                        subagentRuns: []
                    )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty thinking blocks — streaming can briefly produce empty
            // ones that would render as orphan grey dots.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .image(let imageBlock):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(
                id: itemId, type: .image(imageBlock), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(
        in session: inout SessionState, toolId: String, status: ToolStatus
    ) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
                case .toolCall(var tool) = session.chatItems[i].type
            {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning(
                "Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))"
            )
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(key: SessionKey) async {
        guard var session = sessions[key] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
                tool.status == .running
            {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[key] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(key: SessionKey) async {
        guard var session = sessions[key] else { return }

        Self.logger.info("Processing /clear for session \(key.rawValue, privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[key] = session

        Self.logger.info(
            "/clear processed for session \(key.rawValue, privacy: .public) - marked for reconciliation"
        )
    }

    // MARK: - Session End Processing

    private func processSessionEnd(key: SessionKey) async {
        // 同上：保留窗口非零时把会话标成结束而不是直接删掉。
        if PreferenceStore.read(SessionRetention.self).keepsEndedSessions,
            var session = sessions[key]
        {
            if session.phase.canTransition(to: .ended) {
                session.phase = .ended
            }
            sessions[key] = session
            cancelPendingSync(key: key)
            return
        }
        sessions.removeValue(forKey: key)
        cancelPendingSync(key: key)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(key: SessionKey, cwd: String) async {
        // 异步读取记录
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: key.sessionId,
            agent: key.agent,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(
            sessionId: key.sessionId, agent: key.agent)
        let toolResults = await ConversationParser.shared.toolResults(
            sessionId: key.sessionId, agent: key.agent)
        let structuredResults = await ConversationParser.shared.structuredResults(
            sessionId: key.sessionId, agent: key.agent)

        // 同时刷新会话概要（摘要、最后一条消息等）
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: key.sessionId,
            agent: key.agent,
            cwd: cwd
        )

        // 处理已加载的历史
        await process(
            .historyLoaded(
                key: key,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            ))
    }

    private func processHistoryLoaded(
        key: SessionKey,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ToolResultPayload],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[key] else { return }

        // 刷新会话概要（摘要、最后一条消息等）
        session.conversationInfo = conversationInfo

        // 把消息转换成聊天条目
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // 按时间排序
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        sessions[key] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(key: SessionKey, cwd: String) {
        // 取消上一次尚未执行的同步
        cancelPendingSync(key: key)

        // 安排新的去抖读取
        pendingSyncs[key] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // 增量读取：只取上次之后新增的内容
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: key.sessionId,
                agent: key.agent,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(key: key))
            }

            // 未安装实时集成的 Agent：由记录内容推断状态与工具事件
            if !result.activity.isEmpty,
                !AgentRegistry.integrationInstalled(key.agent),
                let session = await self?.session(for: key)
            {
                await self?.applyTranscriptActivity(
                    result.activity, key: key, cwd: cwd, session: session)
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                key: key,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(key: SessionKey) {
        pendingSyncs[key]?.cancel()
        pendingSyncs.removeValue(forKey: key)
    }

    // MARK: - 记录驱动的状态推断

    /// 轮询某个会话的记录（去抖后与 hook 触发的同步共用同一条路径）。
    func pollSession(key: SessionKey, cwd: String) {
        scheduleFileSync(key: key, cwd: cwd)
    }

    /// 把记录里观察到的活动转换成与 hook 同名的事件，喂给同一个状态机。
    /// 只在 Agent 没有安装实时集成时调用，以免与实时事件重复。
    private func applyTranscriptActivity(
        _ activity: [AgentActivityEvent],
        key: SessionKey,
        cwd: String,
        session: SessionState
    ) async {
        for item in activity {
            guard let event = Self.hookEvent(for: item, key: key, cwd: cwd, session: session) else {
                continue
            }
            await process(.hookReceived(event))
        }
    }

    /// 活动 → HookEvent 的映射（事件名与 Claude Code hook 保持一致）。
    private static func hookEvent(
        for activity: AgentActivityEvent,
        key: SessionKey,
        cwd: String,
        session: SessionState
    ) -> HookEvent? {
        let agent = key.agent.rawValue
        switch activity {
        case .promptSubmitted:
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd, event: "UserPromptSubmit", status: "processing",
                pid: session.pid, tty: session.tty, tool: nil, toolInput: nil, toolUseId: nil,
                notificationType: nil, message: nil, agent: agent,
                sessionFile: session.transcriptPath
            )
        case .toolStarted(let id, let name, let input):
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd, event: "PreToolUse", status: "running_tool",
                pid: session.pid, tty: session.tty, tool: name,
                toolInput: input.mapValues { AnyCodable($0) }, toolUseId: id,
                notificationType: nil, message: nil, agent: agent,
                sessionFile: session.transcriptPath
            )
        case .toolFinished(let id, let name, let isError):
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd,
                event: isError ? "PostToolUseFailure" : "PostToolUse", status: "processing",
                pid: session.pid, tty: session.tty, tool: name, toolInput: nil, toolUseId: id,
                notificationType: nil, message: nil, agent: agent,
                sessionFile: session.transcriptPath
            )
        case .turnFinished:
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd, event: "Stop", status: "waiting_for_input",
                pid: session.pid, tty: session.tty, tool: nil, toolInput: nil, toolUseId: nil,
                notificationType: nil, message: nil, agent: agent,
                sessionFile: session.transcriptPath
            )
        case .sessionReset:
            // 清空由 clearDetected 与随后的文件同步负责
            return nil
        }
    }

    // MARK: - Periodic Status Check

    /// Start periodic status checking for all sessions
    func startPeriodicStatusCheck() {
        guard statusCheckTask == nil else { return }

        statusCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                // 「刷新频率」档位每轮读一次：改档位在下一轮生效，不必重启。
                // 读取走 nonisolated 的 PreferenceStore（actor 里也能直接调用）。
                let seconds = PreferenceStore.read(RefreshCadence.self).statusSeconds
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.recheckAllSessions()
            }
        }
        Self.logger.info(
            "Started periodic status check (every \(PreferenceStore.read(RefreshCadence.self).statusSeconds)s)"
        )
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
        Self.logger.info("Stopped periodic status check")
    }

    /// 重新检查所有活跃会话
    private func recheckAllSessions() {
        var stateChanged = false
        let now = Date()
        let staleCutoff = now.addingTimeInterval(-Self.staleSessionIdleTimeout)
        // 「已结束的会话」档位：立即档等于结束就移除，其余档按窗口保留
        let retention = PreferenceStore.read(SessionRetention.self)

        for (key, session) in Array(sessions) {
            if session.phase == .ended {
                guard
                    Self.shouldDropEndedSession(
                        phase: session.phase, lastActivity: session.lastActivity,
                        retention: retention, now: now)
                else {
                    // 结束的会话不会再变，挂起的文件同步可以先收掉。
                    cancelPendingSync(key: key)
                    continue
                }
                sessions.removeValue(forKey: key)
                cancelPendingSync(key: key)
                stateChanged = true
                continue
            }

            // 子 Agent 的「运行中」需要持续证据：丢一条 settled 帧就会留下永远在跑的
            // 幽灵（实测运行十天后累计到一百多个）。窗口外的记录在这里落成终态，
            // 并同步回卡片，让徽标与列表行都不再显示它们还在跑。
            var session = session
            let runningBeforeExpiry = session.subagentState.runningSubagentCount(at: now)
            if session.subagentState.expireStaleEvidence(now: now) {
                SessionHookReducers.syncSubagentRunsToChatItems(session: &session)
                sessions[key] = session
                stateChanged = true
                Self.logger.info(
                    "Expired stale subagent evidence for \(key.rawValue, privacy: .public) (running in window: \(runningBeforeExpiry))"
                )
            }

            if let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    // 保留档：相位还看得见（在处理/待批/压缩）的会话标成结束留在列表里，
                    // 等保留窗口到期再由上面的分支收割；其余情况立刻移除。
                    if retention.keepsEndedSessions, session.phase.isPausableWhenProcessGone() {
                        var ended = session
                        ended.phase = .ended
                        sessions[key] = ended
                        stateChanged = true
                        continue
                    }
                    Self.logger.info(
                        "Process \(pid) no longer running, ending session \(key.rawValue, privacy: .public)"
                    )
                    sessions.removeValue(forKey: key)
                    cancelPendingSync(key: key)
                    stateChanged = true
                    continue
                }
            } else if session.lastActivity < staleCutoff {
                // 没有实时集成的会话无法感知进程退出，只能按「多久没写入」回收
                Self.logger.info(
                    "Session \(key.rawValue, privacy: .public) idle for too long, ending")
                sessions.removeValue(forKey: key)
                cancelPendingSync(key: key)
                stateChanged = true
                continue
            }

            // 「处理中」的心跳兜底：Stop 丢了（CLI 被杀、omp 把会话 dispose 掉）时相位
            // 会永远停在处理中，只要进程还活着就没人体面地收它——关闭态徽标的分子因此虚高。
            // 判据见 `SessionLiveness`（纯函数，可单测）。
            if SessionLiveness.shouldDemoteProcessing(
                session: session,
                transcriptModifiedAt: session.transcriptPath.flatMap {
                    TranscriptFileReader.modificationDate(of: URL(fileURLWithPath: $0))
                },
                now: now)
            {
                let idleMinutes = Int(SessionLiveness.processingHeartbeatTimeout / 60)
                Self.logger.info(
                    "Session \(key.rawValue, privacy: .public) has no heartbeat for \(idleMinutes)m, dropping stale processing phase"
                )
                var demoted = session
                demoted.phase = .idle
                sessions[key] = demoted
                stateChanged = true
                continue
            }

            let needsSync: Bool
            switch session.phase {
            case .processing, .waitingForApproval:
                needsSync = true
            default:
                needsSync = false
            }
            if needsSync {
                scheduleFileSync(key: key, cwd: session.cwd)
            }
        }

        if stateChanged {
            publishState()
        }
    }

    /// 无实时集成会话的空闲回收阈值（秒）。
    private static let staleSessionIdleTimeout: TimeInterval = 30 * 60

    /// 结束的会话该不该从列表移除：按「已结束的会话」档位的保留窗口判断。
    /// 纯函数（可单测）；立即档窗口为 0，等于结束就移除——这是默认行为。
    nonisolated static func shouldDropEndedSession(
        phase: SessionPhase, lastActivity: Date, retention: SessionRetention, now: Date
    ) -> Bool {
        guard phase == .ended else { return false }
        return now.timeIntervalSince(lastActivity) >= retention.window
    }

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    // MARK: - State Publishing

    /// 上一次真正发出去的快照。
    ///
    /// 事件密度远高于「界面上有东西变了」的密度：一次工具调用会连着来 PreToolUse /
    /// PostToolUse / Stop 好几帧，而多数帧只改时间戳或压根不改可见字段。整份列表
    /// （排序后）逐值没变就不发，省掉 SwiftUI 一整轮 diff。
    private var lastPublishedSessions: [SessionState]?

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        guard sortedSessions != lastPublishedSessions else { return }
        lastPublishedSessions = sortedSessions
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for key: SessionKey) -> SessionState? {
        sessions[key]
    }
}
