//
//  DiscoveredAgentSession.swift
//  ClaudeIsland
//
//  由磁盘/数据库发现的会话：无需实时集成即可让 notch 认出「这个 Agent 正在
//  某个项目里干活」。
//

import Foundation

/// 一个被发现的 Agent 会话。
nonisolated struct DiscoveredAgentSession: Sendable, Equatable, Identifiable {
    let agent: AgentKind
    /// Agent 自己的会话 id。
    let sessionId: String
    /// 会话所属项目目录。
    let cwd: String
    /// 会话标题（Agent 记录里的标题、或首条用户消息）。
    let title: String?
    /// 记录文件；结构化存储的 Agent 为 nil。
    let transcriptPath: String?
    /// 最后一次写入的时间，用于判断活跃度与排序。
    let updatedAt: Date

    var id: String { SessionKey(agent: agent, sessionId: sessionId).rawValue }
}

/// 能枚举「最近有活动的会话」的 Agent 需要实现的能力。
///
/// JSONL 类 Agent 靠记录文件目录扫描实现；结构化存储的 Agent（OpenCode）
/// 查询自家数据库。
nonisolated protocol AgentSessionDiscoverySource: Sendable {
    /// 该发现实现所属的 Agent（与 `AgentProvider.kind` 保持同名）。
    var kind: AgentKind { get }

    /// `since` 之后有活动的会话，按活动时间从新到旧排序。
    func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession]
}

/// 会话在应用内的稳定标识：id 相同的不同 Agent 会话必须互不干扰。
nonisolated struct SessionKey: Hashable, Sendable, CustomStringConvertible {
    let agent: AgentKind
    let sessionId: String

    var rawValue: String { "\(agent.rawValue):\(sessionId)" }

    /// 从 `rawValue` 还原；格式非法时返回 nil。
    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        guard let agent = AgentKind(rawValue: String(rawValue[rawValue.startIndex..<separator]))
        else { return nil }
        self.agent = agent
        self.sessionId = String(rawValue[rawValue.index(after: separator)...])
    }

    init(agent: AgentKind, sessionId: String) {
        self.agent = agent
        self.sessionId = sessionId
    }

    var description: String { rawValue }
}
