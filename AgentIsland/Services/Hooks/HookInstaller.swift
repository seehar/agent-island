//
//  HookInstaller.swift
//  AgentIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

nonisolated struct HookInstaller {

    /// hook 脚本文件名（各 Agent 的安装逻辑共用这个名字）。
    static let hookScriptName = "agent-island-state.py"

    /// 改名前的脚本名。老用户机器上 ~/.claude/settings.json 与 hooks 目录里仍有它，
    /// 安装与卸载都要一并清理，否则旧脚本会继续往已废弃的 socket 发状态。
    static let legacyHookScriptNames = ["claude-island-state.py"]

    /// 本应用的 hook 命令判定：新旧脚本名都算自己的。
    nonisolated static func isOwnHookCommand(_ command: String) -> Bool {
        ([hookScriptName] + legacyHookScriptNames).contains { command.contains($0) }
    }

    /// 启动时安装 hook 脚本并更新 settings.json
    static func installIfNeeded() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent(Self.hookScriptName)

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        for legacy in Self.legacyHookScriptNames {
            try? FileManager.default.removeItem(at: hooksDir.appendingPathComponent(legacy))
        }

        if let bundled = Bundle.main.url(forResource: "agent-island-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        updateSettings(at: ClaudePaths.settingsFile)
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) \(ClaudePaths.hookScriptShellPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Strip any existing AgentIsland hooks from ALL event types first — even
        // events we no longer register. Fixes users who installed v1.3 on an older
        // Claude Code and now have invalid keys like PermissionDenied sitting in
        // their settings.json (issue #85).
        var cleanedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let cleaned = entries.compactMap { removingAgentIslandHooks(from: $0) }
                if !cleaned.isEmpty {
                    cleanedHooks[event] = cleaned
                }
            } else {
                cleanedHooks[event] = value
            }
        }
        hooks = cleanedHooks

        // Register only hooks the installed Claude Code version supports.
        // When detection fails, fall back to the baseline set that every
        // Claude Code version has supported (no new v1.3+ hooks).
        let installedVersion = detectClaudeCodeVersion()
        let hookEvents = supportedHookEvents(
            for: installedVersion,
            withMatcher: withMatcher,
            withMatcherAndTimeout: withMatcherAndTimeout,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        )

        for (event, config) in hookEvents {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
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

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent(Self.hookScriptName)
        for legacy in Self.legacyHookScriptNames {
            try? FileManager.default.removeItem(at: hooksDir.appendingPathComponent(legacy))
        }
        let settings = ClaudePaths.settingsFile

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries = entries.compactMap { removingAgentIslandHooks(from: $0) }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }
    }

    private static func detectPython() -> String {
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
