//
//  SessionPhase.swift
//  AgentIsland
//
//  Explicit state machine for Claude session lifecycle.
//  All state transitions are validated before being applied.
//

import Foundation

/// Permission context for tools waiting for approval
nonisolated struct PermissionContext: Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date

    /// Format tool input for display
    var formattedInput: String? {
        guard let input = toolInput else { return nil }

        // For Bash, prioritize showing the command
        if toolName == "Bash", let command = input["command"]?.value as? String {
            return command.count > 100 ? String(command.prefix(100)) + "..." : command
        }

        // For Write/Edit, show the file path
        if toolName == "Write" || toolName == "Edit", let path = input["file_path"]?.value as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        // For Read, show the file path
        if toolName == "Read", let path = input["file_path"]?.value as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        // Default: show first string value found (skip description)
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = input[key]?.value as? String {
                return value.count > 100 ? String(value.prefix(100)) + "..." : value
            }
        }

        // Fallback: first non-description string
        for (key, value) in input where key != "description" {
            if let str = value.value as? String {
                return str.count > 100 ? String(str.prefix(100)) + "..." : str
            }
        }

        return nil
    }
}

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields only (AnyCodable doesn't conform to Equatable)
        lhs.toolUseId == rhs.toolUseId &&
        lhs.toolName == rhs.toolName &&
        lhs.receivedAt == rhs.receivedAt
    }
}

/// Explicit session phases - the state machine
nonisolated enum SessionPhase: Sendable {
    /// Session is idle, waiting for user input or new activity
    case idle

    /// Claude is actively processing (running tools, generating response)
    case processing

    /// Claude has finished and is waiting for user input
    case waitingForInput

    /// A tool is waiting for user permission approval
    case waitingForApproval(PermissionContext)

    /// Context is being compacted (auto or manual)
    case compacting

    /// Session has ended
    case ended

    /// 进程已经不在、但相位本身还看得见时，这个相位能不能标成「已结束」。
    ///
    /// 等用户输入的相位例外：那多半是终端仍开着、Agent 已经退出，标成结束会让人
    /// 以为任务丢了；这些会话留在列表里，由空闲阈值回收（见 recheckAllSessions）。
    nonisolated func isPausableWhenProcessGone() -> Bool {
        switch self {
        case .idle, .waitingForInput:
            return false
        case .processing, .waitingForApproval, .compacting, .ended:
            return true
        }
    }

    // MARK: - State Machine Transitions

    /// Check if a transition to the target phase is valid
    nonisolated func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        // Terminal state - no transitions out
        case (.ended, _):
            return false

        // Any state can transition to ended
        case (_, .ended):
            return true

        // Idle transitions
        case (.idle, .processing):
            return true
        case (.idle, .waitingForApproval):
            return true  // Direct permission request on idle session
        case (.idle, .compacting):
            return true

        // Processing transitions
        case (.processing, .waitingForInput):
            return true
        case (.processing, .waitingForApproval):
            return true
        case (.processing, .compacting):
            return true
        case (.processing, .idle):
            return true  // Interrupt or quick completion

        // WaitingForInput transitions
        case (.waitingForInput, .processing):
            return true
        case (.waitingForInput, .idle):
            return true  // Can become idle
        case (.waitingForInput, .compacting):
            return true

        // WaitingForApproval transitions
        case (.waitingForApproval, .processing):
            return true  // Approved - tool will run
        case (.waitingForApproval, .idle):
            return true  // Denied or cancelled
        case (.waitingForApproval, .waitingForInput):
            return true  // Denied and Claude stopped
        case (.waitingForApproval, .waitingForApproval):
            return true  // Another tool needs approval (multiple pending permissions)

        // Compacting transitions
        case (.compacting, .processing):
            return true
        case (.compacting, .idle):
            return true
        case (.compacting, .waitingForInput):
            return true

        // Allow staying in same state (no-op transitions)
        default:
            return self == next
        }
    }

    /// Attempt to transition to a new phase, returns the new phase if valid
    nonisolated func transition(to next: SessionPhase) -> SessionPhase? {
        canTransition(to: next) ? next : nil
    }

    /// 有活着的待批时，一条「状态上报」要不要被相位机挡下。
    ///
    /// 待批是**已经发生的事实**（服务端还攥着那条等应答的连接），状态上报只是描述；两者
    /// 冲突时以事实为准。现实里这条冲突很常见：闸门版集成先发闸门信封、后发 `PreToolUse`
    /// （两条独立连接、彼此不保序），实测 `PreToolUse` 会在 74ms 后把相位推回 `processing`，
    /// 卡片随之消失——工具于是一直挂到客户端预算耗尽被静默拒绝，用户侧毫无反馈。
    ///
    /// 同一类冲突还有两条**把卡片彻底抹掉**的路径（2026-09-22 实测：Claude 的提问卡出现
    /// 十几秒后自己消失，而待批连接还挂着、用户再也点不到）：
    /// * 会话发现给刚由实时事件建立的会话补发一条 `SessionStart` + `status: idle` → `.idle`
    ///   （源头已另修：`AgentSessionDiscovery` 不再给库里已有的会话补登）；
    /// * Claude 在等待期间发 `Notification(idle_prompt)` → `.idle`。
    /// 两者都会让相位离开「等待审批」。`.idle` 因此一并挡住——它是「什么都没发生」的描述，
    /// 而待批是可点的事实。
    ///
    /// 放行的三类：`.ended`（进程退出/会话结束是既成事实）、`.waitingForInput`（`Stop`：
    /// 终端里已经收手，那条待批已无意义）、`.compacting`（压缩是真实活动，且压缩结束后
    /// 会有新的状态上报）。`.waitingForApproval` 自身也照旧放行（并发待批）。
    nonisolated static func statusUpdateBlockedByPending(
        current: SessionPhase, next: SessionPhase, hasLivePending: Bool
    ) -> Bool {
        guard current.isWaitingForApproval, hasLivePending else { return false }
        return next == .processing || next == .idle
    }

    /// Whether this phase indicates the session needs user attention
    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput:
            return true
        default:
            return false
        }
    }

    /// Whether this phase indicates active processing
    var isActive: Bool {
        switch self {
        case .processing, .compacting:
            return true
        default:
            return false
        }
    }

    /// Whether this is a waitingForApproval phase
    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Extract tool name if waiting for approval
    var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self {
            return ctx.toolName
        }
        return nil
    }
}

// MARK: - Equatable

extension SessionPhase: Equatable {
    nonisolated static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.processing, .processing): return true
        case (.waitingForInput, .waitingForInput): return true
        case (.waitingForApproval(let ctx1), .waitingForApproval(let ctx2)):
            return ctx1 == ctx2
        case (.compacting, .compacting): return true
        case (.ended, .ended): return true
        default: return false
        }
    }
}

// MARK: - Debug Description

nonisolated extension SessionPhase: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .idle:
            return "idle"
        case .processing:
            return "processing"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForApproval(let ctx):
            return "waitingForApproval(\(ctx.toolName))"
        case .compacting:
            return "compacting"
        case .ended:
            return "ended"
        }
    }
}
