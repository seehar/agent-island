//
//  SubagentLivenessTests.swift
//  AgentIslandTests
//
//  子 Agent 计数的「证据窗口」：上报是 fire-and-forget，丢一条 settled 帧就会留下
//  永远在跑的幽灵（实测应用连续运行十天后累计到一百多个）。这里钉住三件事：
//  只有窗口内还有上报的记录才算在跑；超窗记录由周期巡检落成终态并清掉当前工具；
//  已结束的会话不计它的子 Agent。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("子 Agent 证据窗口")
struct SubagentLivenessTests {
    private let now = Date()

    private var window: TimeInterval { SubagentState.evidenceTimeout }

    private func stale() -> Date { now.addingTimeInterval(-window - 60) }

    private func fresh() -> Date { now.addingTimeInterval(-60) }

    private func task(_ id: String, startedAt: Date) -> TaskContext {
        TaskContext(
            taskToolId: id, startTime: startedAt, agentId: nil, description: nil, subagentTools: [])
    }

    @Test("只有窗口内还有上报的 running 才算在跑")
    func countsOnlyRunsWithFreshEvidence() {
        var state = SubagentState()
        state.upsertSubagent(id: "fresh", agent: "scout", status: .running, now: fresh())
        state.upsertSubagent(id: "stale", agent: "scout", status: .running, now: stale())
        state.upsertSubagent(id: "done", agent: "scout", status: .completed, now: now)

        #expect(state.runningSubagentCount(at: now) == 1)
        #expect(state.runningSubagentCount == 1)
        #expect(state.subagents["stale"]?.isRunning(at: now) == false)
    }

    @Test("窗口边界：正好等于窗口时不再算在跑，差一秒仍算")
    func honoursTheExactBoundary() {
        var state = SubagentState()
        state.upsertSubagent(
            id: "boundary", agent: "scout", status: .running,
            now: now.addingTimeInterval(-window))
        state.upsertSubagent(
            id: "inside", agent: "scout", status: .running,
            now: now.addingTimeInterval(-window + 1))

        #expect(state.subagents["boundary"]?.isRunning(at: now) == false)
        #expect(state.subagents["inside"]?.isRunning(at: now) == true)
        #expect(state.runningSubagentCount(at: now) == 1)
    }

    @Test("新的上报会刷新证据时刻，记录重新算在跑")
    func newEvidenceRevivesARun() {
        var state = SubagentState()
        state.upsertSubagent(id: "run", agent: "scout", status: .running, now: stale())
        #expect(state.runningSubagentCount(at: now) == 0)

        state.upsertSubagent(
            id: "run", agent: "scout", status: .running, currentTool: "bash", now: now)
        #expect(state.runningSubagentCount(at: now) == 1)
    }

    @Test("周期巡检把超窗记录落成 unknown、清掉当前工具，冻结新记录")
    func expireMarksStaleRunsOnly() {
        var state = SubagentState()
        state.upsertSubagent(
            id: "stale", agent: "scout", status: .running, currentTool: "bash", now: stale())
        state.upsertSubagent(
            id: "fresh", agent: "scout", status: .running, currentTool: "read", now: fresh())

        let changed = state.expireStaleEvidence(now: now)
        #expect(changed)

        #expect(state.subagents["stale"]?.status == .unknown)
        #expect(state.subagents["stale"]?.currentTool == nil)
        #expect(state.subagents["fresh"]?.status == .running)
        #expect(state.subagents["fresh"]?.currentTool == "read")
        // 幂等：再巡检一次没有新的变更，避免周期任务每次重发状态。
        let changedAgain = state.expireStaleEvidence(now: now)
        #expect(changedAgain == false)
    }

    @Test("超窗的 Task 工具跟踪同样被清掉（Claude 系的计数兜底）")
    func expireDropsStaleTaskTracking() {
        var state = SubagentState()
        state.activeTasks["old"] = task("old", startedAt: stale())
        state.activeTasks["new"] = task("new", startedAt: fresh())

        let changed = state.expireStaleEvidence(now: now)
        #expect(changed)

        #expect(state.activeTasks["old"] == nil)
        #expect(state.activeTasks["new"] != nil)
        #expect(state.activeTaskCount(at: now) == 1)
    }

    @Test("子 Agent 全部超窗时退回 Task 工具计数，且同样按窗口过滤")
    func fallsBackToFreshTaskTracking() {
        var state = SubagentState()
        state.upsertSubagent(id: "stale", agent: "scout", status: .running, now: stale())
        state.activeTasks["fresh"] = task("fresh", startedAt: fresh())

        let session = SessionState(
            agent: .ohMyPi, sessionId: "sid", cwd: "/tmp", phase: .processing,
            subagentState: state)
        #expect(session.activeSubagentCount(at: now) == 1)

        var staleTasksOnly = state
        staleTasksOnly.activeTasks["fresh"] = task("fresh", startedAt: stale())
        let idle = SessionState(
            agent: .ohMyPi, sessionId: "sid", cwd: "/tmp", phase: .processing,
            subagentState: staleTasksOnly)
        #expect(idle.activeSubagentCount(at: now) == 0)
    }

    @Test("已结束的会话不计子 Agent（宿主进程都没了）")
    func endedSessionsDoNotCountSubagents() {
        var state = SubagentState()
        state.upsertSubagent(id: "run", agent: "scout", status: .running, now: now)

        let ended = SessionState(
            agent: .ohMyPi, sessionId: "sid", cwd: "/tmp", phase: .ended,
            subagentState: state)
        #expect(ended.activeSubagentCount(at: now) == 0)
    }
}
