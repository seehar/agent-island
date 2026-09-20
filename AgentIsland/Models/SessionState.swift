//
//  SessionState.swift
//  AgentIsland
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
nonisolated struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    /// 该会话属于哪个 Agent CLI。
    let agent: AgentKind

    let sessionId: String
    let cwd: String
    let projectName: String

    /// 记录文件路径；由实时集成上报，或用记录目录推导。结构化存储的 Agent 为 nil。
    var transcriptPath: String?

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionKey.rawValue }

    /// 应用内的唯一键：不同 Agent 的会话 id 可能相同，必须带 Agent 前缀。
    var sessionKey: SessionKey { SessionKey(agent: agent, sessionId: sessionId) }

    // MARK: - Initialization

    nonisolated init(
        agent: AgentKind = .claudeCode,
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        transcriptPath: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.transcriptPath = transcriptPath
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// 当前正在运行的子 Agent 数。
    ///
    /// omp/pi 走子 Agent 生命周期（`subagentState.subagents`）；Claude 没有这条
    /// 通道，退回到「在飞的 Task 工具」计数。两者表达同一件事，界面不必区分。
    var activeSubagentCount: Int {
        let running = subagentState.runningSubagentCount
        return running > 0 ? running : subagentState.activeTasks.count
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// 稳定的 SwiftUI 标识（pid + Agent + 会话 id），保证动画期间不跳变。
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionKey.rawValue)"
        }
        return sessionKey.rawValue
    }

    /// 展示标题：摘要 > 首条用户消息 > 项目名
    var displayTitle: String {
        conversationInfo.summary ?? conversationInfo.firstUserMessage ?? projectName
    }

    /// Best hint for matching window title
    var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Token usage for this session
    var usage: UsageInfo {
        conversationInfo.usage
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
nonisolated struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
nonisolated struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
nonisolated enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
nonisolated struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    /// 子 Agent 实例，键为 omp 的 job 名（同时是子会话记录的文件名）。
    var subagents: [String: SubagentRun]

    /// 子 Agent 的首次出现顺序，供界面稳定排序（字典不保证顺序）。
    var subagentOrder: [String]

    nonisolated init(
        activeTasks: [String: TaskContext] = [:], taskStack: [String] = [],
        agentDescriptions: [String: String] = [:],
        subagents: [String: SubagentRun] = [:], subagentOrder: [String] = []
    ) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
        self.subagents = subagents
        self.subagentOrder = subagentOrder
    }

    /// 正在运行的子 Agent 数（不含已结束的）。
    nonisolated var runningSubagentCount: Int {
        subagents.values.filter { $0.status.isRunning }.count
    }

    /// 记录或更新一个子 Agent。
    ///
    /// 终态会清掉「当前工具」：否则已结束的子 Agent 会一直显示在跑某个工具。
    nonisolated mutating func upsertSubagent(
        id: String,
        agent: String?,
        status: SubagentRunStatus,
        currentTool: String? = nil,
        task: String? = nil,
        sessionFile: String? = nil,
        parentToolCallId: String? = nil
    ) {
        let resolvedTool = status.isRunning ? currentTool : nil
        if var run = subagents[id] {
            run.agent = agent
            run.status = status
            run.currentTool = resolvedTool ?? (status.isRunning ? run.currentTool : nil)
            run.task = task ?? run.task
            run.sessionFile = sessionFile ?? run.sessionFile
            run.parentToolCallId = parentToolCallId ?? run.parentToolCallId
            subagents[id] = run
        } else {
            subagentOrder.append(id)
            subagents[id] = SubagentRun(
                id: id,
                agent: agent,
                status: status,
                currentTool: resolvedTool,
                task: task,
                sessionFile: sessionFile,
                parentToolCallId: parentToolCallId
            )
        }
    }

    /// 某个 task 工具调用派生的子 Agent，按出现顺序。
    nonisolated func subagents(forTask taskToolId: String) -> [SubagentRun] {
        subagentOrder.compactMap { subagents[$0] }
            .filter { $0.parentToolCallId == taskToolId }
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// 一轮结束（根会话的 `Stop`）：清掉「在飞的 Task 工具」跟踪，但**保留子 Agent 表**。
    ///
    /// omp 的 task 默认异步派发：根会话回合结束时子 Agent 往往还在跑，若一并清空，
    /// 界面会在子 Agent 运行期间失去全部表示。子 Agent 由自己的生命周期事件收敛。
    nonisolated mutating func finishTurn() {
        activeTasks.removeAll()
        taskStack.removeAll()
        agentDescriptions.removeAll()
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard
            let mostRecentTaskId = activeTasks.keys.max(by: {
                (activeTasks[$0]?.startTime ?? .distantPast)
                    < (activeTasks[$1]?.startTime ?? .distantPast)
            })
        else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId })
            {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
nonisolated struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}

// MARK: - Subagent Run

/// 子 Agent 的生命周期状态（omp 的 `task:subagent:lifecycle` 取值）。
nonisolated enum SubagentRunStatus: String, Sendable {
    case started
    case running
    case completed
    case failed
    case aborted
    /// 上报值不认识（旧版或新增取值）：按「已结束」处理，避免计数永远偏高。
    case unknown

    /// 是否仍在运行。
    nonisolated var isRunning: Bool {
        self == .started || self == .running
    }

    /// 从线协议取值构造。
    nonisolated init(wire: String?) {
        guard let wire, let value = SubagentRunStatus(rawValue: wire) else {
            self = .unknown
            return
        }
        self = value
    }
}

/// 一个子 Agent 实例（omp 的 task 派发单元）。
///
/// 与 `SubagentToolCall` 的区别：后者是「子 Agent 内部的一次工具调用」（Claude 由
/// hook 与 agent 记录上报）；本类型是「子 Agent 本身」——omp 通过父会话的
/// `task:subagent:*` 总线给出身份、状态与当前工具，但不给内部调用明细。
nonisolated struct SubagentRun: Equatable, Identifiable, Sendable {
    /// omp 的 job 名（如 `EchoAlpha`），同时是子会话记录的文件名。
    let id: String
    /// 子 Agent 类型名（如 `scout` / `sonic`）；记录侧兜底拿不到类型时为 nil。
    var agent: String?
    var status: SubagentRunStatus
    /// 当前正在执行的工具名；已结束时为空。
    var currentTool: String?
    /// 交给它的任务描述。
    var task: String?
    /// 子 Agent 自己的记录文件路径。
    var sessionFile: String?
    /// 派生它的父会话工具调用（task 工具的 tool_use_id）。
    var parentToolCallId: String?

    /// 任务描述首行，供密集行展示（omp 的 task 正文是完整 brief，太长）。
    nonisolated var taskSummary: String? {
        guard let task, !task.isEmpty else { return nil }
        let firstLine = task.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? task
        return String(firstLine.prefix(120))
    }
}
