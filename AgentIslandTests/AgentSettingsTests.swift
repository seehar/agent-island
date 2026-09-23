//
//  AgentSettingsTests.swift
//  AgentIslandTests
//
//  「监控哪些 Agent」的启用口径与「逐 Agent 配置目录」的读写契约。
//  这两条一旦算错，用户的监控列表会被静默改掉（升级用户掉线、或全新安装被被动
//  接管工具配置），因此迁移的判定被抽成纯函数在这里钉住。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("监控启用口径")
struct AgentEnablementTests {
    @Test("全新安装：一个都不启用（默认关闭）")
    func freshInstallEnablesNothing() {
        #expect(AppSettings.enablementAfterMigration(legacyDisabled: [], isFreshInstall: true).isEmpty)
        // 即使旧域里带着一堆禁用项，全新安装也不该反过来启用任何东西。
        #expect(
            AppSettings.enablementAfterMigration(
                legacyDisabled: [AgentKind.pi.rawValue], isFreshInstall: true
            ).isEmpty)
    }

    @Test("升级：保留改口径之前就默认启用、且用户没显式关掉的那些")
    func upgradeKeepsLegacyDefaultsOnly() {
        let upgraded = AppSettings.enablementAfterMigration(legacyDisabled: [], isFreshInstall: false)
        #expect(upgraded == Set(AgentKind.defaultEnabledBeforeOptIn.map(\.rawValue)))
        // 本特性新接入的 Agent 不在其中：它们是「旧口径默认全开」的副作用，不是用户的选择。
        for kind in [AgentKind.codex, .gemini, .cursor, .kimi, .cline, .trae, .deepSeekHarness] {
            #expect(!upgraded.contains(kind.rawValue), "\(kind.rawValue) 不该被迁移启用")
        }
    }

    @Test("升级：用户显式关掉过的那些不会因为换口径而复活")
    func upgradeHonoursExplicitDisables() {
        let upgraded = AppSettings.enablementAfterMigration(
            legacyDisabled: [AgentKind.pi.rawValue, AgentKind.opencode.rawValue],
            isFreshInstall: false)
        #expect(!upgraded.contains(AgentKind.pi.rawValue))
        #expect(!upgraded.contains(AgentKind.opencode.rawValue))
        #expect(upgraded.contains(AgentKind.claudeCode.rawValue))
        #expect(upgraded.contains(AgentKind.ohMyPi.rawValue))
    }

    @Test("历史默认集合与「本特性新增」的边界没有重叠")
    func legacyDefaultsAreTheOriginalFour() {
        #expect(
            Set(AgentKind.defaultEnabledBeforeOptIn.map(\.rawValue))
                == ["claude", "omp", "pi", "opencode"])
        // 新增的 13 个 Agent 一个都不能落在历史默认集合里。
        let added = Set(AgentKind.allCases.map(\.rawValue))
            .subtracting(AgentKind.defaultEnabledBeforeOptIn.map(\.rawValue))
        #expect(added.count == AgentKind.allCases.count - 4)
    }
}

@Suite("「此前跑过没跑过」的判据")
struct PreviousInstallFootprintTests {
    @Test("空目录 = 全新安装；任一集成文件存在 = 跑过")
    func footprintFilesDecideFreshness() throws {
        let home = AgentProviderRoot.canonical(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("footprint-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // 全新安装：偏好域可能已经被同一次启动的改名迁移写过标记，但磁盘上没有任何足迹。
        // 判据如果看偏好域，就会把这里判成「升级」——那正是本条用例要防的回归。
        #expect(!AppSettings.hasInstallFootprintFiles(home: home))

        // 上一版装的共享脚本（现行落点）
        let script = home.appendingPathComponent(".agent-island/hooks/agent-island-state.py")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(AppSettings.hasInstallFootprintFiles(home: home))
    }

    @Test("改名前的旧脚本也算足迹")
    func legacyScriptCounts() throws {
        let home = AgentProviderRoot.canonical(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("footprint-legacy-\(UUID().uuidString)"))
        let script = home.appendingPathComponent(".claude/hooks/claude-island-state.py")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# old\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AppSettings.hasInstallFootprintFiles(home: home))
    }
}

@Suite("旧口径 Claude 目录的迁移")
struct ClaudeDirectoryMigrationTests {
    @Test("默认值与空值都等于「自动检测」，不进覆盖表")
    func defaultsDoNotBecomeOverrides() {
        #expect(AppSettings.claudeOverrideAfterMigration(legacyDirectoryName: "") == nil)
        #expect(AppSettings.claudeOverrideAfterMigration(legacyDirectoryName: "   ") == nil)
        #expect(AppSettings.claudeOverrideAfterMigration(legacyDirectoryName: ".claude") == nil)
    }

    @Test("绝对路径原样、家目录下的名字补成 ~/ 形式")
    func customValuesBecomeOverrides() {
        #expect(
            AppSettings.claudeOverrideAfterMigration(
                legacyDirectoryName: "/Volumes/work/claude") == "/Volumes/work/claude")
        #expect(
            AppSettings.claudeOverrideAfterMigration(
                legacyDirectoryName: ".claude-internal") == "~/.claude-internal")
    }
}

