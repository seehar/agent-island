//
//  ClaudeAgentProvider.swift
//  ClaudeIsland
//
//  Claude Code 布局：`<配置目录>/projects/<编码后的 cwd>/<session>.jsonl`，
//  hook 注册在 `<配置目录>/settings.json`。路径解析全部委托给既有的
//  `ClaudePaths`，保持单一事实来源。
//

import Foundation

nonisolated struct ClaudeAgentProvider: AgentProvider {
    let kind: AgentKind = .claudeCode

    /// Claude Code 自身的环境变量覆盖项，用于子 Agent 布局判断。
    private static let configEnvVar = "CLAUDE_CONFIG_DIR"

    func paths() -> AgentPaths? {
        AgentPaths(
            configDir: ClaudePaths.claudeDir,
            sessionsDir: ClaudePaths.projectsDir,
            pluginsDir: nil,
            dataDir: nil
        )
    }

    // MARK: - 会话记录

    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        let projectDir = Self.encodeProjectDirectory(cwd)
        return ClaudePaths.projectsDir
            .appendingPathComponent(projectDir)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        guard path.contains("/projects/") else { return false }
        return !((path as NSString).lastPathComponent.hasPrefix("agent-"))
    }

    func sessionId(fromTranscriptFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl"), !name.hasPrefix("agent-") else { return nil }
        return String(name.dropLast(".jsonl".count))
    }

    func cwd(fromTranscriptFile path: String) throws -> String? {
        try TranscriptFileReader.firstRecordField(
            in: path,
            predicate: {
                $0["type"] as? String == "user" || $0["type"] as? String == "assistant"
                    || $0["sessionId"] != nil
            },
            value: { $0["cwd"] as? String }
        )
    }

    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] {
        let projectDir = ClaudePaths.projectsDir.appendingPathComponent(
            Self.encodeProjectDirectory(cwd))
        let nested = projectDir.appendingPathComponent(sessionId).appendingPathComponent(
            "subagents")
        let flat = projectDir

        var files: [URL] = []
        let fm = FileManager.default
        if let nestedContents = try? fm.contentsOfDirectory(
            at: nested, includingPropertiesForKeys: nil)
        {
            files += nestedContents.filter {
                $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl"
            }
        }
        if let flatContents = try? fm.contentsOfDirectory(at: flat, includingPropertiesForKeys: nil)
        {
            files += flatContents.filter {
                $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl"
            }
        }
        return files
    }

    /// Claude Code 把工作目录中的 `/` 与 `.` 都替换成 `-`。
    nonisolated static func encodeProjectDirectory(_ cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        let script = ClaudePaths.hooksDir.appendingPathComponent(HookInstaller.hookScriptName)
        let installed =
            FileManager.default.fileExists(atPath: script.path) && HookInstaller.isInstalled()
        return AgentIntegrationStatus(
            health: installed ? .installed : .missing,
            installedFiles: [script, ClaudePaths.settingsFile]
        )
    }
}
