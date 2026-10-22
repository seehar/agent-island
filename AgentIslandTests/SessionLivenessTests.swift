//
//  SessionLivenessTests.swift
//  AgentIslandTests
//
//  「处理中」心跳兜底的用例：Stop 丢了之后相位不能永远停在处理中，但也不能把
//  真在跑的长工具调用降级。窗口边界、记录文件 mtime 与事件时间取较晚者都要钉住。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("会话心跳")
struct SessionLivenessTests {
    private let now = Date()

    private func demotes(
        phase: SessionPhase = .processing,
        lastActivity: Date,
        transcriptModifiedAt: Date? = nil,
        hasRunningTool: Bool = false
    ) -> Bool {
        SessionLiveness.shouldDemoteProcessing(
            phase: phase,
            lastActivity: lastActivity,
            transcriptModifiedAt: transcriptModifiedAt,
            hasRunningTool: hasRunningTool,
            now: now)
    }

    @Test("事件与记录文件都超过窗口、又没有在跑的工具时降级")
    func demotesWhenNothingHasHappenedForTheWindow() {
        let stale = now.addingTimeInterval(-SessionLiveness.processingHeartbeatTimeout - 60)
        #expect(demotes(lastActivity: stale))
        // 记录文件同样陈旧时也是同一个结论。
        #expect(demotes(lastActivity: stale, transcriptModifiedAt: stale))
    }

    @Test("窗口内刚有心跳就不降级")
    func keepsSessionsWithRecentHeartbeat() {
        let recent = now.addingTimeInterval(-60)
        #expect(!demotes(lastActivity: recent))
        // 事件陈旧但记录文件刚长过：文件才是「它还在写」的证据。
        let stale = now.addingTimeInterval(-SessionLiveness.processingHeartbeatTimeout - 60)
        #expect(!demotes(lastActivity: stale, transcriptModifiedAt: recent))
    }

    @Test("工具还没回结果时不降级（长工具调用没有输出）")
    func keepsSessionsWithRunningTools() {
        let stale = now.addingTimeInterval(-SessionLiveness.processingHeartbeatTimeout - 60)
        #expect(!demotes(lastActivity: stale, hasRunningTool: true))
    }

    @Test("窗口边界：正好等于窗口时降级，差一秒不降")
    func honoursTheExactBoundary() {
        let atBoundary = now.addingTimeInterval(-SessionLiveness.processingHeartbeatTimeout)
        #expect(demotes(lastActivity: atBoundary))
        #expect(!demotes(lastActivity: atBoundary.addingTimeInterval(1)))
    }

    @Test("SessionState 版本：工具表里有在跑的工具就不降级")
    func keepsSessionsWhoseToolTrackerHasRunningTools() {
        let stale = now.addingTimeInterval(-SessionLiveness.processingHeartbeatTimeout - 60)
        var session = SessionState(
            agent: .ohMyPi, sessionId: "s-1", cwd: "/tmp", phase: .processing,
            lastActivity: stale)
        #expect(SessionLiveness.shouldDemoteProcessing(session: session, transcriptModifiedAt: nil, now: now))

        // 同一份会话，只要工具表里有一条在跑，就不该降级——这是 `inProgress` 的接线判据。
        session.toolTracker.startTool(id: "tool-1", name: "bash")
        #expect(
            !SessionLiveness.shouldDemoteProcessing(
                session: session, transcriptModifiedAt: stale, now: now))
    }

    @Test("只处理 processing：其它相位（含待批）不受时间兜底影响")
    func onlyProcessingIsDemoted() {
        let stale = now.addingTimeInterval(-SessionLiveness.processingHeartbeatTimeout - 60)
        let approval = PermissionContext(
            toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: stale)
        for phase in [SessionPhase.idle, .waitingForInput, .compacting, .ended] {
            #expect(!demotes(phase: phase, lastActivity: stale))
        }
        #expect(!demotes(phase: .waitingForApproval(approval), lastActivity: stale))
    }
}
