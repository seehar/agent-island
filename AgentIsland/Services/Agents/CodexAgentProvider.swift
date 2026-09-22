//
//  CodexAgentProvider.swift
//  AgentIsland
//
//  OpenAI Codex 的布局：`<CODEX_HOME 或 ~/.codex>/sessions/YYYY/MM/DD/rollout-<时间戳>-<uuid>.jsonl`，
//  hook 写在 `<CODEX_HOME>/hooks.json`。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:6396`（`~/.codex/sessions`）、
//  `:6777`（最近 7 天的 `YYYY/MM/DD` 目录）、`:6825`（`codexSessionCwd` 读首行
//  `payload.cwd`）、`:6845`（`extractCodexSessionId` 取文件名末 5 段 uuid）；根目录的
//  环境变量语义见同仓 `ConfigInstaller.codexHome()`（空白视作未设置，`~` 展开）。
//  本机实测首行：`{"type":"session_meta","payload":{"id":…,"cwd":…}}`。
//

import Foundation

nonisolated struct CodexAgentProvider: AgentProvider {
    let kind: AgentKind = .codex

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

    // MARK: - 布局

    /// 配置根：`$CODEX_HOME` 优先，否则 `~/.codex`。
    var configRoot: URL {
        AgentRootOverride.resolve(
            environment["CODEX_HOME"],
            fallback: home.appendingPathComponent(".codex"),
            home: home
        )
    }

    /// 会话根：记录按日期分目录放在 `sessions/` 下。
    var sessionsRoot: URL {
        configRoot.appendingPathComponent("sessions")
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

    /// 记录文件名里带着写入日期，与「会话属于哪个项目」无关，因此只能按
    /// `<会话 id>.jsonl` 后缀扫目录找回。
    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        guard
            let years = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)
        else { return nil }

        for year in years {
            guard
                let months = try? fm.contentsOfDirectory(at: year, includingPropertiesForKeys: nil)
            else { continue }
            for month in months {
                guard
                    let days = try? fm.contentsOfDirectory(
                        at: month, includingPropertiesForKeys: nil)
                else { continue }
                for day in days {
                    guard
                        let files = try? fm.contentsOfDirectory(
                            at: day, includingPropertiesForKeys: nil)
                    else { continue }
                    if let match = files.first(where: {
                        $0.lastPathComponent.hasSuffix("-\(sessionId).jsonl")
                    }) {
                        return match
                    }
                }
            }
        }
        return nil
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(sessionsRoot.path + "/") else {
            return false
        }
        return (path as NSString).lastPathComponent.hasPrefix("rollout-")
    }

    /// `rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl` 的会话 id 是末尾 5 段（uuid）。
    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        guard stem.hasPrefix("rollout-") else { return nil }
        let parts = stem.split(separator: "-")
        // rollout-YYYY-MM-DDThh-mm-ss-{8}-{4}-{4}-{4}-{12}：共 11 段。
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return stem
    }

    /// 首行是 `session_meta`，`payload.cwd` 即会话的工作目录。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard isTranscriptFile(path) else { return nil }
        return try TranscriptFileReader.firstRecordField(
            in: path,
            predicate: { $0["type"] as? String == "session_meta" },
            value: { ($0["payload"] as? [String: Any])?["cwd"] as? String }
        )
    }

    /// 子会话（`codex` 的 sub-session）在磁盘上仍是独立的 rollout 文件，没有可用的
    /// 父子映射，因此不认。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
