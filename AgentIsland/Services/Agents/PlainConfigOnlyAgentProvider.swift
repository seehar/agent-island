//
//  PlainConfigOnlyAgentProvider.swift
//  AgentIsland
//
//  「只知道配置目录、没有可解析的磁盘记录」的 Agent（Trae IDE / Trae CLI / DeepSeek
//  Harness）共用的 Provider：`paths()` 只回答配置目录在不在，记录类 API 一律返回
//  空值（这些工具的会话状态只能靠实时事件）。
//
//  事实来源：Trae IDE 与 Trae CLI 共用 `~/.trae`（hook 分别写在 `hooks.json` 与
//  `traecli.yaml`，见 `AgentHooks.swift` 的 trae / traeCli 两项，后者
//  `requiresExistingRoot = false`）；DSH 是插件运行时，只有 `~/.dsh` 配置目录，
//  事件由外部 dsh 插件直接写 socket（本机实测 `~/.dsh` 下 `sessions/` 是 zstd 压缩的
//  `session.jsonl.zstd`，Swift 侧没有解压 API，因此不解析记录）。
//

import Foundation

nonisolated struct PlainConfigOnlyAgentProvider: AgentProvider {
    let kind: AgentKind

    private let home: URL

    init(kind: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.kind = kind
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    /// 配置目录名：Trae IDE 与 Trae CLI 都是 `~/.trae`，DSH 是 `~/.dsh`。
    private var configDirName: String {
        switch kind {
        case .deepSeekHarness: return ".dsh"
        // 其余只可能是 trae / traeCli：本 Provider 只服务这三个 Agent。
        default: return ".trae"
        }
    }

    func paths() -> AgentPaths? {
        let configDir = home.appendingPathComponent(configDirName)
        guard FileManager.default.fileExists(atPath: configDir.path) else { return nil }
        return AgentPaths(configDir: configDir)
    }

    // MARK: - 会话记录

    func transcriptFile(sessionId: String, cwd: String) -> URL? { nil }

    func isTranscriptFile(_ path: String) -> Bool { false }

    func sessionId(fromTranscriptFile path: String) -> String? { nil }

    func cwd(fromTranscriptFile path: String) throws -> String? { nil }

    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
