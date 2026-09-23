//
//  SessionListOrdering.swift
//  AgentIsland
//
//  会话列表的显示顺序：视图与快捷键共用同一条，避免两处实现漂移。
//

import Foundation

/// 列表顺序与相位优先级。
///
/// 抽取自 `ClaudeInstancesView` 的私有实现：快捷键的上下移动、待批目标都按同一顺序定位，
/// 两处各写一份迟早会对不上。**可见性过滤不在这里**——那是视图的事（保留窗口、隐藏闲置），
/// 快捷键按视图写回的 `visibleSessionKeys` 定位。
nonisolated enum SessionListOrdering {
    /// 显示顺序：相位优先级（待批/处理中 > 等待输入 > 空闲）优先，其次按最后一条用户消息
    /// 时间倒序；没有用户消息时退回最后活动时间。用「用户消息时间」而不是最后活动时间：
    /// Agent 的回复不会让行跳动。
    static func sorted(_ sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// 相位优先级：数字越小越靠前。待批与处理中共用同一档，避免待批卡片随状态变化上下跳。
    static func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }
}
