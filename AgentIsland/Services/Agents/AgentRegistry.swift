//
//  AgentRegistry.swift
//  AgentIsland
//
//  Agent 查找的唯一入口。应用里所有「与具体 Agent 有关」的判断都走这里，
//  调用点无需知道到底支持哪些 Agent。
//

import Foundation

/// 已启用 Agent 及其 Provider 的查找表。
nonisolated enum AgentRegistry {
    private static let all: [AgentKind: any AgentProvider] = [
        .claudeCode: ClaudeAgentProvider(),
        .ohMyPi: PiFamilyAgentProvider(kind: .ohMyPi),
        .pi: PiFamilyAgentProvider(kind: .pi),
        .opencode: OpenCodeAgentProvider(),
    ]

    /// 某个 Agent 的 Provider（与是否启用无关）。
    static func provider(for kind: AgentKind) -> any AgentProvider {
        // `all` 覆盖全部 AgentKind；这里给个兜底实现以避免强制解包。
        all[kind] ?? ClaudeAgentProvider()
    }

    /// 用户开启监控的 Agent。
    static var enabled: [AgentKind] {
        AgentKind.allCases.filter { AppSettings.isAgentEnabled($0) }
    }

    /// 已启用且配置目录存在的 Agent。
    static var enabledAndInstalled: [AgentKind] {
        enabled.filter { provider(for: $0).paths() != nil }
    }

    /// 已安装实时集成的 Agent。
    static func integrationInstalled(_ kind: AgentKind) -> Bool {
        provider(for: kind).integrationStatus()?.health == .installed
    }

    /// 需要用户安装实时事件集成的 Agent。
    static var installableIntegrations: [AgentKind] {
        enabled.filter { $0.requiresIntegrationInstall }
    }

    /// 判断某个会话记录文件属于哪个 Provider。
    /// Claude 与 pi 系都用 `.jsonl`，因此按固定顺序检查，先识别者获胜。
    static func provider(owningTranscript path: String) -> (any AgentProvider)? {
        for kind in enabledAndInstalled {
            let candidate = provider(for: kind)
            if candidate.isTranscriptFile(path) {
                return candidate
            }
        }
        return nil
    }
}
