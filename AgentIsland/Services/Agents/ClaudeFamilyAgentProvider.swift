//
//  ClaudeFamilyAgentProvider.swift
//  AgentIsland
//
//  Claude Code fork（Qoder / Factory / CodeBuddy）共用的 Provider：记录格式与
//  事件契约都沿用 Claude Code，差别只在配置根、记录根与项目目录编码。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift` 的 `findFlatStoreSessions`
//  调用点 —— qoder → `~/.qoder/projects`（`claudeProjectDirEncoded`）、
//  droid → `~/.factory/sessions`（`claudeProjectDirEncoded`）、
//  codebuddy → `~/.codebuddy/projects`（`appProjectDirEncoded`，同文件尾部的
//  `String` 扩展）。本机实测：`~/.qoder/projects/-Users-…-note/` 有前导短横线，
//  `~/.codebuddy/projects/Users-…-hwyc-server-ai/` 没有。
//

import Foundation

nonisolated struct ClaudeFamilyAgentProvider: AgentProvider {
    let kind: AgentKind

    /// 用于推导全部路径的用户主目录（用例可注入临时目录）。
    private let home: URL

    init(kind: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.kind = kind
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    // MARK: - 布局

    /// 该 fork 的配置根（hook 写在 `<配置根>/settings.json`）。
    private var configRoot: URL {
        home.appendingPathComponent(configRootName)
    }

    /// 记录根：Qoder / CodeBuddy 用 `projects/`，Factory 用 `sessions/`。
    private var recordsRoot: URL {
        configRoot.appendingPathComponent(recordsDirName)
    }

    private var configRootName: String {
        switch kind {
        case .qoder: return ".qoder"
        case .factory: return ".factory"
        // 其余只可能是 CodeBuddy：本 Provider 只服务 Claude fork。
        default: return ".codebuddy"
        }
    }

    private var recordsDirName: String {
        kind == .factory ? "sessions" : "projects"
    }

    func paths() -> AgentPaths? {
        guard FileManager.default.fileExists(atPath: configRoot.path) else { return nil }
        return AgentPaths(
            configDir: configRoot,
            sessionsDir: recordsRoot,
            pluginsDir: nil,
            dataDir: nil
        )
    }

    // MARK: - 会话记录

    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        recordsRoot
            .appendingPathComponent(projectDirectoryName(for: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(recordsRoot.path + "/") else {
            return false
        }
        // Claude 系把子 Agent 的记录写成 `agent-<id>.jsonl`，它不是会话记录。
        return !(path as NSString).lastPathComponent.hasPrefix("agent-")
    }

    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl"), !name.hasPrefix("agent-") else { return nil }
        return String(name.dropLast(".jsonl".count))
    }

    /// 记录里的工作目录。Claude fork 沿用 Claude 的逐行格式（`sessionId` / `cwd`
    /// 出现在每条消息上），因此走与 `ClaudeAgentProvider` 相同的字段选择。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard isTranscriptFile(path) else { return nil }
        return try TranscriptFileReader.firstRecordField(
            in: path,
            predicate: {
                $0["type"] as? String == "user" || $0["type"] as? String == "assistant"
                    || $0["sessionId"] != nil
            },
            value: { $0["cwd"] as? String }
        )
    }

    /// 子 Agent 记录：这些 fork 是否有 Claude 的 `subagents/` 子目录没有证据，
    /// 因此不认（宁可不认，也不要误认别的文件）。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 项目目录编码

    /// 项目目录名。Claude 把 `/` 与 `.` 都换成 `-`；CodeBuddy 的编码再少一个前导
    /// 短横线（CodeIsland 的 `appProjectDirEncoded`，本机 `~/.codebuddy/projects`
    /// 实测无前导 `-`）。
    private func projectDirectoryName(for cwd: String) -> String {
        let encoded = ClaudeAgentProvider.encodeProjectDirectory(cwd)
        guard kind == .codeBuddy else { return encoded }
        return encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
