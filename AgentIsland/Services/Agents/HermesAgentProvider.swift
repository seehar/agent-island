//
//  HermesAgentProvider.swift
//  AgentIsland
//
//  Hermes（Nous Research，`hermes`）的布局：会话历史不在文件树里，而在
//  `<HERMES_HOME 或 ~/.hermes>/state.db` 的 SQLite 库里（`sessions` / `messages`
//  两张表）；hook 写在同一个 home 下的 `config.yaml` 的 `hooks:` 映射里。
//
//  事实来源：`~/.hermes/hermes-agent/hermes_constants.py:106 get_hermes_home()`（解析
//  顺序 = 上下文覆盖 → `HERMES_HOME` → 平台默认 `~/.hermes`）；库 schema 由本机
//  `state.db` 实测（`sessions.id/cwd/title/started_at/ended_at/parent_session_id/archived`、
//  `messages.id/session_id/role/content/tool_call_id/tool_calls/tool_name/timestamp/
//  token_count/finish_reason/reasoning/reasoning_content` 与
//  `idx_messages_session(session_id, timestamp)`）。
//

import Foundation
import os.log

nonisolated struct HermesAgentProvider: AgentProvider {
    let kind: AgentKind = .hermes

    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Hermes")

    /// 是否已经报告过「home 不存在」。
    ///
    /// `paths()` 会被 4 秒一轮的会话发现循环调用，而 home 不存在是常态（用户没装
    /// Hermes），逐次打日志会把 debug 流刷满，因此每个进程只报一次。
    nonisolated(unsafe) private static var didReportMissingHome = false

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

    /// Hermes 的 home：`$HERMES_HOME` 优先（那是 Hermes 自己的配置方式），其次用户在
    /// 设置面板里指定的目录（`AgentRootOverride`），否则 `~/.hermes`。会话库
    /// `state.db` 与 hook 配置 `config.yaml` 都在它下面，因此**这个目录同时影响安装与记录**。
    var hermesHome: URL {
        AgentRootOverride.resolve(
            environment["HERMES_HOME"],
            fallback: AgentRootOverride.userOverride(for: kind)
                ?? home.appendingPathComponent(".hermes"),
            home: home
        )
    }

    /// 记录不在文件树里（在 `state.db` 里），因此只回答配置根：`sessionsDir` /
    /// `dataDir` / `pluginsDir` 都留空。
    func paths() -> AgentPaths? {
        guard FileManager.default.fileExists(atPath: hermesHome.path) else {
            Self.reportMissingHome(hermesHome)
            return nil
        }
        return AgentPaths(configDir: hermesHome)
    }

    /// 权威会话库（`<home>/state.db`）；文件不存在时返回 nil。
    var databaseFile: URL? {
        let database = hermesHome.appendingPathComponent("state.db")
        return FileManager.default.fileExists(atPath: database.path) ? database : nil
    }

    /// 报告一次「home 不存在」。
    ///
    /// 这一步返回 nil 会让整个 Hermes 接入被静默跳过（发现不到会话、记录读不出内容），
    /// 界面上只表现为「没有会话」，因此留下日志说明原因。
    private static func reportMissingHome(_ hermesHome: URL) {
        guard !didReportMissingHome else { return }
        didReportMissingHome = true
        logger.debug("Hermes home 不存在（\(hermesHome.path, privacy: .public)），该 Agent 的接入被跳过")
    }

    // MARK: - 会话记录

    /// Hermes 的历史在 SQLite 中，而不是「一个会话一个文件」。需要按文件定位记录的
    /// 能力（子 Agent 发现、中断监听）时返回空，改由 `HermesSessionDiscovery` 轮询数据库。
    func transcriptFile(sessionId: String, cwd: String) -> URL? { nil }

    func isTranscriptFile(_ path: String) -> Bool { false }

    func sessionId(fromTranscriptFile path: String) -> String? { nil }

    func cwd(fromTranscriptFile path: String) throws -> String? { nil }

    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 集成状态

    /// 配置根不存在时 `hookConfigIntegrationStatus` 报 `.unavailable`（工具没装），
    /// 否则按 `AgentConfigInstaller` 的读回结果给 `.installed` / `.missing`。
    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}