//
//  TerminalFocuser.swift
//  AgentIsland
//
//  把会话所在的终端带到前台。
//
//  三级回退，**yabai 不是前置条件**：
//   1. yabai：唯一能精确到「窗口」的路径（多窗口、多空间、同应用多标签时只有它能选对）。
//   2. tmux 客户端：会话跑在 tmux 里时，面板进程的祖先链上**没有**终端——tmux 服务端被
//      launchd 收养，pane 里的 shell 是它的子进程。只有 `tmux list-clients` 给出客户端 pid，
//      从那里往上才找得到终端应用。
//   3. 直接祖先：非 tmux 会话沿祖先链找 GUI 宿主应用。
//
//  第 2、3 步都靠「激活宿主应用」而不是「聚焦窗口」：「宿主应用」用 AppKit 判定
//  （有 bundle、activationPolicy 不是 prohibited），因此不需要维护终端品牌名单——
//  `TerminalAppRegistry` 那种子串匹配会漏掉 Ghostty/Warp/VS Code 的集成终端，还会把
//  `opencode` 这类含 "code" 的命令误判成 VS Code。
//

import AppKit
import Foundation
import os.log

/// 聚焦会话所在终端。
actor TerminalFocuser {
    static let shared = TerminalFocuser()

    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Focus")

    private init() {}

    /// 聚焦某个会话的终端。
    ///
    /// - Parameters:
    ///   - pid: 会话所属进程（集成上报的 pid；只有记录可读的会话可能为 nil）。
    ///   - workingDirectory: 会话工作目录，作为「没有 pid / pid 定位不到」时的退路。
    /// - Returns: 是否真的把某个窗口或应用带到了前台。
    func focus(pid: Int?, workingDirectory: String?) async -> Bool {
        // ① yabai：能精确到窗口
        if let pid, await YabaiController.shared.focusWindow(forClaudePid: pid) {
            return true
        }
        if let workingDirectory,
            await YabaiController.shared.focusWindow(forWorkingDirectory: workingDirectory)
        {
            return true
        }

        // ② 没有 yabai（或 yabai 没找到窗口）：激活宿主应用
        guard
            let hostPid = await hostApplicationPid(pid: pid, workingDirectory: workingDirectory)
        else {
            Self.logger.info("找不到可激活的终端宿主应用（pid=\(pid ?? -1, privacy: .public)）")
            return false
        }

        return await activate(pid: hostPid)
    }

    // MARK: - 宿主应用定位

    /// 宿主应用 pid：先试 tmux 客户端那侧，再试进程自己的祖先链。
    private func hostApplicationPid(pid: Int?, workingDirectory: String?) async -> Int? {
        let tree = ProcessTreeBuilder.shared.buildTree()

        if let pid {
            if let target = await TmuxTargetFinder.shared.findTarget(forClaudePid: pid),
                let host = await hostViaClients(of: target, tree: tree)
            {
                return host
            }
            if let host = Self.applicationAncestor(of: pid, tree: tree) {
                return host
            }
        }

        if let workingDirectory,
            let target = await TmuxTargetFinder.shared.findTarget(
                forWorkingDirectory: workingDirectory),
            let host = await hostViaClients(of: target, tree: tree)
        {
            return host
        }

        return nil
    }

    /// 某个 tmux 会话的客户端终端（可能同时有多个客户端连着）。
    private func hostViaClients(of target: TmuxTarget, tree: [Int: ProcessInfo]) async -> Int? {
        for clientPid in await TmuxTargetFinder.shared.clientPids(forSession: target.session) {
            if let host = Self.applicationAncestor(of: clientPid, tree: tree) {
                return host
            }
        }
        return nil
    }

    // MARK: - 纯判定（可单测）

    /// 沿祖先链找 GUI 宿主应用 pid。
    ///
    /// - Parameter isApplication: 「这个 pid 算不算 GUI 应用」的判定；默认问 AppKit，
    ///   单测传合成判定，因此不必起真进程。
    nonisolated static func applicationAncestor(
        of pid: Int,
        tree: [Int: ProcessInfo],
        isApplication: (Int) -> Bool = isGuiApplication
    ) -> Int? {
        ProcessTreeBuilder.shared.findAncestor(fromProcess: pid, tree: tree) {
            isApplication($0.pid)
        }
    }

    /// 生产判据：AppKit 认识这个 pid、它有 bundle、且不是 `prohibited`（纯命令行进程
    /// 没有 bundle，激活它们没有意义）。
    nonisolated static func isGuiApplication(_ pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        return app.bundleURL != nil && app.activationPolicy != .prohibited
    }

    // MARK: - 激活

    /// 激活宿主应用，把它所有窗口带上来。
    ///
    /// 用不带协作参数的 `activate(options:)`：实测（打包成 LSUIElement 的 .app 探针）它
    /// 能从**非前台**的进程把终端带到前台，只是生效是异步的（约 0.5–1.2s）——因此这个
    /// 返回值只代表「请求已被接受」，不代表此刻已经切过去了。
    /// 协作版 `activate(from:)` 要求调用方先 `yieldActivation`，只在「我们自己正前台」
    /// 时成立，而本应用两种处境都可能有（面板因通知展开、用户关掉「接管键盘焦点」时，
    /// 我们都不是前台），因此不用它。
    @MainActor
    private func activate(pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }

        let activated = app.activate(options: [.activateAllWindows])
        if !activated {
            Self.logger.info(
                "激活宿主应用被系统拒绝：pid=\(pid, privacy: .public) \(app.localizedName ?? "-", privacy: .public)"
            )
        }
        return activated
    }
}
