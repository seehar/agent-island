//
//  KimiAgentProvider.swift
//  AgentIsland
//
//  Kimi Code CLI 的布局（两代并存）：
//    · kimi-code（`~/.kimi-code`）：`session_index.jsonl` 记录
//      `{sessionId, sessionDir, workDir}`，会话正文在 `<sessionDir>/agents/main/wire.jsonl`；
//    · 旧版 kimi-cli（`~/.kimi`）：`sessions/<md5(cwd)>/<会话 id>/wire.jsonl`。
//  hook 写在数据根的 `config.toml`。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:4751`（findActiveKimiSessions：
//  两个根、旧版 md5 分目录）、`:4860`（discoverKimiCodeSessionFromIndex：索引字段与
//  `agents/main/wire.jsonl`）、`:4938`（readRecentFromKimiTranscript 的两种信封）、
//  `:4746`（md5Hash：小写 hex）；根解析见 `ConfigInstaller.kimiHome()`（优先
//  `~/.kimi-code`，缺失时退回 `~/.kimi`）。旧版把 cwd 的 md5 当目录名，**无法反推
//  cwd**，因此旧版记录只有在实时事件带来 cwd 时才能建立会话（见 `cwd(fromTranscriptFile:)`）。
//

import CryptoKit
import Foundation

