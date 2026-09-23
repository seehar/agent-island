//
//  TerminalFocuserTests.swift
//  AgentIslandTests
//
//  「聚焦终端」的宿主应用定位是纯函数（进程表进、pid 出），这里用手工构造的进程表断言，
//  不依赖真实进程，也不需要 tmux 或 yabai。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("聚焦终端的宿主应用定位")
struct TerminalFocuserTests {
    private func tree(_ rows: [(pid: Int, ppid: Int, command: String)]) -> [Int: AgentIsland
        .ProcessInfo]
    {
        var result: [Int: AgentIsland.ProcessInfo] = [:]
        for row in rows {
            result[row.pid] = AgentIsland.ProcessInfo(
                pid: row.pid, ppid: row.ppid, command: row.command, tty: nil)
        }
        return result
    }

    @Test("跳过非应用进程，返回祖先链上第一个 GUI 应用")
    func findsFirstApplicationUpwards() {
        // claude → zsh → tmux 服务端 → … → 终端应用。中间那几个都不是应用。
        let processTree = tree([
            (800, 700, "claude"), (700, 600, "zsh"), (600, 500, "tmux"),
            (500, 400, "login"), (400, 1, "Ghostty"),
        ])
        let applications: Set<Int> = [400]

        #expect(
            TerminalFocuser.applicationAncestor(of: 800, tree: processTree) {
                applications.contains($0)
            } == 400)
    }

    @Test("起点自己就是应用时返回自身（tmux 客户端 pid 直接命中终端应用）")
    func returnsSelfForApplication() {
        let processTree = tree([(600, 1, "iTerm2"), (900, 600, "zsh")])
        #expect(
            TerminalFocuser.applicationAncestor(of: 600, tree: processTree) { $0 == 600 } == 600)
    }

    @Test("链上没有应用（例如会话来自断开连接的终端）返回 nil")
    func returnsNilWithoutApplication() {
        let processTree = tree([(800, 700, "claude"), (700, 1, "launchd")])
        #expect(
            TerminalFocuser.applicationAncestor(of: 800, tree: processTree) { _ in false } == nil)
    }

    @Test("判定不看命令名：改名/未知终端（Ghostty、Warp、VS Code 集成终端）一样能命中")
    func judgementDoesNotDependOnCommandName() {
        let processTree = tree([(800, 700, "claude"), (700, 1, "Code Helper (Renderer)")])
        #expect(
            TerminalFocuser.applicationAncestor(of: 800, tree: processTree) { $0 == 700 } == 700)
    }
}
