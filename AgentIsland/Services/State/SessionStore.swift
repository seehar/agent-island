//
//  SessionStore.swift
//  AgentIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import Mixpanel
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Session")

    // MARK: - State

    /// 全部会话，按 (Agent, 会话 id) 索引
    private var sessions: [SessionKey: SessionState] = [:]

    /// 待同步的记录读取任务（按会话键去抖）
    private var pendingSyncs: [SessionKey: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    /// Status check interval (3 seconds)
    private let statusCheckIntervalSeconds: UInt64 = 3

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

        case .historyLoaded(let key, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
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

        // MARK: - Subagent Events

        case .subagentStarted(let key, let taskToolId):
            processSubagentStarted(key: key, taskToolId: taskToolId)

        case .subagentToolExecuted(let key, let tool):
            processSubagentToolExecuted(key: key, tool: tool)

        case .subagentToolCompleted(let key, let toolId, let status):
            processSubagentToolCompleted(key: key, toolId: toolId, status: status)

        case .subagentStopped(let key, let taskToolId):
            processSubagentStopped(key: key, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let key = event.sessionKey
        let isNewSession = sessions[key] == nil
        var session = sessions[key] ?? createSession(from: event)

        // Track new session in Mixpanel
        if isNewSession {
            Mixpanel.mainInstance().track(event: "Session Started")
        }

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
        session.lastActivity = Date()

        if event.status == "ended" {
            sessions.removeValue(forKey: key)
            cancelPendingSync(key: key)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
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
            phase: .idle
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead.
                // 只对真正上报子 Agent 内部调用的 Agent 生效：其余 Agent（omp/pi/
                // opencode）在 Task 运行期间报上来的工具属于根会话本体。
                let isSubagentTool = session.agent.reportsSubagentInnerTools
                    && session.subagentState.hasActiveSubagent
                    && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolName = event.tool,
                      let toolUseId = event.toolUseId,
                      session.agent.reportsSubagentInnerTools,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool is starting. Add it to the parent Task/Agent's
                // subagent list and sync to chatItems so the UI updates live (rather
                // than only after the parent Agent completes).
                var input: [String: String] = [:]
                if let hookInput = event.toolInput {
                    for (key, value) in hookInput {
                        if let str = value.value as? String {
                            input[key] = str
                        } else if let num = value.value as? Int {
                            input[key] = String(num)
                        } else if let bool = value.value as? Bool {
                            input[key] = bool ? "true" : "false"
                        }
                    }
                }
                let subagentTool = SubagentToolCall(
                    id: toolUseId,
                    name: toolName,
                    input: input,
                    status: .running,
                    timestamp: Date()
                )
                session.subagentState.addSubagentTool(subagentTool)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "PostToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent tool returned — the subagent has finished. Stop
                // tracking so subsequent tools in the parent turn don't get
                // attached to this dead task.
                session.subagentState.stopTask(taskToolId: toolUseId)
                Self.logger.debug("Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolUseId = event.toolUseId,
                      session.agent.reportsSubagentInnerTools,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool completed. Update its status in the
                // parent's subagent list and sync.
                session.subagentState.updateSubagentToolStatus(toolId: toolUseId, status: .success)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// Push the current subagent tool lists from subagentState into the
    /// corresponding ChatHistoryItem.subagentTools so the UI renders them live.
    private func syncSubagentToolsToChatItems(session: inout SessionState) {
        for (taskToolId, context) in session.subagentState.activeTasks {
            guard !context.subagentTools.isEmpty else { continue }
            for i in 0..<session.chatItems.count {
                if session.chatItems[i].id == taskToolId,
                   case .toolCall(var tool) = session.chatItems[i].type {
                    tool.subagentTools = context.subagentTools
                    session.chatItems[i] = ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                    break
                }
            }
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(key: SessionKey, taskToolId: String) {
        guard var session = sessions[key] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[key] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(key: SessionKey, tool: SubagentToolCall) {
        guard var session = sessions[key] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[key] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(key: SessionKey, toolId: String, status: ToolStatus) {
        guard var session = sessions[key] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[key] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(key: SessionKey, taskToolId: String) {
        guard var session = sessions[key] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[key] = session
        // Subagent tools will be populated from agent file in processFileUpdated
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
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
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
    private func processToolCompleted(key: SessionKey, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[key] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[key] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(key: SessionKey, toolUseId: String, reason: String?) async {
        guard var session = sessions[key] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
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
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
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

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
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
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
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
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
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

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            key: payload.key,
            session: &session,
            structuredResults: payload.structuredResults
        )

        sessions[payload.key] = session

        await emitToolCompletionEvents(
            key: payload.key,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
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
                  !taskResult.agentId.isEmpty else { continue }

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

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
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
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
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
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
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
            return ChatHistoryItem(id: itemId, type: .image(imageBlock), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
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
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
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
               tool.status == .running {
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

        Self.logger.info("/clear processed for session \(key.rawValue, privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(key: SessionKey) async {
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
        let completedTools = await ConversationParser.shared.completedToolIds(sessionId: key.sessionId, agent: key.agent)
        let toolResults = await ConversationParser.shared.toolResults(sessionId: key.sessionId, agent: key.agent)
        let structuredResults = await ConversationParser.shared.structuredResults(sessionId: key.sessionId, agent: key.agent)

        // 同时刷新会话概要（摘要、最后一条消息等）
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: key.sessionId,
            agent: key.agent,
            cwd: cwd
        )

        // 处理已加载的历史
        await process(.historyLoaded(
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
               let session = await self?.session(for: key) {
                await self?.applyTranscriptActivity(result.activity, key: key, cwd: cwd, session: session)
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
            guard let event = Self.hookEvent(for: item, key: key, cwd: cwd, session: session) else { continue }
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
                notificationType: nil, message: nil, agent: agent, sessionFile: session.transcriptPath
            )
        case .toolStarted(let id, let name, let input):
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd, event: "PreToolUse", status: "running_tool",
                pid: session.pid, tty: session.tty, tool: name,
                toolInput: input.mapValues { AnyCodable($0) }, toolUseId: id,
                notificationType: nil, message: nil, agent: agent, sessionFile: session.transcriptPath
            )
        case .toolFinished(let id, let name, let isError):
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd,
                event: isError ? "PostToolUseFailure" : "PostToolUse", status: "processing",
                pid: session.pid, tty: session.tty, tool: name, toolInput: nil, toolUseId: id,
                notificationType: nil, message: nil, agent: agent, sessionFile: session.transcriptPath
            )
        case .turnFinished:
            return HookEvent(
                sessionId: key.sessionId, cwd: cwd, event: "Stop", status: "waiting_for_input",
                pid: session.pid, tty: session.tty, tool: nil, toolInput: nil, toolUseId: nil,
                notificationType: nil, message: nil, agent: agent, sessionFile: session.transcriptPath
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

        let intervalSeconds = statusCheckIntervalSeconds
        statusCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.recheckAllSessions()
            }
        }
        Self.logger.info("Started periodic status check (every \(intervalSeconds)s)")
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
        Self.logger.info("Stopped periodic status check")
    }

    /// 重新检查所有活跃会话
    private func recheckAllSessions() {
        var removedSession = false
        let staleCutoff = Date().addingTimeInterval(-Self.staleSessionIdleTimeout)

        for (key, session) in Array(sessions) {
            if session.phase == .ended {
                sessions.removeValue(forKey: key)
                cancelPendingSync(key: key)
                removedSession = true
                continue
            }

            if let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    Self.logger.info("Process \(pid) no longer running, ending session \(key.rawValue, privacy: .public)")
                    sessions.removeValue(forKey: key)
                    cancelPendingSync(key: key)
                    removedSession = true
                    continue
                }
            } else if session.lastActivity < staleCutoff {
                // 没有实时集成的会话无法感知进程退出，只能按「多久没写入」回收
                Self.logger.info("Session \(key.rawValue, privacy: .public) idle for too long, ending")
                sessions.removeValue(forKey: key)
                cancelPendingSync(key: key)
                removedSession = true
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

        if removedSession {
            publishState()
        }
    }

    /// 无实时集成会话的空闲回收阈值（秒）。
    private static let staleSessionIdleTimeout: TimeInterval = 30 * 60

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for key: SessionKey) -> SessionState? {
        sessions[key]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(key: SessionKey) -> Bool {
        guard let session = sessions[key] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
