//
//  AgentPaths.swift
//  AgentIsland
//
//  某个 Agent 在磁盘上的配置、会话与 hook 目录布局。
//

import Foundation

/// 单个 Agent 的目录布局，按当前配置解析一次。
nonisolated struct AgentPaths: Sendable, Equatable {
    /// 配置根目录，例如 `~/.claude` 或 `~/.omp/agent`。
    let configDir: URL
    /// 按项目分目录存放会话记录的位置；记录不集中在单一根目录时为 nil。
    let sessionsDir: URL?
    /// 插件目录，例如 omp 的 `~/.omp/plugins`、pi 的 `~/.pi`。
    let pluginsDir: URL?
    /// 数据根目录，例如 opencode 的 `~/.local/share/opencode`。
    let dataDir: URL?

    var hooksDir: URL { configDir.appendingPathComponent("hooks") }
    var settingsFile: URL { configDir.appendingPathComponent("settings.json") }

    init(configDir: URL, sessionsDir: URL? = nil, pluginsDir: URL? = nil, dataDir: URL? = nil) {
        self.configDir = configDir
        self.sessionsDir = sessionsDir
        self.pluginsDir = pluginsDir
        self.dataDir = dataDir
    }
}
