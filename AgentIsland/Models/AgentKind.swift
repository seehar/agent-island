//
//  AgentKind.swift
//  AgentIsland
//
//  notch 支持监控的编码 Agent 集合。所有与具体 Agent 相关的差异（路径、
//  记录格式、实时事件接入）都收敛到这个枚举上，其余代码保持 Agent 无关。
//

import Foundation

/// 某个 Agent 的审批能力：决定「刘海上的批准/拒绝能否真正回传给该 Agent」，以及
/// 该 Agent 用哪个事件名请求审批。纯数据，避免能力判断散落到各个调用点。
nonisolated struct ApprovalCapability: Sendable {
    /// 刘海上的决定能否真正回传给该 Agent（为假时 UI 只提示「在终端中批准」）。
    let canDecideRemotely: Bool
    /// 该 Agent 的集成会阻塞等待应答；决定服务端是否保留 socket fd。
    let waitsForDecision: Bool
    /// 该 Agent 用来请求审批的事件名。
    let requestEvent: String
}

/// 受支持的编码 Agent CLI。
nonisolated enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Anthropic Claude Code（`claude`）。
    case claudeCode = "claude"
    /// Oh My Pi（`omp`）。
    case ohMyPi = "omp"
    /// Pi coding agent（`pi`）。
    case pi = "pi"
    /// OpenCode（`opencode`）。
    case opencode = "opencode"

    var id: String { rawValue }

    /// 面向用户的产品名。产品名在 `zh-Hans` 里是原文映射，保留 key 只是为了让
    /// 这些名字日后可被覆盖，而不是硬编码在代码里。本类型是 `nonisolated`，
    /// 因此走 `LocalizationManager` 的非隔离静态入口。
    var displayName: String {
        switch self {
        case .claudeCode: return LocalizationManager.t("Claude Code")
        case .ohMyPi: return LocalizationManager.t("Oh My Pi")
        case .pi: return LocalizationManager.t("Pi")
        case .opencode: return LocalizationManager.t("OpenCode")
        }
    }

    /// 紧凑标签，用于会话行、角标等密集 UI。
    var shortName: String {
        switch self {
        case .claudeCode: return LocalizationManager.t("Claude")
        case .ohMyPi: return LocalizationManager.t("OMP")
        case .pi: return LocalizationManager.t("Pi")
        case .opencode: return LocalizationManager.t("OpenCode")
        }
    }

    /// CLI 可执行文件名，用于进程发现。
    var binaryName: String {
        switch self {
        case .claudeCode: return "claude"
        case .ohMyPi: return "omp"
        case .pi: return "pi"
        case .opencode: return "opencode"
        }
    }

    /// 该 Agent 的审批能力。`canDecideRemotely` 为真时 notch 才给出批准/拒绝
    /// 入口并回传决定；`waitsForDecision` 与 `requestEvent` 描述集成侧的等待
    /// 方式与事件名（扩展 / 插件据此实现阻塞闸门）。
    var approval: ApprovalCapability {
        switch self {
        case .claudeCode:
            return .init(
                canDecideRemotely: true, waitsForDecision: true,
                requestEvent: "PermissionRequest")
        case .ohMyPi, .pi, .opencode:
            return .init(
                canDecideRemotely: true, waitsForDecision: true, requestEvent: "ToolApproval")
        }
    }

    /// 是否需要用户安装集成（hook 脚本 / 扩展 / 插件）才能上报实时事件。
    /// 为 false 时仅靠读取记录推断状态。
    var requiresIntegrationInstall: Bool {
        switch self {
        case .claudeCode, .ohMyPi, .pi: return true
        case .opencode: return false
        }
    }

    /// 该 Agent 用来派生 subAgent 的工具名：
    /// - Claude Code：`Agent`（新名）/ `Task`（旧名）
    /// - omp / pi / opencode：`task`
    var subagentToolNames: [String] {
        switch self {
        case .claudeCode: return ["Agent", "Task"]
        case .ohMyPi, .pi, .opencode: return ["task"]
        }
    }

    /// 全部 Agent 的 subAgent 派生工具名并集。实时事件只带工具名、不带 Agent
    /// 归属，因此按并集判定；各 Agent 之间名称互不冲突。
    static let allSubagentToolNames: Set<String> = Set(allCases.flatMap(\.subagentToolNames))

    /// 该 Agent 的集成是否会**上报子 Agent 内部的工具调用**。只有 Claude Code
    /// 具备这条通道（hook + 子 Agent 记录）；omp/pi 的扩展与 opencode 插件只上报
    /// 根会话，因此对它们不能把「Task 运行期间到达的其它工具」当成子 Agent 内部调用。
    var reportsSubagentInnerTools: Bool {
        self == .claudeCode
    }
}
