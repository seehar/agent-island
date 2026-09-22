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

    /// 总 token = 输入 + 输出 + 缓存读 + 缓存写。
    ///
    /// 与记录里的原始口径一致（omp / pi 的 `totalTokens` 就是这四项之和），
    /// 也与用量统计页一致——两处若不同，同一份数据会出现两个数。
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// 展示用短字符串（中文界面如 "1.1亿"，其它语言如 "106.6M"）。
    ///
    /// 量级与小数点符号都跟随界面语言：中文按「万 / 亿」，其余语言按 K / M 公制词头。
    /// 与统计页共用 `UsageTokenFormat`，同一份数据不会在两处显示成不同量级。
    var formattedTotal: String {
        let languageCode = AppSettings.language.resolvedCode
        return UsageTokenFormat.short(
            totalTokens,
            languageCode: languageCode,
            locale: Locale(identifier: languageCode)
        )
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
    /// 有磁盘记录的 Agent。同格式的 Agent 共用一份实现（Claude 系 / pi 系）。
    private static let schemas: [AgentKind: any AgentTranscriptSchema] = [
        .claudeCode: ClaudeTranscriptSchema(),
        .qoder: ClaudeFamilyTranscriptSchema(kind: .qoder),
        .factory: ClaudeFamilyTranscriptSchema(kind: .factory),
        .codeBuddy: CodeBuddyTranscriptSchema(),
        .ohMyPi: PiTranscriptSchema(kind: .ohMyPi),
        .pi: PiTranscriptSchema(kind: .pi),
        .opencode: OpenCodeTranscriptSchema(),
        .codex: CodexTranscriptSchema(),
        .gemini: GeminiTranscriptSchema(),
        .cursor: CursorTranscriptSchema(),
        .copilot: CopilotTranscriptSchema(),
        .kimi: KimiTranscriptSchema(),
        .cline: ClineTranscriptSchema(),
        .grok: GrokTranscriptSchema(),
    ]

    /// 没有可解析记录的 Agent：Trae 与 Trae CLI 不落盘对话记录，DSH 的记录是
    /// zstd 压缩（Swift 侧没有 zstd API）。它们共用空解析器：不产出历史，
    /// 也不假装读过什么。
    private static let emptySchemas: [AgentKind: EmptyTranscriptSchema] = [
        .trae: EmptyTranscriptSchema(kind: .trae),
        .traeCli: EmptyTranscriptSchema(kind: .traeCli),
        .deepSeekHarness: EmptyTranscriptSchema(kind: .deepSeekHarness),
    ]

    /// 取某个 Agent 的记录解析器。
    ///
    /// 没有解析器的 Agent 返回**空解析器**，而不是回退到 Claude：把别的格式按
    /// Claude 的记录硬解会产出「看着有内容、其实是错的内容」，比没有历史更坏。
    static func schema(for kind: AgentKind) -> any AgentTranscriptSchema {
        if let schema = schemas[kind] { return schema }
        if let empty = emptySchemas[kind] { return empty }
        // 将来新增 Agent 忘了注册时留一行痕（空解析器的表现是「没有历史」，
        // 不留痕就查不出是漏注册还是真没有记录）。
        ConversationParser.logger.debug(
            "Agent \(kind.rawValue, privacy: .public) 未注册记录解析器，本次读取不产出历史"
        )
        return EmptyTranscriptSchema(kind: kind)
    }
}

/// 没有可解析记录的 Agent 使用的空解析器。
nonisolated final class EmptyTranscriptSchema: AgentTranscriptSchema {
    let agent: AgentKind

    init(kind: AgentKind) {
        self.agent = kind
    }

    /// 没有记录文件。
    func transcriptFile(sessionId: String, cwd: String) -> URL? { nil }

    /// 什么都不产出（连「有新内容」都不报：没有记录可读）。
    func read(sessionId: String, cwd: String, state: inout TranscriptParseState)
        -> TranscriptReadResult
    {
        TranscriptReadResult.empty
    }
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// 跨上下文使用的日志器。
    nonisolated static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Session")

    /// 解析状态缓存保留的会话数上限。
    ///
    /// 依据：单个 `TranscriptParseState` 会累积整个会话的 messages / toolResults /
    /// structuredResults，一段几万行的会话就是数 MB 的数组；而解析器在整个进程
    /// 生命周期里为每个见过的会话各留一份，是全应用唯一没有上限的常驻容器。
    /// 64 覆盖「当前活跃 + 最近回看」的量级（同时开着的会话通常个位数），
    /// 超出后先释放最久未访问的状态。
    private static let maxCachedStates = 64

    /// 各会话的解析状态，按 (Agent, 会话 id) 隔离。
    private var states: [SessionKey: TranscriptParseState] = [:]

    /// 每个会话最后一次被读取的顺序号，用于淘汰最久未访问的状态。
    private var lastAccessTick: [SessionKey: UInt64] = [:]

    /// 单调递增的读取顺序号。
    private var accessTick: UInt64 = 0

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
        noteAccess(key)
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
        let key = SessionKey(agent: agent, sessionId: sessionId)
        states.removeValue(forKey: key)
        // 访问顺序跟着状态一起清掉，避免留下过期的顺序号参与淘汰比较。
        lastAccessTick.removeValue(forKey: key)
    }

    // MARK: - 缓存上限

    /// 记录一次读取，并在缓存超出上限时淘汰最久未访问的会话。
    ///
    /// 解析器内部看不到「会话是否已结束」（那属于 `SessionStore` 的职责，这里不
    /// 反向依赖），唯一可用的「非活跃」判据就是「已经很久没有人读它」：仍在被
    /// 增量读取的会话每次都会把自己的顺序号刷到最新，因此按访问顺序做 LRU 淘汰
    /// 即可，正在读取的会话永远排在队尾。
    private func noteAccess(_ key: SessionKey) {
        accessTick &+= 1
        lastAccessTick[key] = accessTick
        guard states.count > Self.maxCachedStates else { return }
        let released = evictLeastRecentlyUsedStates()
        guard released > 0 else { return }
        Self.logger.debug(
            "解析状态缓存超出 \(Self.maxCachedStates, privacy: .public) 个会话的上限，已释放 \(released, privacy: .public) 个最久未访问的状态"
        )
    }

    /// 把解析状态缓存压回上限之内，返回释放掉的会话数。
    private func evictLeastRecentlyUsedStates() -> Int {
        var released = 0
        while states.count > Self.maxCachedStates,
            let victim = states.keys.min(by: {
                lastAccessTick[$0, default: 0] < lastAccessTick[$1, default: 0]
            })
        {
            states.removeValue(forKey: victim)
            lastAccessTick.removeValue(forKey: victim)
            released += 1
        }
        return released
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
