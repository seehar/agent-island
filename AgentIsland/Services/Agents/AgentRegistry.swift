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
        .codex: CodexAgentProvider(),
        .gemini: GeminiAgentProvider(),
        .cursor: CursorAgentProvider(),
        .copilot: CopilotAgentProvider(),
        .qoder: ClaudeFamilyAgentProvider(kind: .qoder),
        .factory: ClaudeFamilyAgentProvider(kind: .factory),
        .codeBuddy: ClaudeFamilyAgentProvider(kind: .codeBuddy),
        .kimi: KimiAgentProvider(),
        .cline: ClineAgentProvider(),
        .grok: GrokAgentProvider(),
        .trae: PlainConfigOnlyAgentProvider(kind: .trae),
        .traeCli: PlainConfigOnlyAgentProvider(kind: .traeCli),
        .deepSeekHarness: PlainConfigOnlyAgentProvider(kind: .deepSeekHarness),
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

}

// MARK: - 跨 Provider 共用的事实

/// 环境变量覆盖配置根的解析（`$CODEX_HOME` / `$GROK_HOME`）：空值视为未设置，
/// `~` 与 `~/` 展开到传入的 home。
///
/// 与 `AgentHooks.swift` 里 `AgentHookSpec.rootEnvVar` 是同一套语义（事实来源：
/// CodeIsland `ConfigInstaller.codexHome()` / `grokHome()`）。Provider 必须提前把
/// 根解析出来才能推导记录路径，并且要能用注入的 home 跑用例，所以在这里落一份
/// 可注入的实现。
nonisolated enum AgentRootOverride {
    /// 解析结果；未设置或空白时返回 `fallback`。
    static func resolve(_ raw: String?, fallback: URL, home: URL) -> URL {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // 环境变量指过来的目录同样要解析符号链接：它可能是一个软链，而
        // `FileManager` 的遍历结果永远是解析后的写法（见 AgentProviderRoot）。
        guard !trimmed.isEmpty else { return AgentProviderRoot.canonical(fallback) }
        if trimmed == "~" { return AgentProviderRoot.canonical(home) }
        if trimmed.hasPrefix("~/") {
            return AgentProviderRoot.canonical(
                home.appendingPathComponent(String(trimmed.dropFirst(2))))
        }
        return AgentProviderRoot.canonical(URL(fileURLWithPath: trimmed))
    }
}

nonisolated extension AgentProvider {
    /// 配置文件型 hook Agent 的集成状态。
    ///
    /// 「哪个 Agent 装好了」只能有一个事实源：一律问 `AgentConfigInstaller` —— 它按
    /// `AgentHookSpec` 写配置、也按同一张表读回。Provider 不自己解析配置文本，否则
    /// 设置行的文案、注册表的闸门判断与安装器会各说一套。
    /// 没有配置文件型集成的 Agent（DSH 等 `hookSpec == nil`）返回 nil。
    func hookConfigIntegrationStatus(home: URL, isAvailable: Bool) -> AgentIntegrationStatus? {
        guard kind.hookSpec != nil else { return nil }
        guard isAvailable else {
            // 配置根不存在 = 工具没装（不是「装了但没装我们的条目」）。
            return AgentIntegrationStatus(health: .unavailable, installedFiles: [])
        }
        let installed = AgentConfigInstaller.isInstalled(kind, home: home)
        return AgentIntegrationStatus(
            health: installed ? .installed : .missing,
            installedFiles: AgentConfigInstaller.installedFiles(kind, home: home)
        )
    }
}
