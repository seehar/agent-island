//
//  AgentIsland/Services/Hooks/PendingPermission.swift
//  AgentIsland
//
//  待批许可的登记键、等待记录与卡片展示档位，以及事件/失败回调的类型。
//

import Foundation

/// 待批许可的字典键：会话（Agent + 会话 id）+ 会话内的工具调用 id。
/// 只用裸 `toolUseId` 当键会让不同 Agent / 会话的同名 id 互相覆盖或误关。
nonisolated struct PendingPermissionKey: Hashable {
    let key: SessionKey
    let toolUseId: String
}

/// Pending permission request waiting for user decision
nonisolated struct PendingPermission: Sendable {
    /// 该许可所属的会话；日志与失败回调都按它归属。
    let key: SessionKey
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// 待批卡片要用的展示档位。全部取自集成上报的信封；缺省表示老集成没报，
/// 卡片按「普通档 + 闸门正常」渲染。
nonisolated struct PendingApprovalDisplay: Equatable, Sendable {
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
