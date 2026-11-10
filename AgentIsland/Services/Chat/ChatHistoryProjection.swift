//
//  ChatHistoryProjection.swift
//  AgentIsland
//
//  会话状态 → 聊天视图直接消费的形状：条目列表、子 Agent 描述。
//
//  原先这两项投影只存在于 `ChatHistoryManager.updateFromSessions` 里（一个 `@MainActor`
//  的私有方法），于是「哪些条目该摘掉」这条规则既不能单测、也随镜像类一起消失在视图之外。
//  抽成纯函数后：视图与镜像走同一份实现，过滤规则可以直接断言。
//

import Foundation

/// 会话状态的只读投影（纯函数，不持有状态）。
nonisolated enum ChatHistoryProjection {
    /// 一条会话要显示的条目。
    static func items(for session: SessionState) -> [ChatHistoryItem] {
        items(from: session.chatItems)
    }

    /// 从扁平条目列表里摘掉**子 Agent 容器内部**的工具调用。
    ///
    /// 那些调用已经折叠进容器卡片（`ToolCallView` 的 `presentsAsSubagentContainer` 那条
    /// 分支），再单独出现在列表里就是同一件事画两遍。容器本身保留——它是入口。
    /// 没有容器时走零分配的快路径：绝大多数会话都是这样。
    static func items(from chatItems: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIds = Set<String>()
        for item in chatItems {
            guard case .toolCall(let tool) = item.type, tool.isSubagentContainer else { continue }
            for subagentTool in tool.subagentTools {
                subagentToolIds.insert(subagentTool.id)
            }
        }
        guard !subagentToolIds.isEmpty else { return chatItems }
        return chatItems.filter { !subagentToolIds.contains($0.id) }
    }

    /// 全部会话的投影（按会话分桶）。
    ///
    /// 只做一次遍历：每轮会话状态发布会走这条路径，重复遍历两遍（条目、描述）没有必要。
    static func project(_ sessions: [SessionState]) -> (
        histories: [SessionKey: [ChatHistoryItem]],
        agentDescriptions: [SessionKey: [String: String]]
    ) {
        var histories: [SessionKey: [ChatHistoryItem]] = [:]
        var descriptions: [SessionKey: [String: String]] = [:]
        histories.reserveCapacity(sessions.count)
        descriptions.reserveCapacity(sessions.count)
        for session in sessions {
            histories[session.sessionKey] = items(for: session)
            descriptions[session.sessionKey] = session.subagentState.agentDescriptions
        }
        return (histories, descriptions)
    }
}
