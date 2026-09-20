//
//  ProcessTreeBuilderTests.swift
//  AgentIslandTests
//
//  进程树遍历用于判断「会话是不是跑在 tmux 里、终端是哪个」，全部是纯函数，
//  用手工构造的进程表断言，不依赖真实进程。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("进程树遍历")
struct ProcessTreeBuilderTests {
    private func tree(_ rows: [(pid: Int, ppid: Int, command: String)]) -> [Int: AgentIsland.ProcessInfo] {
        var result: [Int: AgentIsland.ProcessInfo] = [:]
        for row in rows {
            result[row.pid] = AgentIsland.ProcessInfo(pid: row.pid, ppid: row.ppid, command: row.command, tty: nil)
        }
        return result
    }

    @Test("isDescendant 认祖辈链上的进程，不认旁支与反方向")
    func isDescendantWalksUpwards() {
        let processTree = tree([
            (100, 1, "zsh"), (200, 100, "bash"), (300, 200, "node"), (400, 1, "zsh"),
        ])
        let builder = ProcessTreeBuilder.shared

        #expect(builder.isDescendant(targetPid: 300, ofAncestor: 100, tree: processTree))
        #expect(builder.isDescendant(targetPid: 200, ofAncestor: 100, tree: processTree))
        #expect(!builder.isDescendant(targetPid: 400, ofAncestor: 100, tree: processTree))
        #expect(!builder.isDescendant(targetPid: 100, ofAncestor: 300, tree: processTree))
    }

    @Test("isDescendant 把自身也算后代，未知 pid 返回 false")
    func isDescendantIsReflexiveAndSafe() {
        let processTree = tree([(100, 1, "zsh"), (200, 100, "bash")])
        let builder = ProcessTreeBuilder.shared

        #expect(builder.isDescendant(targetPid: 200, ofAncestor: 200, tree: processTree))
        #expect(!builder.isDescendant(targetPid: 999, ofAncestor: 100, tree: processTree))
        #expect(!builder.isDescendant(targetPid: 200, ofAncestor: 1, tree: processTree))
    }

    @Test("findDescendants 返回全部传递后代且不含自身")
    func findDescendantsReturnsTransitiveClosure() {
        let processTree = tree([
            (1, 0, "launchd"), (10, 1, "zsh"), (20, 1, "bash"), (11, 10, "node"), (21, 20, "node"),
            (22, 20, "node"),
        ])
        let builder = ProcessTreeBuilder.shared

        #expect(builder.findDescendants(of: 1, tree: processTree) == [10, 11, 20, 21, 22])
        #expect(builder.findDescendants(of: 20, tree: processTree) == [21, 22])
        #expect(builder.findDescendants(of: 11, tree: processTree).isEmpty)
    }

    @Test("父子关系成环时遍历仍然终止")
    func findDescendantsTerminatesOnCycle() {
        let processTree = tree([(5, 6, "zsh"), (6, 5, "zsh")])
        let result = ProcessTreeBuilder.shared.findDescendants(of: 5, tree: processTree)

        #expect(result.contains(6))
        #expect(result.count <= 2)
    }

    @Test("isInTmux 沿父链命中 tmux，且大小写不敏感")
    func isInTmuxDetectsAncestor() {
        let processTree = tree([(600, 500, "zsh"), (500, 400, "TMUX"), (400, 1, "login"), (700, 1, "zsh")])
        let builder = ProcessTreeBuilder.shared

        #expect(builder.isInTmux(pid: 600, tree: processTree))
        #expect(builder.isInTmux(pid: 500, tree: processTree))
        #expect(!builder.isInTmux(pid: 700, tree: processTree))
        #expect(!builder.isInTmux(pid: 9999, tree: processTree))
    }

    @Test("isInTmux 只沿父链走 20 层，更远的 tmux 不算")
    func isInTmuxStopsAtDepthLimit() {
        var rows: [(pid: Int, ppid: Int, command: String)] = []
        for index in 0..<25 {
            rows.append((1000 + index, 1001 + index, "zsh"))
        }
        rows.append((1025, 1, "tmux"))
        let far = tree(rows)
        let near = tree([(1000, 1001, "zsh"), (1001, 1002, "zsh"), (1002, 1003, "zsh"), (1003, 1, "tmux")])
        let builder = ProcessTreeBuilder.shared

        #expect(builder.isInTmux(pid: 1000, tree: near))
        #expect(!builder.isInTmux(pid: 1000, tree: far))
    }

    @Test("findTerminalPid 找到父链上的终端进程，找不到时返回 nil")
    func findTerminalPidFindsAncestor() {
        let processTree = tree([(800, 700, "zsh"), (700, 600, "bash"), (600, 1, "Terminal")])
        let noTerminal = tree([(900, 1000, "zsh"), (1000, 1, "launchd")])
        let builder = ProcessTreeBuilder.shared

        #expect(builder.findTerminalPid(forProcess: 800, tree: processTree) == 600)
        #expect(builder.findTerminalPid(forProcess: 900, tree: noTerminal) == nil)
    }

    @Test("findTerminalPid 从终端自身出发返回自身")
    func findTerminalPidReturnsSelfForTerminal() {
        let processTree = tree([(600, 1, "Terminal")])
        #expect(ProcessTreeBuilder.shared.findTerminalPid(forProcess: 600, tree: processTree) == 600)
    }
}
