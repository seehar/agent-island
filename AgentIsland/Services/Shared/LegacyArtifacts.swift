//
//  LegacyArtifacts.swift
//  AgentIsland
//
//  改名（claude-island → agent-island）之前在用户磁盘上留下的 socket 残留与清理。
//  旧 socket 文件不清理不会立刻出错，但老客户端会继续往一个无人监听的地址发状态；
//  启动时统一扫一遍。集成文件的遗留清理在各自的安装器里（装/卸时顺手做，见
//  AgentIntegrationInstaller）。
//

import Foundation
import os.log

nonisolated enum LegacyArtifacts {
    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Integration")

    /// 改名前的 Unix socket：新版本绑的是 /tmp/agent-island.sock。
    static let legacySocketPaths = ["/tmp/claude-island.sock", "/tmp/claude-island.socket"]

    // 改名前的集成文件名不在这里：各 Agent 的安装器自己持有清单（Claude 的见
    // HookInstaller.legacyHookScriptNames，pi 系与 OpenCode 的见 AgentIntegrationInstaller），
    // 因为只有安装器知道该往哪个目录找、以及装/卸时要不要顺手清。

    /// 清理改名遗留的 socket 文件。
    ///
    /// 只在文件存在时尝试删除：有进程仍持有它时删除会失败，属预期情况（说明确实还有
    /// 老客户端在跑），不重试也不报错，记一条日志即可。
    static func removeLegacySockets() {
        for path in legacySocketPaths where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                logger.notice("已清理改名遗留的 socket：\(path, privacy: .public)")
            } catch {
                logger.debug(
                    "遗留 socket 未能删除（可能仍有进程持有）：\(path, privacy: .public) \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