nonisolated struct KimiAgentProvider: AgentProvider {
    let kind: AgentKind = .kimi

    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    private let modernDirName = ".kimi-code"
    private let legacyDirName = ".kimi"
    private let sessionsDirName = "sessions"
    private let indexFileName = "session_index.jsonl"
    private let wireFileName = "wire.jsonl"
    private let mainWireRelativePath = "agents/main/wire.jsonl"

    // MARK: - 布局

    /// kimi-code（现行）根：用户在设置面板里指定的目录优先（`AgentRootOverride`），
    /// 否则 `~/.kimi-code`。
    var modernRoot: URL {
        AgentRootOverride.userOverride(for: kind) ?? home.appendingPathComponent(modernDirName)
    }

    /// 旧版 kimi-cli 根（`~/.kimi`）。
    var legacyRoot: URL {
        home.appendingPathComponent(legacyDirName)
    }

    /// 数据根：用户指定了目录就**钉死**它（不再做现代/旧版择优——他已经指了目录，再去
    /// 别的根找记录、写配置就是错配）；没指定时 `~/.kimi-code` 优先，缺失才退回
    /// `~/.kimi`（迁移期两代并存）。
    ///
    /// 两代都不存在时给**现代**路径（与 CodeIsland `kimiHome(fm:)` 一致）。这条口径
    /// 只有一处：安装器也调 `preferredRoot(home:)`，不许各写一份——否则会出现
    /// 「读记录看现代根、写配置落旧根」这种谁都没装却互不相认的状态。
    var configRoot: URL {
        AgentRootOverride.userOverride(for: kind) ?? Self.preferredRoot(home: home)
    }

    /// 配置/数据根的择优（供 Provider 与安装器共用）。
    nonisolated static func preferredRoot(home: URL) -> URL {
        let modern = home.appendingPathComponent(".kimi-code")
        let legacy = home.appendingPathComponent(".kimi")
        let fm = FileManager.default
        if fm.fileExists(atPath: modern.path) { return modern }
        if fm.fileExists(atPath: legacy.path) { return legacy }
        return modern
    }

    /// 记录根候选：没指定目录时两代并存（现代优先），指定了就只剩它。
    var roots: [URL] {
        guard let override = AgentRootOverride.userOverride(for: kind) else {
            return [modernRoot, legacyRoot]
        }
        return [override]
    }

    /// 旧版布局（`sessions/<md5(cwd)>/<会话 id>/wire.jsonl`）的基准根：没指定目录时是
    /// `~/.kimi`；指定了目录时两代布局都落在那个数据根下。
    private var legacyLayoutRoot: URL {
        AgentRootOverride.userOverride(for: kind) ?? legacyRoot
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
        let fm = FileManager.default
        // kimi-code：会话目录由索引给出（不一定等于 `<记录根>/sessions/<会话 id>`）。
        if let entry = indexEntries().first(where: { $0.sessionId == sessionId }) {
            for candidate in wireCandidates(in: entry.sessionDir)
            where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // 旧版：`sessions/<md5(cwd)>/<会话 id>/wire.jsonl`。
        let legacy =
            legacyLayoutRoot
            .appendingPathComponent(sessionsDirName)
            .appendingPathComponent(KimiAgentProvider.workdirHash(for: cwd))
            .appendingPathComponent(sessionId)
            .appendingPathComponent(wireFileName)
        if fm.fileExists(atPath: legacy.path) { return legacy }
        // 兜底：两个根的 `sessions/<会话 id>/` 下找一层。
        for root in roots {
            let directory = root.appendingPathComponent(sessionsDirName)
                .appendingPathComponent(sessionId)
            for candidate in wireCandidates(in: directory)
            where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard (path as NSString).lastPathComponent == wireFileName else { return false }
        return roots.contains {
            path.hasPrefix($0.appendingPathComponent(sessionsDirName).path + "/")
        }
    }

    /// 会话 id：优先按 `session_index.jsonl` 的映射取；没有索引时按目录名 ——
    /// kimi-code 是 `<会话目录>/agents/main/wire.jsonl`（上两级），旧版是
    /// `<md5(cwd)>/<会话 id>/wire.jsonl`（上一级）。
    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        if let indexed = indexedEntry(forTranscriptPath: path) { return indexed.sessionId }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let parent = directory.lastPathComponent
        if parent == "main" {
            let id = directory.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent
            return id.isEmpty ? nil : id
        }
        return parent.isEmpty ? nil : parent
    }

    /// 工作目录：kimi-code 由索引给出；旧版的目录名是 md5(cwd)，**无法反推**，
    /// 因此返回 nil（该版本的会话只能靠实时事件带来 cwd）。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard isTranscriptFile(path) else { return nil }
        return indexedEntry(forTranscriptPath: path)?.workDir
    }

    /// 子 Agent 记录：kimi 的 `agents/` 目录结构里没有可识别的子会话命名，因此不认。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 索引

    /// `session_index.jsonl` 的一行：kimi-code 用它把「会话目录 ↔ 工作目录」对上。
    struct IndexedSession: Sendable, Equatable {
        let sessionId: String
        let sessionDir: URL
        let workDir: String
    }

    /// 索引指纹：路径 + 大小 + mtime，任一变化都重新解析。
    private struct IndexSignature: Equatable {
        let file: String
        let size: Int
        let modified: Date?

        init(file: URL) {
            self.file = file.path
            let values = try? file.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            self.size = values?.fileSize ?? -1
            self.modified = values?.contentModificationDate
        }
    }

    /// 最近一次解析出来的索引 + 它的指纹。
    ///
    /// 必须缓存：`sessionId` / `cwd` 会被**逐条记录**调用（一轮发现 = O(会话数) 次，
    /// 发现循环 4 秒一轮、用量枚举 60 秒一轮），每次重读整个索引会把一轮变成
    /// O(会话数²) 的解析。指纹里带路径，保证注入不同 home 的用例互不串味。
    nonisolated(unsafe) private static var indexCache: (
        signature: IndexSignature, entries: [IndexedSession]
    )?
    private static let indexCacheLock = NSLock()

    func indexEntries() -> [IndexedSession] {
        let file = modernRoot.appendingPathComponent(indexFileName)
        let signature = IndexSignature(file: file)

        Self.indexCacheLock.lock()
        if let cached = Self.indexCache, cached.signature == signature {
            Self.indexCacheLock.unlock()
            return cached.entries
        }
        Self.indexCacheLock.unlock()

        let entries = KimiAgentProvider.parseIndex(at: file)

        Self.indexCacheLock.lock()
        Self.indexCache = (signature, entries)
        Self.indexCacheLock.unlock()
        return entries
    }

    private static func parseIndex(at file: URL) -> [IndexedSession] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var entries: [IndexedSession] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessionId = json["sessionId"] as? String, !sessionId.isEmpty,
                let sessionDir = json["sessionDir"] as? String, !sessionDir.isEmpty,
                let workDir = json["workDir"] as? String, !workDir.isEmpty
            else { continue }
            entries.append(
                IndexedSession(
                    sessionId: sessionId,
                    // 归一软链写法（`/var` → `/private/var`）：下面按前缀比对时，
                    // 一侧来自目录遍历（已解析软链）、一侧来自索引文件，不归一就会
                    // 判不相等、会话丢掉 cwd。
                    sessionDir: AgentProviderRoot.canonical(URL(fileURLWithPath: sessionDir)),
                    workDir: workDir
                ))
        }
        return entries
    }

    /// 记录文件所属的索引条目（索引里的 `sessionDir` 是记录文件所在目录的祖先）。
    private func indexedEntry(forTranscriptPath path: String) -> IndexedSession? {
        // 调用方给的路径可能是软链写法（实时事件里的 `transcript_path`），归一到与
        // 索引同一种写法再比前缀；单次 realpath 远比重读索引便宜。
        let canonicalPath = AgentProviderRoot.canonical(URL(fileURLWithPath: path)).path
        return indexEntries().first { canonicalPath.hasPrefix($0.sessionDir.path + "/") }
    }

    private func wireCandidates(in sessionDir: URL) -> [URL] {
        [
            sessionDir.appendingPathComponent(mainWireRelativePath),
            sessionDir.appendingPathComponent(wireFileName),
        ]
    }

    /// 旧版 kimi-cli 用 cwd 的 md5（小写 hex）作分目录名。
    nonisolated static func workdirHash(for cwd: String) -> String {
        Insecure.MD5.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
