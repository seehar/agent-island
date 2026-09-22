//
//  CursorAgentProvider.swift
//  AgentIsland
//
//  Cursor 的布局：`~/.cursor/projects/<项目目录>/agent-transcripts/<父会话 id>/<父会话 id>.jsonl`，
//  子会话（IDE 的 Task）挂在 `<父会话 id>/subagents/<子会话 id>.jsonl`；hook 写在
//  `~/.cursor/hooks.json`。项目目录名用 CodeIsland 的 `appProjectDirEncoded`
//  （Claude 的编码去掉前导短横线）。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:5561`（findActiveCursorSessions，
//  记录根与项目编码）、`:5599`（findMostRecentCursorTranscript：项目目录下
//  `agent-transcripts/<会话目录>/<文件>.jsonl`）、`Sources/CodeIslandCore/CursorSessionFolding.swift:26`
//  （两种布局：`<父会话 id>/<父会话 id>.jsonl` 与 `<父会话 id>/subagents/<子会话 id>.jsonl`）。
//  本机未安装 Cursor（`~/.cursor/projects/` 不存在），布局未能在本机复核。
//

import Foundation

nonisolated struct CursorAgentProvider: AgentProvider {
    let kind: AgentKind = .cursor

    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    private let agentTranscriptsDirName = "agent-transcripts"
    private let subagentsDirName = "subagents"

    // MARK: - 布局

    var configRoot: URL {
        home.appendingPathComponent(".cursor")
    }

    var recordsRoot: URL {
        configRoot.appendingPathComponent("projects")
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
        let transcripts = transcriptsDirectory(for: cwd)
        let direct =
            transcripts
            .appendingPathComponent(sessionId)
            .appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // 子会话的记录挂在父会话目录下，无法由 id 直接推出父目录，只能扫一层。
        // 两处都没有时返回约定路径（与 claude / pi 一致，调用方按存在性判断）。
        return subagentFile(sessionId: sessionId, in: transcripts) ?? direct
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(recordsRoot.path + "/") else {
            return false
        }
        return path.contains("/\(agentTranscriptsDirName)/")
    }

    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        return id.isEmpty ? nil : id
    }

    /// 记录里没有工作目录字段（Cursor 只写 `role` / `message`），因此由项目目录名反推。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard isTranscriptFile(path) else { return nil }
        guard let encoded = projectDirectory(of: path) else { return nil }
        return decodeProjectDirectory(encoded)
    }

    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] {
        let directory =
            transcriptsDirectory(for: cwd)
            .appendingPathComponent(sessionId)
            .appendingPathComponent(subagentsDirName)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.filter { $0.pathExtension == "jsonl" }
    }

    // MARK: - 目录解析

    private func transcriptsDirectory(for cwd: String) -> URL {
        recordsRoot
            .appendingPathComponent(CursorAgentProvider.projectDirectoryName(for: cwd))
            .appendingPathComponent(agentTranscriptsDirName)
    }

    private func subagentFile(sessionId: String, in transcripts: URL) -> URL? {
        let fm = FileManager.default
        guard
            let parents = try? fm.contentsOfDirectory(
                at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for parent in parents {
            let candidate =
                parent
                .appendingPathComponent(subagentsDirName)
                .appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func projectDirectory(of path: String) -> String? {
        guard path.hasPrefix(recordsRoot.path + "/") else { return nil }
        let parts = path.dropFirst(recordsRoot.path.count + 1).split(separator: "/")
        guard parts.count >= 3, parts[1] == agentTranscriptsDirName else { return nil }
        return String(parts[0])
    }

    /// 项目目录名：Claude 编码（`/` 与 `.` → `-`）去掉前导短横线。
    nonisolated static func projectDirectoryName(for cwd: String) -> String {
        let encoded = ClaudeAgentProvider.encodeProjectDirectory(cwd)
        return encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
    }

    /// 把编码后的项目目录名还原成 cwd。
    ///
    /// 编码把路径分隔符与名字里的短横线混在一起（`Users-me-my-app`），字符串层面
    /// 无法区分，因此按「磁盘上真实存在的目录」逐段贪心还原：每步优先取能拼出真实
    /// 目录的最长片段，都拼不出时退回单段。项目目录已被删除时结果可能不精确，但它
    /// **编码回原样**（`编码(还原(x)) == x`），记录定位与用量归集不受影响。
    private func decodeProjectDirectory(_ encoded: String) -> String {
        let parts = encoded.split(separator: "-").map(String.init)
        let fm = FileManager.default
        var resolved = "/"
        var index = 0
        while index < parts.count {
            var end = parts.count
            var matched: String?
            while end > index {
                let candidate = (resolved as NSString).appendingPathComponent(
                    parts[index..<end].joined(separator: "-"))
                if fm.fileExists(atPath: candidate) {
                    matched = candidate
                    break
                }
                end -= 1
            }
            if let matched {
                resolved = matched
                index = end
            } else {
                resolved = (resolved as NSString).appendingPathComponent(parts[index])
                index += 1
            }
        }
        return resolved
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
