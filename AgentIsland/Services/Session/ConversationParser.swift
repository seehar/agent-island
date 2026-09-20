//
//  ConversationParser.swift
//  AgentIsland
//
//  会话记录的读取门面。具体记录格式交给各 Agent 的 schema
//  （`AgentTranscriptSchema`），这里只负责：按会话缓存解析状态、把增量结果
//  整理成 UI 需要的形状。
//

import Foundation
import os.log

/// 会话的 token 用量。
nonisolated struct UsageInfo: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// 展示用短字符串（例如 "12.5K tokens"）。
    ///
    /// 小数点符号跟随界面语言（德语环境下写作 12,5K）；K/M 是公制词头，各语言通用，
    /// 因此不参与本地化。
    var formattedTotal: String {
        let total = totalTokens
        let locale = Locale(identifier: AppSettings.language.resolvedCode)
        if total >= 1_000_000 {
            return String(format: "%.1fM", locale: locale, Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", locale: locale, Double(total) / 1_000)
        }
        return "\(total)"
    }
}

/// 会话的概要信息，用于列表与标题展示。
nonisolated struct ConversationInfo: Equatable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user"、"assistant" 或 "tool"
    let lastToolName: String?  // lastMessageRole 为 "tool" 时的工具名
    let firstUserMessage: String?  // 没有摘要时的标题兜底
    let lastUserMessageDate: Date?  // 最后一条用户消息时间（用于稳定排序）
    var usage: UsageInfo = UsageInfo()  // token 用量统计
}

/// 各 Agent 的 schema 单例。
nonisolated enum AgentTranscriptSchemaRegistry {
    private static let schemas: [AgentKind: any AgentTranscriptSchema] = [
        .claudeCode: ClaudeTranscriptSchema(),
        .ohMyPi: PiTranscriptSchema(kind: .ohMyPi),
        .pi: PiTranscriptSchema(kind: .pi),
        .opencode: OpenCodeTranscriptSchema(),
    ]

    /// 取某个 Agent 的记录解析器。
    static func schema(for kind: AgentKind) -> any AgentTranscriptSchema {
        if let schema = schemas[kind] { return schema }
        // 尚未注册的 Agent 回退到 Claude 解析器，避免调用点崩溃。
        return ClaudeTranscriptSchema()
    }
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// 跨上下文使用的日志器。
    nonisolated static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Parser")

    /// 各会话的解析状态，按 (Agent, 会话 id) 隔离。
    private var states: [SessionKey: TranscriptParseState] = [:]

    /// 增量解析结果。
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
        /// 本次读取观察到、需要上报给状态机的活动。
        let activity: [AgentActivityEvent]
    }

    /// 兼容旧命名：工具结果载荷现在由所有 Agent 共用。
    typealias ToolResult = ToolResultPayload

    // MARK: - 读取

    /// 读取一次记录（schema 内部按需增量）。
    ///
    /// 产生的活动事件会暂存在会话状态里，由 `parseIncremental` 取走，
    /// 避免整读把事件吞掉。
    private func read(sessionId: String, agent: AgentKind, cwd: String) -> TranscriptReadResult {
        let key = SessionKey(agent: agent, sessionId: sessionId)
        var state = states[key] ?? TranscriptParseState()
        let schema = AgentTranscriptSchemaRegistry.schema(for: agent)
        let result = schema.read(sessionId: sessionId, cwd: cwd, state: &state)
        if !result.activity.isEmpty {
            state.pendingActivity.append(contentsOf: result.activity)
        }
        states[key] = state
        return result
    }

    /// 会话概要（列表与标题使用）。
    func parse(sessionId: String, agent: AgentKind, cwd: String) -> ConversationInfo {
        _ = read(sessionId: sessionId, agent: agent, cwd: cwd)
        return states[SessionKey(agent: agent, sessionId: sessionId)]?.info ?? Self.emptyInfo
    }

    /// 完整对话历史（聊天视图使用，调用需谨慎）。
    func parseFullConversation(sessionId: String, agent: AgentKind, cwd: String) -> [ChatMessage] {
        _ = read(sessionId: sessionId, agent: agent, cwd: cwd)
        return states[SessionKey(agent: agent, sessionId: sessionId)]?.messages ?? []
    }

    /// 只读取上次调用之后的新内容。
    func parseIncremental(sessionId: String, agent: AgentKind, cwd: String)
        -> IncrementalParseResult
    {
        let result = read(sessionId: sessionId, agent: agent, cwd: cwd)
        let state = states[SessionKey(agent: agent, sessionId: sessionId)] ?? TranscriptParseState()
        return IncrementalParseResult(
            newMessages: result.newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: result.resetDetected,
            activity: result.activity
        )
    }

    /// 已完成的工具 id 集合。
    func completedToolIds(sessionId: String, agent: AgentKind) -> Set<String> {
        states[SessionKey(agent: agent, sessionId: sessionId)]?.completedToolIds ?? []
    }

    /// 工具结果。
    func toolResults(sessionId: String, agent: AgentKind) -> [String: ToolResult] {
        states[SessionKey(agent: agent, sessionId: sessionId)]?.toolResults ?? [:]
    }

    /// 结构化工具结果。
    func structuredResults(sessionId: String, agent: AgentKind) -> [String: ToolResultData] {
        states[SessionKey(agent: agent, sessionId: sessionId)]?.structuredResults ?? [:]
    }

    /// 子 Agent 发起的工具调用（仅 Claude Code 有独立子 Agent 记录）。
    func subagentTools(sessionId: String, agent: AgentKind, agentId: String, cwd: String)
        -> [SubagentToolInfo]
    {
        AgentTranscriptSchemaRegistry.schema(for: agent)
            .subagentTools(sessionId: sessionId, agentId: agentId, cwd: cwd)
    }

    /// 丢弃某个会话的解析状态（重新加载时使用）。
    func resetState(sessionId: String, agent: AgentKind) {
        states.removeValue(forKey: SessionKey(agent: agent, sessionId: sessionId))
    }

    private static let emptyInfo = ConversationInfo(
        summary: nil,
        lastMessage: nil,
        lastMessageRole: nil,
        lastToolName: nil,
        firstUserMessage: nil,
        lastUserMessageDate: nil
    )
}
