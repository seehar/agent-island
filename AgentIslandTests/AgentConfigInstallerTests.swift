//
//  AgentConfigInstallerTests.swift
//  AgentIslandTests
//
//  配置文件型 hook 安装器的用例：全部在**临时 home** 里跑，不碰真实的 ~ / ~/.gemini /
//  $CODEX_HOME…（落点全部由 `home:` 参数注入；只有 codex/grok 的根目录来自环境变量，
//  那两个用例自己 setenv 并在结束时复原）。
//
//  钉住三类事故：读不懂的配置被改写、重复安装产生漂移、卸载把别人的内容带走。
//
//  断言口径：**写入**的形状按解析后的结构比（JSON 落盘是 `.prettyPrinted + .sortedKeys`，
//  与用户原先的排版必然不同）；**卸载**的还原按逐字节比 —— 后者才是「有没有带走别人的
//  东西」的真判据。JSON 的逐字节基线取「原始未安装态的规范序列化」，因为安装本身就会把
//  文件重新序列化一次；为了不受这一点影响，另外再用「卸载后重装 == 第一次安装的字节」
//  钉住「卸载只摘走了我们自己的条目」。
//
//  用户指定目录（设置面板的目录选择器）也在这里钉住：它替换的是**该工具自己的根**，因此
//  `.gemini/settings.json` 变成 `<指定目录>/settings.json`（Cline 的 `Documents/Cline/Hooks`
//  变成 `<指定目录>/Hooks`），环境变量仍然压过它，指定到不存在的目录则整轮跳过。
//  这些用例会写进程级偏好（`UserDefaults.standard`），所以本 suite 是 `.serialized`。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("配置文件型 hook 安装器", .serialized)
struct AgentConfigInstallerTests {

    // MARK: - 夹具

