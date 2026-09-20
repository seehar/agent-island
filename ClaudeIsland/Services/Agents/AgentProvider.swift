//
//  AgentProvider.swift
//  ClaudeIsland
//
//  把「与具体 Agent 相关的知识」集中到一处：状态存放位置、会话 id 到记录
//  文件的映射、需要安装哪种实时集成。应用其余部分只通过会话解析协议
//  （见 `TranscriptSchema.swift`）访问 Agent。
//

import Foundation

/// 应用需要了解的单个 Agent CLI 的全部信息。
nonisolated protocol AgentProvider: Sendable {
    var kind: AgentKind { get }

    /// 解析当前配置下的磁盘布局。
    func paths() -> AgentPaths?

    /// 会话对应的记录文件；Agent 的历史无法用 (sessionId, cwd) 定位时返回 nil。
    func transcriptFile(sessionId: String, cwd: String) -> URL?

    /// 判断某个路径是否属于该 Agent 的会话记录。
    func isTranscriptFile(_ path: String) -> Bool

    /// 从记录文件名中还原会话 id。
    func sessionId(fromTranscriptFile path: String) -> String?

    /// 该记录文件创建时的工作目录。
    func cwd(fromTranscriptFile path: String) throws -> String?

    /// `sessionId` 派生的子 Agent 记录文件。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL]

    /// 实时集成的安装状态；无需集成时返回 nil。
    func integrationStatus() -> AgentIntegrationStatus?
}

/// 让 Agent 上报实时事件的辅助程序的安装状态。
nonisolated struct AgentIntegrationStatus: Sendable, Equatable {
    enum Health: String, Sendable {
        /// 辅助文件已就位，且 Agent 配置已指向它。
        case installed
        /// 辅助文件缺失，或 Agent 配置项被移除。
        case missing
        /// 找不到 Agent CLI，或无法自动写入其配置。
        case unavailable
    }

    let health: Health
    /// 安装器写入的文件列表（设置面板用于展示与定位）。
    let installedFiles: [URL]

    init(health: Health, installedFiles: [URL] = []) {
        self.health = health
        self.installedFiles = installedFiles
    }
}
