//
//  AgentKind.swift
//  ClaudeIsland
//
//  notch 支持监控的编码 Agent 集合。所有与具体 Agent 相关的差异（路径、
//  记录格式、实时事件接入）都收敛到这个枚举上，其余代码保持 Agent 无关。
//

import Foundation

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

    /// 该 Agent 是否提供可被 notch 拦截的审批提示。目前只有 Claude Code 的
    /// hook 协议支持从 notch 批准/拒绝，其余 Agent 只上报状态，审批仍走自身 UI。
    var supportsPermissionControl: Bool {
        self == .claudeCode
    }

    /// 是否需要用户安装集成（hook 脚本 / 扩展 / 插件）才能上报实时事件。
    /// 为 false 时仅靠读取记录推断状态。
    var requiresIntegrationInstall: Bool {
        switch self {
        case .claudeCode, .ohMyPi, .pi: return true
        case .opencode: return false
        }
    }
}
