//
//  GeminiAgentProvider.swift
//  AgentIsland
//
//  Google Gemini CLI 的布局：`~/.gemini/tmp/<项目目录>/chats/session-<时间戳>-<截断 id>.jsonl`，
//  项目目录名由 `~/.gemini/projects.json` 的 `{"projects": {cwd: 目录名}}` 映射，
//  兜底是 `<项目目录>/.project_root`（内容即 cwd）。hook 写在 `~/.gemini/settings.json`。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:5399`（findActiveGeminiSessions）、
//  `:5452`（readGeminiProjectsMap）、`:5460`（findGeminiProjectDirectory：先查映射再比对
//  `.project_root`）、`:5477`（findMostRecentGeminiSession 的 `session-*` 命名）。
//  与本机实测的差异：真实记录是 **JSONL**（首行 `{"sessionId":…,"projectHash":…}`），
//  文件名里的 id 被截断到 8 字符（`session-2026-06-03T07-46-a2a-serv.jsonl` 对应
//  `"sessionId":"a2a-server"`），因此会话 id 以首行为准、文件名只作兜底。
//  **只认 `.jsonl`**：旧版 Gemini 的整文档 `session-*.json` 格式不同（没有现成的读取
//  实现），认了它却读不出内容，会把「未实现的格式」表现成「会话在、历史空」——
//  宁可整个忽略，也不假装读过。
//

import Foundation

nonisolated struct GeminiAgentProvider: AgentProvider {
    let kind: AgentKind = .gemini

    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    // MARK: - 布局

    /// Gemini 的配置根（`settings.json`、`projects.json` 都在这里）。
    var configRoot: URL {
        home.appendingPathComponent(".gemini")
    }

    /// 记录根：每个项目一个哈希目录，会话在其 `chats/` 下。
    var recordsRoot: URL {
        configRoot.appendingPathComponent("tmp")
    }

    private var projectsMapFile: URL {
        configRoot.appendingPathComponent("projects.json")
    }

    private let chatsDirName = "chats"
    private let sessionFilePrefix = "session-"

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
        // 顺序很关键：本方法挂在 SessionStore 的增量读取路径上（每个活跃会话每次刷新
        // 都会调一次），而「遍历全部项目目录」是 O(项目数 × 目录项)。所以先用 cwd 的
        // 映射只查那一个目录，命中即返回；只有映射缺失或没命中时，才退化到遍历全部
        // 项目目录（映射表过期、cwd 与项目根写法不一致时仍然能找回记录）。
        let mapped = projectDirectory(for: cwd)
        if let mapped, let match = sessionFile(sessionId: sessionId, inDirectory: mapped) {
            return match
        }
        for name in projectDirectories() where name != mapped {
            if let match = sessionFile(sessionId: sessionId, inDirectory: name) { return match }
        }
        return nil
    }

    /// 在某个项目目录的 `chats/` 里找会话：文件名里的 id 被截断到 8 字符，因此先按
    /// 「前缀相等」匹配（廉价），再用首行的完整 sessionId 兜底。
    private func sessionFile(sessionId: String, inDirectory name: String) -> URL? {
        let files = sessionFiles(
            in: recordsRoot.appendingPathComponent(name).appendingPathComponent(chatsDirName))
        if let byName = files.first(where: { candidate in
            guard let truncated = filenameSessionId(candidate), truncated.count >= 4 else {
                return false
            }
            return sessionId.hasPrefix(truncated)
        }) {
            return byName
        }
        return files.first { firstLineField($0.path, key: "sessionId") == sessionId }
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasPrefix(recordsRoot.path + "/") else { return false }
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().lastPathComponent == chatsDirName else {
            return false
        }
        // 只认 JSONL（旧版整文档 `.json` 不支持，见文件头说明）。
        guard url.pathExtension == "jsonl" else { return false }
        return url.lastPathComponent.hasPrefix(sessionFilePrefix)
    }

    /// 会话 id 以记录首行的 `sessionId` 为准；首行解析不出来（文件被截断）时退回
    /// 文件名里那段截断的 id。
    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        if let id = firstLineField(path, key: "sessionId"), !id.isEmpty { return id }
        return filenameSessionId(URL(fileURLWithPath: path))
    }

    /// 工作目录：由记录所在的 `<项目目录>` 反查映射表，再退回 `.project_root`。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard let directory = projectDirectory(of: path) else { return nil }
        if let mapped = mappedCwd(forDirectory: directory) { return mapped }
        return projectRootMarker(inDirectory: directory)
    }

    /// 子 Agent 记录：Gemini 没有可识别的子会话文件布局，因此不认。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 项目目录解析

    /// 由 cwd 找项目目录：先查映射表，再扫 `tmp/*/` 比对 `.project_root`。
    private func projectDirectory(for cwd: String) -> String? {
        let projects = projectsMap()
        if let mapped = projects[cwd],
            FileManager.default.fileExists(atPath: recordsRoot.appendingPathComponent(mapped).path)
        {
            return mapped
        }
        for directory in projectDirectories() {
            if projectRootMarker(inDirectory: directory) == cwd { return directory }
        }
        return nil
    }

    /// 记录文件所在的项目目录名（`<记录根>/<目录>/chats/<文件>`）。
    private func projectDirectory(of path: String) -> String? {
        guard path.hasPrefix(recordsRoot.path + "/") else { return nil }
        let parts = path.dropFirst(recordsRoot.path.count + 1).split(separator: "/")
        guard parts.count >= 2, parts[1] == chatsDirName else { return nil }
        return String(parts[0])
    }

    private func projectDirectories() -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: recordsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        else { return [] }
        var directories: [String] = []
        for entry in entries
        where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            directories.append(entry.lastPathComponent)
        }
        return directories
    }

    private func sessionFiles(in chatsDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: chatsDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.filter { isTranscriptFile($0.path) }
    }

    private func projectsMap() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: projectsMapFile.path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = json["projects"] as? [String: String]
        else { return [:] }
        return projects
    }

    private func mappedCwd(forDirectory directory: String) -> String? {
        projectsMap().first { $0.value == directory }?.key
    }

    private func projectRootMarker(inDirectory directory: String) -> String? {
        let marker = recordsRoot.appendingPathComponent(directory).appendingPathComponent(".project_root")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `session-<时间戳>-<截断 id>` 里的 id 段。
    ///
    /// 时间戳是 `YYYY-MM-DDThh-mm`（本机实测 `session-2026-06-03T07-46-a2a-serv.jsonl`
    /// 对应 `"sessionId":"a2a-server"`），而被截断的 id 自己可能含短横线，所以不能取
    /// 「最后一段」——按时间戳的 5 段前缀切出来才对；切不出时间戳时整段当 id。
    private func filenameSessionId(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(sessionFilePrefix) else { return nil }
        let stem = String(name.dropFirst(sessionFilePrefix.count))
        let parts = stem.split(separator: "-", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5 else { return stem.isEmpty ? nil : stem }
        let id = String(parts[4])
        return id.isEmpty ? nil : id
    }

    private func firstLineField(_ path: String, key: String) -> String? {
        try? TranscriptFileReader.firstRecordField(
            in: path,
            predicate: { _ in true },
            value: { $0[key] as? String }
        )
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
