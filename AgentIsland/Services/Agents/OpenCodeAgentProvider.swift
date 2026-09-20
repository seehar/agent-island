//
//  OpenCodeAgentProvider.swift
//  AgentIsland
//
//  OpenCode 把会话历史存在 SQLite（`opencode.db`）里，另有一份已冻结的
//  旧版 JSON 目录。会话仅靠 id 定位，因此该 Provider 直接走数据库。
//

import Foundation
import os.log

nonisolated struct OpenCodeAgentProvider: AgentProvider {
    let kind: AgentKind = .opencode

    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "OpenCode")

    func paths() -> AgentPaths? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = home.appendingPathComponent(".local/share/opencode")
        guard FileManager.default.fileExists(atPath: dataDir.path) else { return nil }
        return AgentPaths(
            configDir: home.appendingPathComponent(".config/opencode"),
            sessionsDir: nil,
            pluginsDir: dataDir.appendingPathComponent("storage/plugin"),
            dataDir: dataDir
        )
    }

    /// 权威会话数据库路径。
    var databaseFile: URL? {
        guard let dataDir = paths()?.dataDir else { return nil }
        let db = dataDir.appendingPathComponent("opencode.db")
        return FileManager.default.fileExists(atPath: db.path) ? db : nil
    }

    // MARK: - 会话记录

    /// OpenCode 的历史在 SQLite 中，而不是「一个会话一个文件」。需要按文件
    /// 定位记录的能力（子 Agent 发现、中断监听）时，改由
    /// `AgentSessionDiscovery` 轮询数据库。
    func transcriptFile(sessionId: String, cwd: String) -> URL? { nil }

    func isTranscriptFile(_ path: String) -> Bool { false }

    func sessionId(fromTranscriptFile path: String) -> String? { nil }

    func cwd(fromTranscriptFile path: String) throws -> String? { nil }

    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        let configDir =
            paths()?.configDir
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode")
        let pluginDir = configDir.appendingPathComponent("plugins")
        let pluginFile = pluginDir.appendingPathComponent(
            AgentIntegrationInstaller.openCodePluginName)
        let installed = FileManager.default.fileExists(atPath: pluginFile.path)
        return AgentIntegrationStatus(
            health: installed ? .installed : .missing,
            installedFiles: [pluginFile]
        )
    }
}