@Suite("关闭的 Agent 的事件在门口丢弃", .serialized)
struct DisabledAgentIngressTests {
    /// 真实 socket 是绑在固定路径上的单例（`/tmp/agent-island.sock`），用例里绑它会与
    /// 正在运行的应用抢路径，所以这里测的是**策略函数**本身——它正是入站那条 guard 用的。
    @Test("未启用 → 丢弃；启用后 → 放行")
    func ingressHonoursEnablement() {
        let kind = AgentKind.codex
        let original = AppSettings.isAgentEnabled(kind)
        defer { AppSettings.setAgent(kind, enabled: original) }

        let event = HookEvent(
            sessionId: "s", cwd: "/tmp", event: "SessionStart", status: "starting", pid: nil,
            tty: nil, tool: nil, toolInput: nil, toolUseId: nil, notificationType: nil,
            message: nil, agent: kind.rawValue, sessionFile: nil)

        AppSettings.setAgent(kind, enabled: false)
        #expect(HookSocketServer.shouldIgnore(event), "关掉的 Agent 的事件必须在门口丢掉")

        AppSettings.setAgent(kind, enabled: true)
        #expect(!HookSocketServer.shouldIgnore(event), "启用之后必须放行")
    }

    @Test("缺省（旧 hook 不带 agent 字段）按 Claude 处理，且跟着 Claude 的开关走")
    func legacyEnvelopeFollowsClaudeEnablement() {
        let original = AppSettings.isAgentEnabled(.claudeCode)
        defer { AppSettings.setAgent(.claudeCode, enabled: original) }

        let event = HookEvent(
            sessionId: "s", cwd: "/tmp", event: "SessionStart", status: "starting", pid: nil,
            tty: nil, tool: nil, toolInput: nil, toolUseId: nil, notificationType: nil,
            message: nil, agent: nil, sessionFile: nil)

        AppSettings.setAgent(.claudeCode, enabled: false)
        #expect(HookSocketServer.shouldIgnore(event))
        AppSettings.setAgent(.claudeCode, enabled: true)
        #expect(!HookSocketServer.shouldIgnore(event))
    }
}

@Suite("逐 Agent 配置目录", .serialized)
struct AgentRootOverrideSettingsTests {
    @Test("写入 / 读取 / 清除（含空白的归一）")
    func roundTripOverride() {
        let kind = AgentKind.trae
        let original = AppSettings.agentRootOverride(kind)
        defer { AppSettings.setAgentRootOverride(kind, path: original) }

        #expect(AppSettings.agentRootOverride(kind) == original)
        AppSettings.setAgentRootOverride(kind, path: "/tmp/custom-trae")
        #expect(AppSettings.agentRootOverride(kind) == "/tmp/custom-trae")
        // 空白等于没设：界面里清空输入框应当回到自动检测。
        AppSettings.setAgentRootOverride(kind, path: "   ")
        #expect(AppSettings.agentRootOverride(kind) == nil)
        AppSettings.setAgentRootOverride(kind, path: nil)
        #expect(AppSettings.agentRootOverride(kind) == nil)
    }
}
