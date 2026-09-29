//
//  HookInstaller.swift
//  AgentIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

nonisolated struct HookInstaller {
    /// 失败原因走日志而不是界面：界面上「是否已装」由集成状态表达，日志里才写得下原因。
    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Integration")

    /// hook 脚本文件名。**只有一处事实源**（`AgentHookScript.fileName`）：脚本落点、
    /// 各工具配置里引用的路径、以及卸载时的判据都从那里取，避免两处常量各自漂移。
    static var hookScriptName: String { AgentHookScript.fileName }

    /// 改名前的脚本名。老用户机器上 ~/.claude/settings.json 与 hooks 目录里仍有它，
    /// 安装与卸载都要一并清理，否则旧脚本会继续往已废弃的 socket 发状态。
    static let legacyHookScriptNames = ["claude-island-state.py"]

    /// 本应用的 hook 命令判定：新旧脚本名都算自己的。
    nonisolated static func isOwnHookCommand(_ command: String) -> Bool {
        ([hookScriptName] + legacyHookScriptNames).contains { command.contains($0) }
    }

    /// 启动时安装 hook 脚本并更新 settings.json。
    ///
    /// 顺序是有讲究的：脚本先落地，再改 settings.json。以前两者都用 `try?` 且不看结果，
    /// 脚本拷贝失败时配置里仍然写进一条指向不存在脚本的命令 —— Claude Code 会在每个事件
    /// 上跑一次注定失败的命令。现在脚本没落地就直接返回，配置保持原样。
    static func installIfNeeded() {
        // 脚本的唯一落点是 `~/.agent-island/hooks/`（见 `AgentHookScript`）：Codex、
        // Gemini、Cursor 等工具的 hook 也引用同一份文件，一份实现一处升级。
        let hooksDir = AgentHookScript.directory()
        let pythonScript = AgentHookScript.fileURL()

        do {
            try FileManager.default.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("创建 hooks 目录失败，跳过 Claude 集成安装：\(error.localizedDescription, privacy: .public)")
            return
        }

        // 清理两个位置上的遗留：改名前的旧名字，以及**旧落点上的同名脚本**
        // （本批把落点从 `<claudeDir>/hooks/` 换成 `~/.agent-island/hooks/`）。
        // 旧副本会继续上报到废弃的 socket，或与新脚本并存造成两份实现。
        //
        // 注意：共享落点（`hooksDir`）那一次**不能**带上当前文件名，否则会把正在用的
        // 脚本删掉。
        removeLegacyHookScripts(in: hooksDir)
        removeLegacyHookScripts(in: ClaudePaths.hooksDir, includingCurrentName: true)

        guard let bundled = Bundle.main.url(forResource: "agent-island-state", withExtension: "py")
        else {
            logger.error("缺少内置的 hook 脚本资源，跳过 Claude 集成安装")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: pythonScript.path) {
                try FileManager.default.removeItem(at: pythonScript)
            }
            try FileManager.default.copyItem(at: bundled, to: pythonScript)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        } catch {
            logger.error("写入 hook 脚本失败，本次不改 settings.json：\(error.localizedDescription, privacy: .public)")
            return
        }

        updateSettings(at: ClaudePaths.settingsFile)
    }

    /// 清理改名前的 hook 脚本：旧脚本会继续往已废弃的 socket 发状态。
    ///
    /// - Parameter includingCurrentName: 迁移期用：旧落点上还留着**当前文件名**的副本。
    ///   只允许对 Claude 自己的 hooks 目录传 true——共享落点上那份是正在用的脚本。
    private static func removeLegacyHookScripts(in hooksDir: URL, includingCurrentName: Bool = false) {
        var names = Self.legacyHookScriptNames
        if includingCurrentName { names.append(Self.hookScriptName) }
        for legacy in names {
            let file = hooksDir.appendingPathComponent(legacy)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                logger.notice("已清理改名遗留的 hook 脚本：\(legacy, privacy: .public)")
            } catch {
                logger.debug("遗留 hook 脚本未能删除：\(legacy, privacy: .public)")
            }
        }
    }

    /// 把 hook 条目合并写回 settings.json。
    ///
    /// 四条安全约束：
    /// 1. 这台机器上没有 `python3` 时**放弃写入**：hook 命令必须由一个真实存在的解释器
    ///    解释，写进去只会在每个事件上跑一次注定失败的命令（见 `detectPython`）。
    /// 2. 读不到或读不懂原文件时**放弃写入**（见 `HookSettingsLoad.refusalReason`）：
    ///    宁可这次装不上 hook，也不能把用户整份 Claude Code 配置清空。
    /// 3. 内容没有变化就一个字节都不写，避免每次启动都刷新文件时间戳。
    /// 4. 覆盖前把上一版留成 `settings.json.agent-island-backup`（**只写一次**，
    ///    见 `AgentConfigBackup`），写入用原子替换。
    /// 内部可见而不是 private：单测要拿**临时目录**里的 settings.json 走一遍真实的
    /// 读-改-写（含备份与原子替换），真实路径永远由 `installIfNeeded` 传进来。
    /// - Parameter interpreter: hook 命令要用的解释器；nil 表示探测不到 `python3`，
    ///   此时一个字节都不写。默认值为现场探测结果；单测直接传 nil 走「拒绝安装」分支。
    static func updateSettings(
        at settingsURL: URL,
        interpreter: String? = HookInstaller.detectPython()
    ) {
        guard let python = interpreter else {
            logger.error("未找到 python3，本次不改 settings.json：hook 命令需要它，写进去只会在每个事件上失败")
            return
        }

        let fileExists = FileManager.default.fileExists(atPath: settingsURL.path)
        let loaded = HookSettingsMerger.load(
            data: fileExists ? try? Data(contentsOf: settingsURL) : nil,
            fileExists: fileExists
        )
        if let refusal = loaded.refusalReason {
            logger.error("settings.json 不可安全写入（\(refusal, privacy: .public)），本次跳过 hook 安装：\(settingsURL.path, privacy: .public)")
            return
        }

        let stripped = HookSettingsMerger.strippingOwnHooks(
            from: loaded.settings,
            isOwnCommand: isOwnHookCommand
        )
        let merged = HookSettingsMerger.appending(hookEvents: hookEvents(python: python), to: stripped)

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            logger.error("hook 配置序列化失败，跳过写入")
            return
        }

        let original = try? Data(contentsOf: settingsURL)
        guard original != data else { return }  // 已经是目标状态

        if let original, fileExists {
            // 备份是**不可重写**的原始快照：已经存在就不覆盖，用户按 README 恢复时拿到的
            // 才是他最初的那一份（见 `AgentConfigBackup`）。
            AgentConfigBackup.writeOnce(original, for: settingsURL)
        }

        do {
            try data.write(to: settingsURL, options: [.atomic])
            // notice 级：首次启动会往每个检测到的工具的配置里写条目，用户与我们都得能
            // 从日志里看出「改了哪个文件、备份在哪」（debug 不会被持久化）。
            logger.notice("已写入 Claude hook 配置：\(settingsURL.path, privacy: .public)")
        } catch {
            logger.error("写入 settings.json 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 本次要注册的 hook 事件：基础集 + 按已装 Claude Code 版本追加的事件。
    ///
    /// - Parameter python: 解释器（调用方已确认这台机器上真的有它）。
    private static func hookEvents(python: String) -> [(event: String, entries: [[String: Any]])] {
        let command = "\(python) \(ClaudePaths.hookScriptShellPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [
            ["type": "command", "command": command, "timeout": 86400]
        ]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [
            ["matcher": "*", "hooks": hookEntryWithTimeout]
        ]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        return supportedHookEvents(
            for: detectClaudeCodeVersion(),
            withMatcher: withMatcher,
            withMatcherAndTimeout: withMatcherAndTimeout,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        ).map { (event: $0.0, entries: $0.1) }
    }

    // MARK: - Claude Code Version Detection

    /// Simple semantic version used to gate which hook events we register.
    /// Claude Code rejects unknown hook keys, so we must only register
    /// events the installed version knows about.
    struct ClaudeCodeVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Runs `claude --version` and parses the result. Returns nil on any
    /// failure (binary not found, non-zero exit, unparseable output).
    static func detectClaudeCodeVersion() -> ClaudeCodeVersion? {
        // Claude Code can land in a few typical spots; try each until we find one
        let fm = FileManager.default
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parseClaudeCodeVersion(from: output)
        } catch {
            return nil
        }
    }

    /// Extracts the first `X.Y.Z` token from arbitrary version output.
    /// Accepts any prefix/suffix — works for "2.1.88", "v2.1.88", "claude 2.1.88 (...)" etc.
    static func parseClaudeCodeVersion(from text: String) -> ClaudeCodeVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange])
        else { return nil }
        return ClaudeCodeVersion(major: major, minor: minor, patch: patch)
    }

    /// Returns the ordered list of (event, config) pairs to register, filtered
    /// to only events the installed Claude Code version knows about.
    private static func supportedHookEvents(
        for version: ClaudeCodeVersion?,
        withMatcher: [[String: Any]],
        withMatcherAndTimeout: [[String: Any]],
        withoutMatcher: [[String: Any]],
        preCompactConfig: [[String: Any]]
    ) -> [(String, [[String: Any]])] {
        // Baseline — present in every Claude Code version that supports hooks
        var events: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        // Without a detected version, stick to the baseline — better to miss
        // features than to break settings.json on older Claude Code (#85).
        guard let version else { return events }

        // v2.0.x — PostToolUseFailure shipped alongside the PostToolUse redesign
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 0) {
            events.append(("PostToolUseFailure", withMatcher))
        }
        // v2.0.43 — SubagentStart, pairs with SubagentStop
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 43) {
            events.append(("SubagentStart", withoutMatcher))
        }
        // v2.1.76 — PostCompact, pairs with PreCompact
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 76) {
            events.append(("PostCompact", preCompactConfig))
        }
        // v2.1.78 — StopFailure on API errors (rate limit, auth, billing)
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 78) {
            events.append(("StopFailure", withoutMatcher))
        }
        // v2.1.88 — PermissionDenied for auto-mode classifier denials
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 88) {
            events.append(("PermissionDenied", withMatcher))
        }

        return events
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let settings = ClaudePaths.settingsFile

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               Self.isOwnHookCommand(cmd) {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// 卸载：删脚本 + 从 settings.json 摘掉本应用的 hook 条目。
    ///
    /// 与安装同一套安全约束：读不到／读不懂配置文件时什么都不改（只删脚本），
    /// 也不会在文件本来不存在时凭空造一个空的 settings.json。
    static func uninstall() {
        let settings = ClaudePaths.settingsFile

        // 旧落点（`~/.claude/hooks/`）里的副本只属于 Claude，删干净；
        // 共享落点 `~/.agent-island/hooks/` 的脚本不删——Codex / Gemini / Cursor 等
        // 工具的 hook 同样引用它，按单个 Agent 卸载就删会让它们静默失效。
        removeLegacyHookScripts(in: ClaudePaths.hooksDir, includingCurrentName: true)
        removeLegacyHookScripts(in: AgentHookScript.directory())

        let fileExists = FileManager.default.fileExists(atPath: settings.path)
        guard fileExists else { return }

        let loaded = HookSettingsMerger.load(
            data: try? Data(contentsOf: settings),
            fileExists: fileExists
        )
        if let refusal = loaded.refusalReason {
            logger.error("卸载时 settings.json 不可安全改写（\(refusal, privacy: .public)），跳过清理")
            return
        }

        let stripped = HookSettingsMerger.strippingOwnHooks(
            from: loaded.settings,
            isOwnCommand: isOwnHookCommand
        )
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: stripped,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            logger.error("卸载时序列化 settings.json 失败，跳过写入")
            return
        }
        guard (try? Data(contentsOf: settings)) != data else { return }

        do {
            try data.write(to: settings, options: [.atomic])
            logger.notice("已从 settings.json 摘除 Claude hook 配置")
        } catch {
            logger.error("卸载时写入 settings.json 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// python 解释器探测：所有 Agent 的配置安装器共用这一份。
    ///
    /// **只认 `python3`**：探测不到时返回 nil，而不是退回 `python` —— macOS 上 `python`
    /// 要么不存在、要么是 Xcode 的占位壳（运行只会弹安装提示），写进配置就是一条
    /// **每个事件都失败**的命令，而用户完全看不出为什么。
    ///
    /// 调用方拿到 nil 必须**放弃安装**（一个字节都不写），把原因写进日志，并让集成状态
    /// 停在「未安装」（见 `AgentConfigInstaller.install`、`updateSettings(at:interpreter:)`）。
    nonisolated static func detectPython() -> String? {
        if probePython3() { return "python3" }
        // PATH 里没有时再试常见绝对路径：Finder 启动的应用拿的是系统默认 PATH
        // （`launchctl getenv PATH` 为空 → `/usr/bin:/bin:/usr/sbin:/sbin`），Homebrew
        // （`/opt/homebrew/bin`）与 python.org（`/usr/local/bin`）装法都不在其中，
        // 那台机器上 `which python3` 找不到，但我们明明能用一个绝对路径跑通。
        // 只检查「可执行」而不试跑：`/usr/bin/python3` 在没装命令行工具的机器上是会弹
        // 安装对话框的桩，绝不能去执行它。`detectClaudeCodeVersion` 面对同类问题也是列候选路径。
        for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// 这台机器上有没有可用的 `python3`。
    ///
    /// 供设置行使用：hook 命令的解释器是它，探测不到时状态必须是「未安装 + 原因」，
    /// 而设置页每画一行都会问一次——每次起一个 `which` 进程太贵，因此这里缓存探测结果
    /// （同一个进程里解释器的存在不会变）。
    nonisolated static var pythonIsAvailable: Bool { cachedPython3Availability }

    /// `which python3` 的结果，进程内只探一次（只问「PATH 里有没有」，与
    /// `detectPython()` 的候选路径无关：设置行显示「缺 python3」只在真的一个都用不了时才该出现，
    /// 因此这里也把候选路径算进来）。
    nonisolated private static let cachedPython3Availability: Bool = detectPython() != nil

    /// 真起一个 `which python3` 进程探测。
    nonisolated private static func probePython3() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func removingAgentIslandHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isAgentIslandHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func isAgentIslandHook(_ hook: [String: Any]) -> Bool {
        let cmd = hook["command"] as? String ?? ""
        return isOwnHookCommand(cmd)
    }
}

// MARK: - 备份

/// 安装器改写用户文件前的备份规则：`<文件名>.agent-island-backup` 是**不可重写**的
/// 原始快照，`HookInstaller` 与 `AgentConfigInstaller` 共用这一处。
///
/// 为什么只写一次：第二次安装（升级新增事件、重装）若用「当前内容」覆盖备份，用户按
/// README 恢复时拿到的就不再是他自己的原始文件，而是我们写过一版的内容 —— 备份从此
/// 回答不了「装之前是什么样」，恢复也就失去了意义。
///
/// 备份的**存在**同时是本仓的一处判据：「没有备份」等价于「这个文件原本不存在、是我们
/// 创建的」（见 `AgentConfigInstaller.wasCreatedByUs`），所以常规写入只给「原文件真的
/// 存在」的落备份。唯一的例外是 Codex 的 `config.toml`：`enableCodexHooks` 明知文件不存在
/// 也要落一份内容为空的记录 —— 「我们种下的那份 config.toml」与「用户自己写的、内容恰好
/// 相同的那份」在文件上无法区分，卸载时只能靠这份记录（见 `disableCodexHooks`）。
nonisolated enum AgentConfigBackup {
    /// 备份后缀（`<原文件名>.agent-island-backup`）。
    static let fileExtension = "agent-island-backup"

    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Integration")

    /// 该文件的备份落点。
    static func url(for file: URL) -> URL {
        file.appendingPathExtension(fileExtension)
    }

    /// 落一份备份；**已经存在就不覆盖**（那才是更接近原始的那一版）。
    ///
    /// 备份失败不阻断安装（配置本身还能写），但要在日志里留痕。
    static func writeOnce(_ original: Data, for file: URL) {
        let backup = url(for: file)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        do {
            try original.write(to: backup, options: .atomic)
        } catch {
            logger.error("备份失败（继续写入）：\(backup.path, privacy: .public)")
        }
    }
}
