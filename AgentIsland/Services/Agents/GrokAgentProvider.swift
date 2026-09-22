//
//  GrokAgentProvider.swift
//  AgentIsland
//
//  Grok CLI 的布局：`<GROK_HOME 或 ~/.grok>/sessions/<百分号编码的 cwd>/<会话 id>/`，
//  会话正文在 `chat_history.jsonl`，元数据在 `summary.json`（`info.id` / `info.cwd`）；
//  hook 写在 `<GROK_HOME>/hooks/agent-island.json`。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:5179`（grokSessionCandidates：
//  `sessions/<编码 cwd>/<会话目录>`、summary.json 的 `info.cwd` 必须等于 cwd、
//  `info.id` 取会话 id、activity 取 summary 时间戳与 4 个文件的 mtime 最大值）、
//  `:4989`（grokEncodedCwd：只保留字母数字与 `-._~`，`/` 编成 `%2F`）；根解析见
//  `ConfigInstaller.grokHome()`（`$GROK_HOME` 优先，`~` 展开）。本机未安装 Grok
//  （`~/.grok` 不存在），布局未能在本机复核。
//

import Foundation

nonisolated struct GrokAgentProvider: AgentProvider {
    let kind: AgentKind = .grok

    private let home: URL
    private let environment: [String: String]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment
    ) {
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
        self.environment = environment
    }

    private let sessionsDirName = "sessions"
    private let chatHistoryFileName = "chat_history.jsonl"
    private let summaryFileName = "summary.json"

    // MARK: - 布局

    /// 配置根：`$GROK_HOME` 优先，否则 `~/.grok`。
    var configRoot: URL {
        AgentRootOverride.resolve(
            environment["GROK_HOME"],
            fallback: home.appendingPathComponent(".grok"),
            home: home
        )
    }

    var sessionsRoot: URL {
        configRoot.appendingPathComponent(sessionsDirName)
    }

    func paths() -> AgentPaths? {
        guard FileManager.default.fileExists(atPath: configRoot.path) else { return nil }
        return AgentPaths(
            configDir: configRoot,
            sessionsDir: sessionsRoot,
            pluginsDir: nil,
            dataDir: nil
        )
    }

    // MARK: - 会话记录

    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        let direct = sessionDirectory(for: cwd, sessionId: sessionId)
            .appendingPathComponent(chatHistoryFileName)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // 记录的 cwd 写法可能与磁盘上的项目目录不同（例如 `/tmp` 与 `/private/tmp`），
        // 按会话 id 在项目目录下兜底扫一层。
        return GrokAgentProvider.sessionDirectories(in: sessionsRoot)
            .first { $0.lastPathComponent == sessionId }?
            .appendingPathComponent(chatHistoryFileName) ?? direct
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasPrefix(sessionsRoot.path + "/") else { return false }
        return (path as NSString).lastPathComponent == chatHistoryFileName
    }

    /// 会话 id：`summary.json` 的 `info.id` 为准，缺失时用目录名。
    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        if let summary = summary(at: URL(fileURLWithPath: directory)),
            let id = summary.id, !id.isEmpty
        {
            return id
        }
        let fallback = (directory as NSString).lastPathComponent
        return fallback.isEmpty ? nil : fallback
    }

    /// 工作目录：`summary.json` 的 `info.cwd` 为准（精确），缺失时把项目目录名
    /// 百分号解码回来（编码可逆）。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard isTranscriptFile(path) else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        if let summary = summary(at: directory), let cwd = summary.cwd, !cwd.isEmpty {
            return cwd
        }
        let encoded = directory.deletingLastPathComponent().lastPathComponent
        return encoded.removingPercentEncoding
    }

    /// 子 Agent 记录：Grok 没有可识别的子会话文件布局，因此不认。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 目录与元数据

    /// `summary.json` 里本 Provider 用到的两个字段。
    private struct SessionSummary {
        let id: String?
        let cwd: String?
    }

    private func summary(at directory: URL) -> SessionSummary? {
        let file = directory.appendingPathComponent(summaryFileName)
        guard let data = FileManager.default.contents(atPath: file.path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = json["info"] as? [String: Any]
        else { return nil }
        return SessionSummary(id: info["id"] as? String, cwd: info["cwd"] as? String)
    }

    private func sessionDirectory(for cwd: String, sessionId: String) -> URL {
        guard let encoded = GrokAgentProvider.encodedCwd(cwd) else {
            return sessionsRoot.appendingPathComponent(sessionId)
        }
        return sessionsRoot.appendingPathComponent(encoded).appendingPathComponent(sessionId)
    }

    private static func sessionDirectories(in sessionsRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard
            let projects = try? fm.contentsOfDirectory(
                at: sessionsRoot, includingPropertiesForKeys: nil)
        else { return [] }
        return projects.flatMap { project -> [URL] in
            (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []
        }
    }

    /// Grok 把整个 cwd 百分号编码成一个目录名（`/` → `%2F`），只保留字母数字
    /// 与 `-._~`。
    nonisolated static func encodedCwd(_ cwd: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
