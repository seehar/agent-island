//
//  SubagentToolInfo.swift
//  AgentIsland
//
//  从子 Agent 记录里解析出的工具调用信息（各 Agent 共用）。
//

import Foundation

/// 子 Agent 发起的一次工具调用。
nonisolated struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}