    /// 每个用例一个独立临时 home。
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-island-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// 造目录（存在性闸门要的就是「该工具自己的目录」）。
    private func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    private func text(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    private func json(_ file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    /// 规范序列化（与安装器落盘用的是同一组选项），用于比对「除排版外是否一模一样」。
    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func eventEntries(
        _ root: [String: Any], _ configKey: String, _ event: String
    ) -> [[String: Any]] {
        ((root[configKey] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    /// 一个条目里所有命令（各格式放在不同键上，统一由 `AgentConfigMerger` 取）。
    private func commands(_ entry: [String: Any]) -> [String] {
        AgentConfigMerger.commandStrings(in: entry)
    }

    /// 事件表里指向本应用脚本的命令。
    private func ownCommands(
        _ root: [String: Any], _ configKey: String, _ event: String
    ) -> [String] {
        eventEntries(root, configKey, event).flatMap(commands)
            .filter { HookInstaller.isOwnHookCommand($0) }
    }

    /// 用户在设置面板里指定的配置目录（写的是与界面同一个键；进程级，结束后一律复原）。
    private func withRootOverride(_ kind: AgentKind, _ path: String?, _ body: () throws -> Void)
        throws
    {
        let previous = AppSettings.agentRootOverride(kind)
        AppSettings.setAgentRootOverride(kind, path: path)
        defer { AppSettings.setAgentRootOverride(kind, path: previous) }
        try body()
    }

    /// 环境变量临时改写（进程级；结束后一律复原）。
    private func withEnvironment(_ name: String, _ value: String?, _ body: () -> Void) {
        let previous = Foundation.ProcessInfo.processInfo.environment[name]
        if let value { _ = setenv(name, value, 1) } else { _ = unsetenv(name) }
        defer {
            if let previous { _ = setenv(name, previous, 1) } else { _ = unsetenv(name) }
        }
        body()
    }

    // MARK: - claude 家族（qoder / factory / codeBuddy）

    @Test("claude 格式（qoder）：matcher + 内层 hooks；审批事件 86400；命令不带 --event")
    func claudeFormatShape() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".qoder"))

        #expect(AgentConfigInstaller.install(.qoder, home: home))
        #expect(AgentConfigInstaller.isInstalled(.qoder, home: home))

        let root = try json(home.appendingPathComponent(".qoder/settings.json"))
        let entry = try #require(eventEntries(root, "hooks", "PreToolUse").first)
        #expect(entry["matcher"] as? String == "*")
        let handler = try #require((entry["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        #expect(handler["timeout"] as? Int == 5)

        let command = try #require(handler["command"] as? String)
        #expect(command.contains(AgentHookScript.shellPath(home: home)))
        #expect(command.contains("--source qoder"))
        // stdin 自带 hook_event_name：claude 格式是唯一不加 --event 的格式
        #expect(!command.contains("--event"))

        let approval = try #require(eventEntries(root, "hooks", "PermissionRequest").first)
        let approvalHandler = try #require((approval["hooks"] as? [[String: Any]])?.first)
        #expect(approvalHandler["timeout"] as? Int == 86_400)
    }

    @Test("qoder：已有他人条目时追加；重复安装字节相同；卸载后回到原始内容")
    func installIsIdempotentAndUninstallRestores() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".qoder/settings.json")
        let originalText = #"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/usr/local/bin/other-hook.sh","timeout":5}]}]}}"#
        try write(originalText, to: file)
        let originalObject = try JSONSerialization.jsonObject(with: Data(originalText.utf8))
        let original = try #require(originalObject as? [String: Any])

        #expect(AgentConfigInstaller.install(.qoder, home: home))
        let afterFirstInstall = try Data(contentsOf: file)

        #expect(AgentConfigInstaller.install(.qoder, home: home))
        let afterSecondInstall = try Data(contentsOf: file)
        #expect(afterSecondInstall == afterFirstInstall)

        // 别人的条目、别人的键都还在；我们的条目追加在其后
        let installed = try json(file)
        #expect(installed["model"] as? String == "opus")
        let installedCommands = eventEntries(installed, "hooks", "PreToolUse").flatMap(commands)
        #expect(installedCommands.first == "/usr/local/bin/other-hook.sh")
        #expect(installedCommands.count == 2)
        #expect(ownCommands(installed, "hooks", "PreToolUse").count == 1)

        // 备份留下的是安装前那一版
        let backup = file.appendingPathExtension("agent-island-backup")
        let backupContents = try Data(contentsOf: backup)
        #expect(backupContents == Data(originalText.utf8))

        AgentConfigInstaller.uninstall(.qoder, home: home)
        #expect(!AgentConfigInstaller.isInstalled(.qoder, home: home))

        let uninstalled = try json(file)
        #expect(uninstalled["model"] as? String == "opus")
        #expect(eventEntries(uninstalled, "hooks", "PreToolUse").flatMap(commands)
            == ["/usr/local/bin/other-hook.sh"])
        // 除排版外，内容与原始一模一样
        let uninstalledCanonical = try canonical(uninstalled)
        let originalCanonical = try canonical(original)
        #expect(uninstalledCanonical == originalCanonical)
        // 卸载没有多摘也没有少摘：再装一次应回到第一次安装后的字节
        #expect(AgentConfigInstaller.install(.qoder, home: home))
        let afterReinstall = try Data(contentsOf: file)
        #expect(afterReinstall == afterFirstInstall)
    }

    @Test("未闭合的 JSON：返回 false，一个字节都不写，也不留备份")
    func malformedJSONIsLeftUntouched() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".cursor/hooks.json")
        try write(#"{"hooks": {"beforeSubmitPrompt": ["#, to: file)
        let before = try Data(contentsOf: file)

        #expect(AgentConfigInstaller.install(.cursor, home: home) == false)

        let after = try Data(contentsOf: file)
        #expect(after == before)
        let backup = file.appendingPathExtension("agent-island-backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!AgentConfigInstaller.isInstalled(.cursor, home: home))
    }

    // MARK: - flat / nested / traeIDE / copilot

    @Test("flat 格式（cursor）：条目只有 command；CRLF 文件里的他人条目照旧；带 --event")
    func cursorFlatShapeAndCRLF() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".cursor/hooks.json")
        let original = "{\r\n    \"theme\": \"dark\",\r\n    \"hooks\": {\r\n        \"beforeSubmitPrompt\": [\r\n            { \"command\": \"/usr/local/bin/other.sh\" }\r\n        ]\r\n    }\r\n}\r\n"
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.cursor, home: home))

        let installed = try json(file)
        #expect(installed["theme"] as? String == "dark")
        // 别人的条目在前、我们的追加在其后：取最后一条才是本应用写的那条。
        let entries = eventEntries(installed, "hooks", "beforeSubmitPrompt")
        #expect(entries.count == 2, "他人条目必须保留，我们的追加在其后")
        let entry = try #require(entries.last)
        #expect(entry["hooks"] as? [[String: Any]] == nil)
        // 超时不在 flat 条目里（上游形状没有这个键）
        #expect(entry["timeout"] as? Int == nil)
        let command = try #require(entry["command"] as? String)
        #expect(command.contains("--event beforeSubmitPrompt"))
        #expect(command.contains("--source cursor"))

        AgentConfigInstaller.uninstall(.cursor, home: home)
        let uninstalled = try json(file)
        #expect(eventEntries(uninstalled, "hooks", "beforeSubmitPrompt").flatMap(commands)
            == ["/usr/local/bin/other.sh"])
        #expect(uninstalled["theme"] as? String == "dark")
    }

    @Test("nested 格式（gemini）：没有 matcher；超时按毫秒；命令带 --event")
    func geminiNestedShapeAndMilliseconds() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".gemini"))

        #expect(AgentConfigInstaller.install(.gemini, home: home))

        let root = try json(home.appendingPathComponent(".gemini/settings.json"))
        let entry = try #require(eventEntries(root, "hooks", "BeforeTool").first)
        #expect(entry["matcher"] as? String == nil)
        let handler = try #require((entry["hooks"] as? [[String: Any]])?.first)
        // Gemini 的 timeout 单位是毫秒（24h 的阻塞审批 = 86_400_000，不是 86_400）
        #expect(handler["timeout"] as? Int == 86_400_000)
        let command = try #require(handler["command"] as? String)
        #expect(command.contains("--event BeforeTool"))

        let session = try #require(eventEntries(root, "hooks", "SessionStart").first)
        let sessionHandler = try #require((session["hooks"] as? [[String: Any]])?.first)
        #expect(sessionHandler["timeout"] as? Int == 10_000)
    }

    @Test("traeIDE 格式（trae）：空文件种下 version 1；条目带 matcher / loop_limit")
    func traeIDEFormatSeedsVersion() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".trae"))
        let file = home.appendingPathComponent(".trae/hooks.json")
        try write("", to: file)

        #expect(AgentConfigInstaller.install(.trae, home: home))

        let root = try json(file)
        #expect(root["version"] as? Int == 1)
        let entry = try #require(eventEntries(root, "hooks", "beforeShellExecution").first)
        #expect(entry["matcher"] as? String == "*")
        #expect(entry["loop_limit"] as? Int == 5)
        let handler = try #require((entry["hooks"] as? [[String: Any]])?.first)
        #expect(handler["timeout"] as? Int == 5)
        let command = try #require(handler["command"] as? String)
        #expect(command.contains("--event beforeShellExecution"))
    }

    @Test("copilot：条目是 bash + timeoutSec；用户自己设过的 version 不被覆盖")
    func copilotFormatKeepsUserVersion() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".copilot"))
        let file = home.appendingPathComponent(".copilot/hooks/agent-island.json")
        try write(#"{"version": 7}"#, to: file)

        #expect(AgentConfigInstaller.install(.copilot, home: home))

        let root = try json(file)
        #expect(root["version"] as? Int == 7)
        let entry = try #require(eventEntries(root, "hooks", "preToolUse").first)
        #expect(entry["type"] as? String == "command")
        #expect(entry["timeoutSec"] as? Int == 5)
        let bash = try #require(entry["bash"] as? String)
        #expect(bash.contains("--event preToolUse"))
        #expect(bash.contains("--source copilot"))
    }

    // MARK: - codex（hooks.json + [features] 开关）

    @Test("codex：hooks.json 落在根目录；config.toml 的 [features] hooks 三种情形")
    func codexRootsAndPrerequisite() throws {
        let home = try makeHome()

        // 情形一：$CODEX_HOME 未设 → 用 ~/.codex（不是把 hooks.json 写到 home 根上）
        try makeDirectory(home.appendingPathComponent(".codex"))
        withEnvironment("CODEX_HOME", nil) {
            #expect(AgentConfigInstaller.install(.codex, home: home))
        }
        let fallbackRoot = home.appendingPathComponent(".codex")
        #expect(FileManager.default.fileExists(atPath: fallbackRoot.appendingPathComponent("hooks.json").path))
        let seeded = try text(fallbackRoot.appendingPathComponent("config.toml"))
        #expect(seeded.contains("[features]"))
        #expect(seeded.contains("hooks = true"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks.json").path))

        // 情形二：$CODEX_HOME 有值 → 一切都在它下面；hooks = false 就地翻成 true（保留注释与其它键）
        let envRoot = home.appendingPathComponent("codex-env")
        try write("[features]\nhooks = false # 手改过\nmodel = \"gpt\"\n", to: envRoot.appendingPathComponent("config.toml"))
        withEnvironment("CODEX_HOME", envRoot.path) {
            #expect(AgentConfigInstaller.install(.codex, home: home))
        }
        #expect(FileManager.default.fileExists(atPath: envRoot.appendingPathComponent("hooks.json").path))
        let flipped = try text(envRoot.appendingPathComponent("config.toml"))
        #expect(flipped.contains("hooks = true # 手改过"))
        #expect(flipped.contains("model = \"gpt\""))

        // 情形三：已经是 hooks = true → 一个字节都不动
        let untouchedRoot = home.appendingPathComponent("codex-on")
        let untouchedConfig = untouchedRoot.appendingPathComponent("config.toml")
        let untouchedText = "[features]\nhooks = true\n"
        try write(untouchedText, to: untouchedConfig)
        withEnvironment("CODEX_HOME", untouchedRoot.path) {
            #expect(AgentConfigInstaller.install(.codex, home: home))
        }
        let after = try text(untouchedConfig)
        #expect(after == untouchedText)

        // 闸门：$CODEX_HOME 指向不存在的目录 → 跳过（返回 true），什么都不造
        let missingRoot = home.appendingPathComponent("codex-absent")
        withEnvironment("CODEX_HOME", missingRoot.path) {
            #expect(AgentConfigInstaller.install(.codex, home: home))
        }
        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    }

    @Test("grok：$GROK_HOME 下建出 hooks 子目录；未设时退到 ~/.grok（不碰 home 根）")
    func grokRootAndSubdirectory() throws {
        let home = try makeHome()
        let envRoot = home.appendingPathComponent("grok-env")
        try makeDirectory(envRoot)

        withEnvironment("GROK_HOME", envRoot.path) {
            #expect(AgentConfigInstaller.install(.grok, home: home))
        }
        let envFile = envRoot.appendingPathComponent("hooks/agent-island.json")
        #expect(FileManager.default.fileExists(atPath: envFile.path))
        let envRootObject = try json(envFile)
        let envCommands = ownCommands(envRootObject, "hooks", "PreToolUse")
        #expect(envCommands.count == 1)
        #expect(envCommands.first?.contains("--source grok") == true)

        // 未设 $GROK_HOME：退到 ~/.grok（CodeIsland grokHome() 的默认根），不往 home 根上写
        try makeDirectory(home.appendingPathComponent(".grok"))
        withEnvironment("GROK_HOME", nil) {
            #expect(AgentConfigInstaller.install(.grok, home: home))
        }
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".grok/hooks/agent-island.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks").path))
    }

    // MARK: - 闸门 / 不适用配置文件集成的 Agent

    @Test("存在性闸门：该工具自己的目录不存在就跳过，且不凭空造目录")
    func gateSkipsMissingToolDirectory() throws {
        let home = try makeHome()

        #expect(AgentConfigInstaller.install(.gemini, home: home))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path))
        #expect(!AgentConfigInstaller.isInstalled(.gemini, home: home))
        #expect(AgentConfigInstaller.installedFiles(.gemini, home: home).isEmpty)
    }

    @Test("不走配置文件集成的 Agent：install 返回 false、installedFiles 为空")
    func agentsWithoutConfigIntegration() throws {
        let home = try makeHome()

        for kind in [AgentKind.claudeCode, .ohMyPi, .pi, .opencode, .deepSeekHarness] {
            #expect(AgentConfigInstaller.install(kind, home: home) == false)
            #expect(AgentConfigInstaller.isInstalled(kind, home: home) == false)
            #expect(AgentConfigInstaller.installedFiles(kind, home: home).isEmpty)
        }
    }

    // MARK: - kimi（TOML）

    @Test("kimi：优先 ~/.kimi-code，其次 ~/.kimi；块形状正确；重复安装字节相同")
    func kimiRootPreferenceAndBlockShape() throws {
        let home = try makeHome()
        let legacyFile = home.appendingPathComponent(".kimi/config.toml")
        try makeDirectory(home.appendingPathComponent(".kimi"))

        #expect(AgentConfigInstaller.install(.kimi, home: home))
        #expect(FileManager.default.fileExists(atPath: legacyFile.path))
        #expect(AgentConfigInstaller.isInstalled(.kimi, home: home))
        let legacyContents = try Data(contentsOf: legacyFile)

        // 出现现代路径后改投那边，legacy 文件不被动
        try makeDirectory(home.appendingPathComponent(".kimi-code"))
        #expect(AgentConfigInstaller.install(.kimi, home: home))
        let modernFile = home.appendingPathComponent(".kimi-code/config.toml")
        let modern = try text(modernFile)
        let legacyAfterSecondInstall = try Data(contentsOf: legacyFile)
        #expect(AgentConfigInstaller.isInstalled(.kimi, home: home))
        #expect(legacyAfterSecondInstall == legacyContents)

        // 块形状：工具事件才带 matcher；超时按事件表逐字写；命令带 --event
        let toolBlock = try #require(kimiBlock(modern, event: "PreToolUse"))
        #expect(toolBlock.contains("command = \"") && toolBlock.contains("--source kimi"))
        #expect(toolBlock.contains("--event PreToolUse"))
        #expect(toolBlock.contains("matcher = \".*\""))
        let stopBlock = try #require(kimiBlock(modern, event: "Stop"))
        #expect(!stopBlock.contains("matcher"))
        #expect(stopBlock.contains("timeout = 5"))
        let notificationBlock = try #require(kimiBlock(modern, event: "Notification"))
        #expect(notificationBlock.contains("timeout = 600"))

        // 幂等
        let before = try Data(contentsOf: modernFile)
        #expect(AgentConfigInstaller.install(.kimi, home: home))
        let after = try Data(contentsOf: modernFile)
        #expect(after == before)
    }

    @Test("kimi：legacy 标量 hooks = … 安装时被注释、卸载后逐字节复原")
    func kimiLegacyScalarRoundTripRestoresBytes() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".kimi/config.toml")
        let original = "# kimi 配置\nmodel = \"kimi-k2\"\nhooks = [\"legacy\"]\n"
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.kimi, home: home))
        let installed = try text(file)
        #expect(installed.contains(AgentConfigMerger.kimiLegacyScalarMarker))
        #expect(installed.contains("# hooks = [\"legacy\"]"))
        #expect(installed.contains("[[hooks]]"))

        AgentConfigInstaller.uninstall(.kimi, home: home)
        let restored = try text(file)
        #expect(restored == original)
    }

    @Test("kimi：无结尾换行 / 两个尾部空行 / CRLF 三种文件都逐字节往返")
    func kimiTrailingBytesRoundTrip() throws {
        let fixtures = [
            "# kimi\nmodel = \"k2\"",              // 结尾没有换行
            "# kimi\nmodel = \"k2\"\n\n\n",        // 两个尾部空行
            "# kimi\r\nmodel = \"k2\"\r\n",        // CRLF 行尾
        ]
        for original in fixtures {
            let home = try makeHome()
            let file = home.appendingPathComponent(".kimi/config.toml")
            try write(original, to: file)

            #expect(AgentConfigInstaller.install(.kimi, home: home))
            #expect(AgentConfigInstaller.isInstalled(.kimi, home: home))
            let installed = try text(file)
            #expect(installed.contains("[[hooks]]"))

            #expect(AgentConfigInstaller.install(.kimi, home: home))
            let reinstalled = try text(file)
            #expect(reinstalled == installed)

            AgentConfigInstaller.uninstall(.kimi, home: home)
            let restored = try text(file)
            #expect(restored == original)
        }
    }

    @Test("kimi：表内的 hooks = 键不被当成 legacy 根标量（只在首个表头之前注释）")
    func kimiOnlyCommentsRootScalar() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".kimi/config.toml")
        let original = "model = \"k2\"\n\n[ui]\nhooks = \"inside-table\"\n"
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.kimi, home: home))
        let installed = try text(file)
        // TOML 的根键必须写在首个表头之前；表内同名键既不冲突，也不该被我们改
        #expect(installed.contains("[ui]\nhooks = \"inside-table\""))
        #expect(!installed.contains("# hooks = \"inside-table\""))

        AgentConfigInstaller.uninstall(.kimi, home: home)
        let restored = try text(file)
        #expect(restored == original)
    }

    /// TOML 文本里某个事件的托管块（块之间由一个空行分隔）。
    private func kimiBlock(_ contents: String, event: String) -> String? {
        contents.components(separatedBy: "\n\n").first {
            $0.contains("event = \"\(event)\"") && HookInstaller.isOwnHookCommand($0)
        }
    }

    // MARK: - traecli（YAML 行手术）

    @Test("traecli：行手术保住注释与键序；重复安装字节相同；卸载后逐字节复原")
    func traecliLineSurgeryKeepsForeignContent() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".trae/traecli.yaml")
        let original = """
        # traecli 配置
        theme: dark
        hooks:
          - type: command
            command: '/usr/local/bin/other-hook.sh'
            timeout: '5s'
        # 结尾注释

        """
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.traeCli, home: home))
        let installed = try text(file)
        #expect(installed.hasPrefix("# traecli 配置\ntheme: dark\nhooks:\n  - type: command\n"))
        #expect(installed.contains("--source traecli"))
        #expect(installed.contains("      - event: permission_request"))
        #expect(installed.contains("timeout: '86400s'"))
        #expect(installed.contains("  - type: command\n    command: '/usr/local/bin/other-hook.sh'"))
        #expect(installed.contains("# 结尾注释"))
        #expect(AgentConfigInstaller.isInstalled(.traeCli, home: home))

        let beforeSecond = try Data(contentsOf: file)
        #expect(AgentConfigInstaller.install(.traeCli, home: home))
        let afterSecond = try Data(contentsOf: file)
        #expect(afterSecond == beforeSecond)

        AgentConfigInstaller.uninstall(.traeCli, home: home)
        let restored = try text(file)
        #expect(restored == original)
        #expect(!AgentConfigInstaller.isInstalled(.traeCli, home: home))
    }

    @Test("traecli：配置不存在时创建 hooks 块；托管项是单一命令，不带 --event")
    func traecliCreatesHooksBlock() throws {
        let home = try makeHome()
        // 闸门：工具目录 ~/.trae 必须已存在（用户装了 traecli 才会有）
        try makeDirectory(home.appendingPathComponent(".trae"))

        #expect(AgentConfigInstaller.install(.traeCli, home: home))

        let file = home.appendingPathComponent(".trae/traecli.yaml")
        let created = try text(file)
        #expect(created.hasPrefix("hooks:\n  - type: command\n"))
        // 单一命令 + matchers 列全部事件 → 不能按事件分命令，所以不带 --event
        #expect(!created.contains("--event"))
        #expect(created.contains("      - event: session_start"))
        #expect(created.contains("      - event: post_compact"))
    }

    @Test("traecli：hooks 行内已有非空序列时拒绝写入；空值写法则正常改写成块")
    func traecliRefusesPopulatedInlineHooks() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".trae/traecli.yaml")
        let original = "theme: dark\nhooks: [a, b]\n"
        try write(original, to: file)

        // 行手术保不住行内那一串项：返回 false，一个字节都不写
        #expect(AgentConfigInstaller.install(.traeCli, home: home) == false)
        let untouched = try text(file)
        #expect(untouched == original)
        #expect(!AgentConfigInstaller.isInstalled(.traeCli, home: home))

        // 行内空值（`hooks: []`）与没写等价：可以就地换成裸键 + 托管块
        try write("theme: dark\nhooks: []\n", to: file)
        #expect(AgentConfigInstaller.install(.traeCli, home: home))
        let rewritten = try text(file)
        #expect(rewritten.hasPrefix("theme: dark\nhooks:\n  - type: command\n"))
        #expect(!rewritten.contains("hooks: []"))
        #expect(AgentConfigInstaller.isInstalled(.traeCli, home: home))
    }

    @Test("traecli：hooks 下的列表项写在列 0（最常见写法）时沿用该缩进，混缩进会写出非法 YAML")
    func traecliKeepsColumnZeroIndent() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".trae/traecli.yaml")
        let original = """
        theme: dark
        hooks:
        - type: command
          command: '/usr/local/bin/other.sh'
          timeout: '5s'

        """
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.traeCli, home: home))
        let installed = try text(file)
        // 我们的项必须也落在列 0：同一个序列里混缩进，PyYAML / Psych 都会直接报错
        #expect(installed.contains("hooks:\n- type: command\n  command: '"))
        #expect(installed.contains("\n- type: command\n  command: '/usr/local/bin/other.sh'"))
        #expect(AgentConfigInstaller.isInstalled(.traeCli, home: home))

        let beforeSecond = try Data(contentsOf: file)
        #expect(AgentConfigInstaller.install(.traeCli, home: home))
        let afterSecond = try Data(contentsOf: file)
        #expect(afterSecond == beforeSecond)

        AgentConfigInstaller.uninstall(.traeCli, home: home)
        let restored = try text(file)
        #expect(restored == original)
    }

    @Test("traecli：hooks 下已是映射时拒绝写入（不写出解析不了的 YAML）")
    func traecliRefusesMappingUnderHooks() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent(".trae/traecli.yaml")
        let original = "hooks:\n  enabled: true\n"
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.traeCli, home: home) == false)
        let untouched = try text(file)
        #expect(untouched == original)
        #expect(!AgentConfigInstaller.isInstalled(.traeCli, home: home))
    }

    // MARK: - hermes（YAML 行手术）

    /// Hermes 的配置落点：`$HERMES_HOME/config.yaml`，未设环境变量时是 `~/.hermes/config.yaml`。
    /// 存在性闸门的判据就是这个根目录本身，所以先把它造出来（返回配置文件 URL）。
    private func makeHermesHome(_ home: URL) throws -> URL {
        try makeDirectory(home.appendingPathComponent(".hermes"))
        return home.appendingPathComponent(".hermes/config.yaml")
    }

    /// Hermes 注册的事件名（与 `AgentHooks.swift` 的 `.hermes` 事件表逐字一致）。
    private let hermesEvents = [
        "pre_tool_call", "post_tool_call", "pre_llm_call", "post_llm_call",
        "on_session_start", "on_session_end", "on_session_reset", "subagent_stop",
    ]

    @Test("hermes：空文件装出 `hooks:` 映射（每事件一行内联条目），卸载后只剩孤立的 hooks:")
    func hermesWritesInlineEntriesIntoEmptyFile() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        try write("", to: file)

        #expect(AgentConfigInstaller.install(.hermes, home: home))
        let installed = try text(file)
        #expect(installed.hasPrefix("hooks:\n"))
        // 每事件一行：命令带 --source hermes 与自己的事件名，超时按事件表写（Hermes 的单位是秒）
        for event in hermesEvents {
            #expect(installed.contains("\n  \(event): [{command: '"))
            #expect(installed.contains("--source hermes --event \(event)', timeout: 5}]"))
        }
        // 只写行内序列（块序列在行手术下删不干净），也不注册审批事件
        #expect(!installed.contains("- command: "))
        #expect(!installed.contains("pre_approval_request"))
        #expect(installed.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 9)
        #expect(AgentConfigInstaller.isInstalled(.hermes, home: home))

        // 重复安装字节相同（幂等）
        let beforeSecond = try Data(contentsOf: file)
        #expect(AgentConfigInstaller.install(.hermes, home: home))
        #expect(try Data(contentsOf: file) == beforeSecond)

        AgentConfigInstaller.uninstall(.hermes, home: home)
        // 这个文件原本就存在（是用户的）：只摘我们的条目，孤立的 `hooks:` 留着
        #expect(try text(file) == "hooks:\n")
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
    }

    @Test("hermes：没有配置文件时创建它；卸载后（无备份 = 我们造的）整份删除")
    func hermesCreatesConfigFileAndRemovesItOnUninstall() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        #expect(AgentConfigInstaller.install(.hermes, home: home))
        #expect((try text(file)).hasPrefix("hooks:\n"))
        #expect(AgentConfigInstaller.isInstalled(.hermes, home: home))
        // 我们创建的文件不落备份：「没有备份」正是「这个文件是我们造的」的判据
        #expect(!FileManager.default.fileExists(
            atPath: file.appendingPathExtension("agent-island-backup").path))
        #expect(AgentConfigInstaller.installedFiles(.hermes, home: home)
            .map { $0.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])

        AgentConfigInstaller.uninstall(.hermes, home: home)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
    }

    @Test("hermes：行手术保住用户的注释、别的键与别人在 hooks 下的条目；卸载后逐字节还原")
    func hermesKeepsForeignContentAndRestoresBytes() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        // 用户文件：顶层别的键（含与 `hooks` 同前缀的 `hooks_auto_accept`）、hooks 下自己的键、
        // 注释与尾部空行 —— 安装只该在映射末尾插我们的键
        let original = """
        # Hermes 配置（用户自己写的注释）
        model: claude-sonnet-4
        hooks_auto_accept: false
        hooks:
          # 用户自己的条目：我们要与它共存
          pre_approval_request: [{command: '/usr/local/bin/user-hook.sh', timeout: 30}]

        # 结尾注释

        """
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.hermes, home: home))
        let installed = try text(file)
        #expect(installed.hasPrefix("""
        # Hermes 配置（用户自己写的注释）
        model: claude-sonnet-4
        hooks_auto_accept: false
        hooks:
          # 用户自己的条目：我们要与它共存
          pre_approval_request: [{command: '/usr/local/bin/user-hook.sh', timeout: 30}]
          pre_tool_call: [{command: '
        """))
        #expect(installed.hasSuffix("\n\n# 结尾注释\n"))
        // 我们的键沿用映射已有的缩进（同一个映射里混缩进会让整个文件解析失败）
        #expect(installed.contains("\n  pre_tool_call: [{command: '"))
        #expect(AgentConfigInstaller.isInstalled(.hermes, home: home))

        let beforeSecond = try Data(contentsOf: file)
        #expect(AgentConfigInstaller.install(.hermes, home: home))
        #expect(try Data(contentsOf: file) == beforeSecond)

        AgentConfigInstaller.uninstall(.hermes, home: home)
        #expect(try text(file) == original)
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
    }

    @Test("hermes：事件键已存在但行内为空（`[]` / `null` / `~` / 裸键）时就地换掉那一行")
    func hermesReplacesEmptyEventValues() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        try write(
            "hooks:\n  pre_tool_call: []\n  post_tool_call: null\n  pre_llm_call:\n  post_llm_call: ~\n",
            to: file)

        #expect(AgentConfigInstaller.install(.hermes, home: home))
        let installed = try text(file)
        for event in ["pre_tool_call", "post_tool_call", "pre_llm_call", "post_llm_call"] {
            #expect(installed.contains("\n  \(event): [{command: '"))
        }
        for empty in ["pre_tool_call: []", "post_tool_call: null", "post_llm_call: ~"] {
            #expect(!installed.contains(empty))
        }
        // 其余事件补在映射末尾
        #expect(installed.contains("\n  subagent_stop: [{command: '"))
        #expect(AgentConfigInstaller.isInstalled(.hermes, home: home))

        AgentConfigInstaller.uninstall(.hermes, home: home)
        // 那四个键里原本没有别人的条目：摘完连键一起删（不留 `pre_tool_call:` 这样的空壳）
        #expect(try text(file) == "hooks:\n")
    }

    @Test("hermes：同一个事件键下已有别人的条目时，我们的条目追加在同一行")
    func hermesAppendsIntoExistingInlineList() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        let original =
            "hooks:\n  pre_tool_call: [{command: '/usr/local/bin/user.sh', timeout: 30}]  # 用户自己的\n"
        try write(original, to: file)

        #expect(AgentConfigInstaller.install(.hermes, home: home))
        let installed = try text(file)
        let line = installed.components(separatedBy: "\n").first { $0.contains("pre_tool_call:") }
        #expect(line?.hasPrefix(
            "  pre_tool_call: [{command: '/usr/local/bin/user.sh', timeout: 30}, {command: '") == true)
        #expect(line?.hasSuffix("--event pre_tool_call', timeout: 5}]  # 用户自己的") == true)
        #expect(line?.contains(AgentHookScript.shellPath(home: home)) == true)
        // 只在那一行里追加一条我们的（别的 7 个事件补在映射末尾，没有重复的键）
        #expect(line?.components(separatedBy: "agent-island-state.py").count == 2)
        #expect(installed.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 9)

        AgentConfigInstaller.uninstall(.hermes, home: home)
        // 别人的条目内容与行尾注释（含注释前的两个空格）逐字节还原
        #expect(try text(file) == original)
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
    }

    @Test("hermes：hooks 下是块序列时拒绝写入（返回 false）且文件一个字节都不动")
    func hermesRefusesBlockStructures() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)

        // 事件键下挂着块序列（YAML 往返写入器那类形状）—— 行手术删一条会留下孤立的 `timeout:`
        let nestedBlock = """
        hooks:
          pre_tool_call:
          - command: 'python3 /usr/local/bin/other.py --source hermes'
            timeout: 5

        """
        try write(nestedBlock, to: file)
        #expect(AgentConfigInstaller.install(.hermes, home: home) == false)
        #expect(try Data(contentsOf: file) == Data(nestedBlock.utf8))
        #expect(!FileManager.default.fileExists(
            atPath: file.appendingPathExtension("agent-island-backup").path))
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
        #expect(AgentConfigInstaller.installedFiles(.hermes, home: home).isEmpty)

        // `hooks:` 的值本身就是块序列（无缩进序列写法）同样是拒绝
        let inlineSequence = "hooks:\n- command: 'x'\n"
        try write(inlineSequence, to: file)
        #expect(AgentConfigInstaller.install(.hermes, home: home) == false)
        #expect(try text(file) == inlineSequence)

        // 行内不是列表也不是空值（`hooks: something`）也拒绝
        try write("hooks: something\n", to: file)
        #expect(AgentConfigInstaller.install(.hermes, home: home) == false)
        #expect(try text(file) == "hooks: something\n")
    }

    @Test("hermes：配置根走 $HERMES_HOME；没设时判据是 ~/.hermes（不凭空造目录）")
    func hermesUsesHermesHome() throws {
        let home = try makeHome()
        // `~/.hermes` 不存在 ⇒ 用户没装 Hermes：跳过（返回 true），一个字节都不写
        #expect(AgentConfigInstaller.install(.hermes, home: home))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes").path))
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))

        let envRoot = home.appendingPathComponent("env-hermes")
        try makeDirectory(envRoot)
        withEnvironment("HERMES_HOME", envRoot.path) {
            let file = envRoot.appendingPathComponent("config.yaml")
            #expect(AgentConfigInstaller.install(.hermes, home: home))
            #expect(AgentConfigInstaller.isInstalled(.hermes, home: home))
            #expect((try? text(file))?.hasPrefix("hooks:\n") == true)
            // 默认位置（~/.hermes）一个字节都不写
            #expect(
                !FileManager.default.fileExists(
                    atPath: home.appendingPathComponent(".hermes").path))

            AgentConfigInstaller.uninstall(.hermes, home: home)
            #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        // 环境变量撤掉之后又回到「~/.hermes 不存在 ⇒ 跳过」
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
    }

    @Test("hermes：卸载摘掉块形式里的我们的条目（连同续行），空掉的键也删掉")
    func hermesRemovesBlockFormEntry() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        let script = AgentHookScript.shellPath(home: home)
        let original = """
        # 用户文件
        hooks:
          pre_tool_call:
          - command: 'python3 \(script) --source hermes --event pre_tool_call'
            timeout: 5
          post_tool_call: [{command: '/usr/local/bin/user.sh', timeout: 30}]

        """
        try write(original, to: file)
        #expect(AgentConfigInstaller.isInstalled(.hermes, home: home))

        AgentConfigInstaller.uninstall(.hermes, home: home)
        // 我们的条目（含它的续行 `timeout:`）整项摘掉；摘空的键一起删；别人的键留着
        #expect(try text(file) == """
        # 用户文件
        hooks:
          post_tool_call: [{command: '/usr/local/bin/user.sh', timeout: 30}]

        """)
        #expect(!AgentConfigInstaller.isInstalled(.hermes, home: home))
    }

    @Test("hermes：映射键写了非默认缩进时沿用它的缩进（同一个映射里混缩进会解析失败）")
    func hermesKeepsExistingMappingIndent() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        try write("hooks:\n    pre_tool_call: []\n", to: file)

        #expect(AgentConfigInstaller.install(.hermes, home: home))
        let installed = try text(file)
        #expect(installed.contains("\n    pre_tool_call: [{command: '"))
        #expect(installed.contains("\n    subagent_stop: [{command: '"))
        #expect(!installed.contains("\n  pre_tool_call:"))

        AgentConfigInstaller.uninstall(.hermes, home: home)
        #expect(try text(file) == "hooks:\n")
    }

    @Test("hermes：只按 command 标量认自己的条目（别的键里出现脚本名不算）")
    func hermesOwnershipUsesCommandScalarOnly() throws {
        let home = try makeHome()
        let file = try makeHermesHome(home)
        let script = AgentHookScript.shellPath(home: home)

        // 用户自己条目的**别的键**里恰好写着我们的脚本路径：卸载一个字节都不该动它
        let foreign = """
        hooks:
          pre_tool_call: [{command: '/usr/local/bin/user.sh', name: '\\(script)', timeout: 30}]

        """
        try write(foreign, to: file)
        AgentConfigInstaller.uninstall(.hermes, home: home)
        #expect(try text(file) == foreign)

        // 裸字符串条目（Hermes 不接受的形状）同样不算我们的
        let bareString = "hooks:\n  pre_tool_call: ['python3 \\(script) --source hermes']\n"
        try write(bareString, to: file)
        AgentConfigInstaller.uninstall(.hermes, home: home)
        #expect(try text(file) == bareString)
    }

    // MARK: - cline（每事件可执行文件）

    @Test("cline：每事件一个 0755 可执行文件、内容先回 cancel；卸载只删自己的文件")
    func clineEventScripts() throws {
        let home = try makeHome()
        let hooksDir = home.appendingPathComponent("Documents/Cline/Hooks")
        // 闸门判据是工具自己的目录 ~/Documents/Cline（Hooks 目录本身由我们创建）；
        // 用户自己的同名目录里已有别的 hook：安装与卸载都不能碰它
        try write("#!/bin/bash\necho user\n", to: hooksDir.appendingPathComponent("UserOwnHook"))

        #expect(AgentConfigInstaller.install(.cline, home: home))
        #expect(AgentConfigInstaller.isInstalled(.cline, home: home))

        let script = try text(hooksDir.appendingPathComponent("PreToolUse"))
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("{\"cancel\":false}"))
        #expect(script.contains(AgentHookScript.shellPath(home: home)))
        #expect(script.contains("--source cline"))
        #expect(script.contains("--event PreToolUse"))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: hooksDir.appendingPathComponent("PreToolUse").path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o755)

        // 事件文件不落备份（备份躺在 hooks 目录里会被 Cline 当 hook 扫到）
        let backup = hooksDir.appendingPathComponent("PreToolUse")
            .appendingPathExtension("agent-island-backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        AgentConfigInstaller.uninstall(.cline, home: home)
        #expect(!AgentConfigInstaller.isInstalled(.cline, home: home))
        #expect(!FileManager.default.fileExists(atPath: hooksDir.appendingPathComponent("PreToolUse").path))
        #expect(FileManager.default.fileExists(atPath: hooksDir.appendingPathComponent("UserOwnHook").path))
    }

    @Test("cline：用户自己写的同名事件文件不被顶掉（跳过该事件并返回 false）")
    func clineKeepsUserOwnEventFile() throws {
        let home = try makeHome()
        let hooksDir = home.appendingPathComponent("Documents/Cline/Hooks")
        let userEvent = hooksDir.appendingPathComponent("PreToolUse")
        let userScript = "#!/bin/bash\necho my-own-hook\n"
        try write(userScript, to: userEvent)

        // 被占用的那个事件跳过（整体返回 false），用户文件与它旁边都不留我们的痕迹
        #expect(AgentConfigInstaller.install(.cline, home: home) == false)
        let untouched = try text(userEvent)
        #expect(untouched == userScript)
        #expect(!FileManager.default.fileExists(
            atPath: userEvent.appendingPathExtension("agent-island-backup").path))

        // 卸载只删我们写的那些事件文件，用户的那个原样留着
        AgentConfigInstaller.uninstall(.cline, home: home)
        let afterUninstall = try text(userEvent)
        #expect(afterUninstall == userScript)
    }

    @Test("cline：只有 ~/Documents 而没有 ~/Documents/Cline 时跳过（不凭空造目录）")
    func clineGateSkipsWithoutToolDirectory() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent("Documents"))
        let hooksDir = home.appendingPathComponent("Documents/Cline/Hooks")

        #expect(AgentConfigInstaller.install(.cline, home: home))
        #expect(!FileManager.default.fileExists(atPath: hooksDir.path))
        #expect(!AgentConfigInstaller.isInstalled(.cline, home: home))
        #expect(AgentConfigInstaller.installedFiles(.cline, home: home).isEmpty)

        // 工具目录出现后才创建 Hooks 并写入全部事件
        try makeDirectory(home.appendingPathComponent("Documents/Cline"))
        #expect(AgentConfigInstaller.install(.cline, home: home))
        #expect(AgentConfigInstaller.isInstalled(.cline, home: home))
        #expect(FileManager.default.fileExists(
            atPath: hooksDir.appendingPathComponent("PreToolUse").path))
    }

    // MARK: - installedFiles / 脚本落点

    @Test("installedFiles：该 Agent 自己的配置文件在前、共享脚本在后；未安装时为空")
    func installedFilesReportsWrittenFiles() throws {
        let home = try makeHome()
        let script = AgentHookScript.fileURL(home: home)
        try write("#!/usr/bin/env python3\n", to: script)
        try makeDirectory(home.appendingPathComponent(".qoder"))

        #expect(AgentConfigInstaller.install(.qoder, home: home))
        let files = AgentConfigInstaller.installedFiles(.qoder, home: home)
        #expect(files == [home.appendingPathComponent(".qoder/settings.json"), script])

        AgentConfigInstaller.uninstall(.qoder, home: home)
        // 卸载后没有属于这个 Agent 的文件了（脚本由 installHookScript 统一维护，不列在这里）
        #expect(AgentConfigInstaller.installedFiles(.qoder, home: home).isEmpty)
    }

    @Test("installHookScript：随包脚本落到唯一路径、权限 0755、内容相同则不重写")
    func installHookScriptCopiesBundledScript() throws {
        guard let bundled = Bundle.main.url(forResource: "agent-island-state", withExtension: "py")
        else {
            // 测试宿主没带资源（不是以 app 为 TEST_HOST 运行时）：跳过，别把环境问题当缺陷
            return
        }
        let home = try makeHome()

        #expect(AgentConfigInstaller.installHookScript(home: home))
        let installed = AgentHookScript.fileURL(home: home)
        let installedData = try Data(contentsOf: installed)
        let bundledData = try Data(contentsOf: bundled)
        #expect(installedData == bundledData)

        let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o755)

        // 内容已经是最新：再次安装仍是成功，内容不变（幂等）
        let before = try Data(contentsOf: installed)
        #expect(AgentConfigInstaller.installHookScript(home: home))
        let after = try Data(contentsOf: installed)
        #expect(after == before)
    }

    // MARK: - 卸载对称性（原本不存在的文件，卸完就删）

    @Test("卸载对称性：原本不存在的 copilot 文件（我们种的 version 1）卸载后整份删除")
    func uninstallDeletesCreatedPlainFile() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".copilot"))
        let file = home.appendingPathComponent(".copilot/hooks/agent-island.json")
        let backup = file.appendingPathExtension("agent-island-backup")

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(AgentConfigInstaller.install(.copilot, home: home))
        #expect(FileManager.default.fileExists(atPath: file.path))
        // 我们创建的文件不落备份：「没有备份」正是「这个文件是我们造的」的判据
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try json(file)["version"] as? Int == 1)

        AgentConfigInstaller.uninstall(.copilot, home: home)

        // 摘完只剩 `{"version": 1}` 的空壳：整个删掉，别留在用户机器上
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!AgentConfigInstaller.isInstalled(.copilot, home: home))
        #expect(AgentConfigInstaller.installedFiles(.copilot, home: home).isEmpty)
    }

    @Test("卸载对称性：我们创建的文件被用户加过顶层键后，卸载保留文件、只摘我们的条目")
    func uninstallKeepsCreatedFileOnceUserAddsKeys() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".gemini"))
        let file = home.appendingPathComponent(".gemini/settings.json")

        #expect(AgentConfigInstaller.install(.gemini, home: home))
        // 用户后来自己往这个文件里写了别的东西：它已经归他，卸载不能再整份删
        var root = try json(file)
        root["theme"] = "dark"
        try canonical(root).write(to: file)

        AgentConfigInstaller.uninstall(.gemini, home: home)

        #expect(FileManager.default.fileExists(atPath: file.path))
        let uninstalled = try json(file)
        #expect(uninstalled["theme"] as? String == "dark")
        #expect(uninstalled["hooks"] == nil)
        #expect(!AgentConfigInstaller.isInstalled(.gemini, home: home))
    }

    @Test("卸载对称性：原本不存在的 kimi config.toml 卸载后整份删除")
    func uninstallDeletesCreatedKimiFile() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".kimi"))
        let file = home.appendingPathComponent(".kimi/config.toml")

        #expect(AgentConfigInstaller.install(.kimi, home: home))
        #expect((try text(file)).contains("[[hooks]]"))
        #expect(AgentConfigInstaller.isInstalled(.kimi, home: home))

        AgentConfigInstaller.uninstall(.kimi, home: home)

        // 摘完只剩空白：整个删掉（用户自己写过的文件走另一条路，逐字节还原）
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!AgentConfigInstaller.isInstalled(.kimi, home: home))
    }

    @Test("卸载对称性：原本不存在的 traecli.yaml 卸载后整份删除（空 hooks 键不算内容）")
    func uninstallDeletesCreatedTraecliFile() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".trae"))
        let file = home.appendingPathComponent(".trae/traecli.yaml")

        #expect(AgentConfigInstaller.install(.traeCli, home: home))
        #expect((try text(file)).hasPrefix("hooks:\n  - type: command\n"))
        #expect(AgentConfigInstaller.isInstalled(.traeCli, home: home))

        AgentConfigInstaller.uninstall(.traeCli, home: home)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!AgentConfigInstaller.isInstalled(.traeCli, home: home))
    }

    // MARK: - 用户指定目录（设置面板的目录选择器）

    @Test("指定目录：`.gemini/settings.json` 写到它下面；卸载只摘我们的条目")
    func installUsesRootOverride() throws {
        let home = try makeHome()
        let override = home.appendingPathComponent("custom-gemini")
        let file = override.appendingPathComponent("settings.json")
        let originalText =
            #"{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/usr/local/bin/other.sh","timeout":5}]}]}}"#
        try write(originalText, to: file)

        try withRootOverride(.gemini, override.path) {
            #expect(AgentConfigInstaller.install(.gemini, home: home))
            #expect(AgentConfigInstaller.isInstalled(.gemini, home: home))
            let afterFirstInstall = try Data(contentsOf: file)

            // 用户自己的键与条目都留着，我们的条目追加在其后
            let installed = try json(file)
            #expect(installed["theme"] as? String == "dark")
            let allCommands = eventEntries(installed, "hooks", "SessionStart").flatMap(commands)
            #expect(allCommands.first == "/usr/local/bin/other.sh")
            #expect(allCommands.count == 2)
            #expect(ownCommands(installed, "hooks", "SessionStart").count == 1)
            // 默认根（~/.gemini）一个字节都不该出现
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path))

            AgentConfigInstaller.uninstall(.gemini, home: home)
            #expect(!AgentConfigInstaller.isInstalled(.gemini, home: home))

            // 除排版外，内容与原始一模一样
            let restored = try json(file)
            let original = try #require(
                try JSONSerialization.jsonObject(with: Data(originalText.utf8)) as? [String: Any])
            #expect(try canonical(restored) == canonical(original))
            // 卸载没有多摘也没有少摘：再装一次回到第一次安装后的字节
            #expect(AgentConfigInstaller.install(.gemini, home: home))
            #expect(try Data(contentsOf: file) == afterFirstInstall)
        }
    }

    @Test("指定目录：cline 的 hook 根换成它（`~/Documents/Cline` → 指定目录）")
    func clineInstallUsesRootOverride() throws {
        let home = try makeHome()
        let override = home.appendingPathComponent("custom-cline")
        try makeDirectory(override)

        try withRootOverride(.cline, override.path) {
            #expect(AgentConfigInstaller.install(.cline, home: home))
            #expect(AgentConfigInstaller.isInstalled(.cline, home: home))
            let event = override.appendingPathComponent("Hooks/PreToolUse")
            let contents = try text(event)
            #expect(contents.contains("--source cline"))
            // 默认位置（~/Documents/Cline）一个字节都不写
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents").path))

            AgentConfigInstaller.uninstall(.cline, home: home)
            #expect(!AgentConfigInstaller.isInstalled(.cline, home: home))
            #expect(!FileManager.default.fileExists(atPath: event.path))
            #expect(FileManager.default.fileExists(atPath: override.path))
        }
    }

    @Test("指定目录：kimi 的 config.toml 写在它下面（不再走 ~/.kimi-code 择优）")
    func kimiInstallUsesRootOverride() throws {
        let home = try makeHome()
        try makeDirectory(home.appendingPathComponent(".kimi-code"))
        let override = home.appendingPathComponent("custom-kimi")
        try makeDirectory(override)

        try withRootOverride(.kimi, override.path) {
            #expect(AgentConfigInstaller.install(.kimi, home: home))
            #expect(AgentConfigInstaller.isInstalled(.kimi, home: home))
            let contents = try text(override.appendingPathComponent("config.toml"))
            #expect(contents.contains("[[hooks]]"))
            // 择优出来的现代根不该再被写：写在这、读在那会让装好的集成看不见
            #expect(
                !FileManager.default.fileExists(
                    atPath: home.appendingPathComponent(".kimi-code/config.toml").path))
        }
    }

    @Test("指定目录不存在：安装跳过（返回 true）且一个字节都不写")
    func missingRootOverrideSkipsInstall() throws {
        let home = try makeHome()
        let missing = home.appendingPathComponent("nowhere")

        try withRootOverride(.gemini, missing.path) {
            #expect(AgentConfigInstaller.install(.gemini, home: home))
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            #expect(AgentConfigInstaller.isInstalled(.gemini, home: home) == false)
            #expect(AgentConfigInstaller.installedFiles(.gemini, home: home).isEmpty)
        }
    }

    @Test("指定目录与 $CODEX_HOME 同时给出：环境变量获胜（与读取链路同一优先级）")
    func environmentWinsOverRootOverride() throws {
        let home = try makeHome()
        let envRoot = home.appendingPathComponent("env-codex")
        let overrideRoot = home.appendingPathComponent("custom-codex")
        try makeDirectory(envRoot)
        try makeDirectory(overrideRoot)

        try withRootOverride(.codex, overrideRoot.path) {
            withEnvironment("CODEX_HOME", envRoot.path) {
                #expect(AgentConfigInstaller.install(.codex, home: home))
                #expect(AgentConfigInstaller.isInstalled(.codex, home: home))
                #expect(
                    FileManager.default.fileExists(
                        atPath: envRoot.appendingPathComponent("hooks.json").path))
                #expect(
                    !FileManager.default.fileExists(
                        atPath: overrideRoot.appendingPathComponent("hooks.json").path))
            }
        }
        // 环境变量撤掉之后才轮到用户指定目录
        try withRootOverride(.codex, overrideRoot.path) {
            withEnvironment("CODEX_HOME", nil) {
                #expect(AgentConfigInstaller.install(.codex, home: home))
                #expect(
                    FileManager.default.fileExists(
                        atPath: overrideRoot.appendingPathComponent("hooks.json").path))
            }
        }
    }
}
