//
//  PaseoCli.swift
//  AgentIsland
//
//  经 Paseo CLI（`paseo terminal send-keys`）把消息写入 Paseo 托管终端的 pty。
//
//  为什么需要它：刘海的「发消息 / 中断」原来只有 tmux 一条路（`TmuxTargetFinder` +
//  `tmux send-keys`），而 Paseo（`@getpaseo/server`，「我的机器」的宿主）用它自己的
//  node-pty 起终端、**不经过 tmux**：这类会话的 `isInTmux` 恒为 false，输入框只能一直
//  置灰。Paseo 的终端输入在协议上是 `terminal_input`，官方 CLI 把它包成
//  `paseo terminal send-keys <终端 id> …`（内部与 `sendKeys` 同一条 `write()` 实现，
//  因此 `--literal <文本>\r` 等价于 typed text + 回车提交），这里复用它。
//
//  终端 id 来自集成上报的 `PASEO_TERMINAL_ID`（Paseo 注入到终端环境里）；daemon 对外
//  的终端列表只有 `{id, cwd, name}`，没有 pid/tty，所以**无法**从应用侧反查，只能由
//  会话自己上报。
//

import Foundation
import os.log

// MARK: - 调用形状（纯函数，可单测）

nonisolated enum PaseoCliInvocation {
    /// `paseo terminal send-keys` 发送消息：按字面写入文本 + `\r`（＝键入 + 回车）。
    /// 用 `--literal` 避免文本被解析成令牌（用户的消息自由文本里不包含我们想要触发的
    /// 特殊键；但 `\r` 是字节，与令牌 `Enter` 逐字节相同——`sendKeys` 与 `write`
    /// 在客户端是同一条实现，因此一次调用等价于「发送文本 + 发送回车」两次调用）。
    static func sendMessage(terminalId: String, text: String) -> [String] {
        ["terminal", "send-keys", "--literal", terminalId, "--", text + "\r"]
    }

    /// `paseo terminal send-keys` 中断：`C-c` 走令牌解析（不加 `--literal`），
    /// 客户端把它展开成 `\u{3}`（Ctrl-C 的 Unix 信号字节）。
    static func sendInterrupt(terminalId: String) -> [String] {
        ["terminal", "send-keys", terminalId, "C-c"]
    }
}

// MARK: - CLI 路径定位

nonisolated enum PaseoCliLocator {
    /// 找可执行的 paseo CLI 路径。
    /// - Parameters:
    ///   - preferred: 会话上报的 paseo 绝对路径（`PASEO_HOOK_CLI`）；优先使用。
    ///   - searchPaths: `searchDirectories(cliPath:home:)` 的输出。
    /// - Returns: 可执行文件的完整路径，或 nil。
    static func executablePath(preferred: String?, searchPaths: [String]) -> String? {
        if let preferred, FileManager.default.isExecutableFile(atPath: preferred) {
            return preferred
        }
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent("paseo")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// 候选目录（去重、保序）：CLI 所在目录 → 用户 PATH → nvm 各版本 → 常见安装位置。
    /// 除了搜 `paseo`，这些目录也用于在子进程 PATH 里放 `node`——CLI 的 shebang
    /// `#!/usr/bin/env -S node` 需要 `node` 在 PATH 上。
    static func searchDirectories(cliPath: String?, home: String, envPath: String?) -> [String] {
        var directories: [String] = []
        if let cliPath {
            directories.append((cliPath as NSString).deletingLastPathComponent)
        }
        if let envPath {
            directories.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        // nvm：版本目录里既有 node（shebang 需要）也有全局安装的 paseo
        let nvmRoot = (home as NSString).appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in sortedByVersionDescending(versions) {
                let bin = (nvmRoot as NSString).appendingPathComponent("\(version)/bin")
                directories.append(bin)
            }
        }
        directories.append(contentsOf: [
            (home as NSString).appendingPathComponent(".bun/bin"),
            (home as NSString).appendingPathComponent(".volta/bin"),
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent("Library/pnpm"),
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// nvm 版本目录名按数值降序（`v22.21.1` 在 `v9.11.2` 之前）。
    /// 纯字典序会把 `v9` 排到 `v22` 前面，从而优先用更老的 node 去跑 CLI 的 shebang。
    static func sortedByVersionDescending(_ versions: [String]) -> [String] {
        versions.sorted { lhs, rhs in
            let left = numericParts(lhs)
            let right = numericParts(rhs)
            for index in 0..<max(left.count, right.count) {
                let leftValue = index < left.count ? left[index] : 0
                let rightValue = index < right.count ? right[index] : 0
                if leftValue != rightValue {
                    return leftValue > rightValue
                }
            }
            // 数值完全一致时按原串定序，保证结果稳定。
            return lhs > rhs
        }
    }

    /// 取版本串里的数值段（`v22.21.1` → `[22, 21, 1]`）。
    private static func numericParts(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

// MARK: - 调用入口

/// 定位并调用 Paseo CLI 往指定终端的 pty 写入文本 / 中断信号。
actor PaseoCli {
    static let shared = PaseoCli()

    nonisolated static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Paseo")

    private init() {}

    /// 往 Paseo 托管终端的 pty 写入一条消息（文本 + 回车）。
    func sendMessage(_ message: String, toTerminal terminalId: String, cliPath: String?) async
        -> Bool
    {
        await invoke(
            PaseoCliInvocation.sendMessage(terminalId: terminalId, text: message),
            cliPath: cliPath)
    }

    /// 往 Paseo 托管终端的 pty 写入 Ctrl-C。
    func sendInterrupt(toTerminal terminalId: String, cliPath: String?) async -> Bool {
        await invoke(
            PaseoCliInvocation.sendInterrupt(terminalId: terminalId),
            cliPath: cliPath)
    }

    // MARK: - Private

    private func invoke(_ arguments: [String], cliPath: String?) async -> Bool {
        let searchPaths = PaseoCliLocator.searchDirectories(
            cliPath: cliPath,
            home: NSHomeDirectory(),
            // `ProcessInfo` 在仓内被 `ProcessTreeBuilder` 的同名结构体遮蔽，必须显式限定。
            envPath: Foundation.ProcessInfo.processInfo.environment["PATH"]
        )
        guard
            let executable = PaseoCliLocator.executablePath(
                preferred: cliPath, searchPaths: searchPaths
            )
        else {
            Self.logger.error("找不到 paseo CLI，无法写入 Paseo 终端")
            return false
        }

        // `paseo` CLI 是带 node shebang 的脚本（`#!/usr/bin/env -S node …`），而 GUI 进程
        // 的 PATH 通常没有 node。用 `/usr/bin/env PATH=<搜索目录> …` 注入搜索目录，
        // shebang 的 `env -S node` 因此能找到 node。
        let envPathValue = searchPaths.joined(separator: ":")
        let fullArguments = ["PATH=\(envPathValue)", executable] + arguments

        do {
            _ = try await ProcessExecutor.shared.run("/usr/bin/env", arguments: fullArguments)
            return true
        } catch {
            Self.logger.error("调用 paseo 失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
