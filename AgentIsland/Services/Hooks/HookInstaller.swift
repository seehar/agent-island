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

    /// hook 脚本文件名（各 Agent 的安装逻辑共用这个名字）。
    static let hookScriptName = "agent-island-state.py"

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
    /// 三条安全约束：
    /// 1. 读不到或读不懂原文件时**放弃写入**（见 `HookSettingsLoad.refusalReason`）：
    ///    宁可这次装不上 hook，也不能把用户整份 Claude Code 配置清空。
    /// 2. 内容没有变化就一个字节都不写，避免每次启动都刷新文件时间戳。
    /// 3. 覆盖前把上一版留成 `settings.json.agent-island-backup`，写入用原子替换。
    /// 内部可见而不是 private：单测要拿**临时目录**里的 settings.json 走一遍真实的
    /// 读-改-写（含备份与原子替换），真实路径永远由 `installIfNeeded` 传进来。
    static func updateSettings(at settingsURL: URL) {
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
        let merged = HookSettingsMerger.appending(hookEvents: hookEvents(), to: stripped)

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
            let backup = settingsURL.appendingPathExtension("agent-island-backup")
            try? original.write(to: backup, options: [.atomic])
        }

        do {
            try data.write(to: settingsURL, options: [.atomic])
            logger.debug("已写入 Claude hook 配置：\(settingsURL.path, privacy: .public)")
        } catch {
            logger.error("写入 settings.json 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 本次要注册的 hook 事件：基础集 + 按已装 Claude Code 版本追加的事件。
    private static func hookEvents() -> [(event: String, entries: [[String: Any]])] {
        let python = detectPython()
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

    /// python 解释器探测：所有 Agent 的配置安装器共用这一份
    /// （找不到 `python3` 就退回 `python`）。
    nonisolated static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
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
