//
//  SessionListOrderingTests.swift
//  AgentIslandTests
//
//  会话列表的显示顺序（相位优先级 + 用户消息时间）。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("会话列表顺序")
struct SessionListOrderingTests {
    private func session(
        _ sessionId: String,
        phase: SessionPhase = .idle,
        lastActivity: Date = Date(),
        lastUserMessageAt: Date? = nil
    ) -> SessionState {
        SessionState(
            agent: .claudeCode,
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            phase: phase,
            conversationInfo: ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: lastUserMessageAt
            ),
            lastActivity: lastActivity
        )
    }

    @Test("排序：相位优先级优先，同级按最后一条用户消息倒序")
    func sortedByPhasePriorityThenUserMessage() {
        let now = Date()
        let model = session("model", phase: .idle, lastActivity: now)
        let waiting = session("waiting", phase: .waitingForInput, lastActivity: now)
        let approval = session(
            "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "t", toolName: "Bash", toolInput: nil, receivedAt: now)),
            lastActivity: now)
        let processing = session("processing", phase: .processing, lastActivity: now)
        let compacting = session("compacting", phase: .compacting, lastActivity: now)
        let ended = session("ended", phase: .ended, lastActivity: now)

        let ordered = SessionListOrdering.sorted([
            model, waiting, processing, ended, compacting, approval,
        ])
        #expect(
            Set(ordered.prefix(3).map(\.sessionId)) == ["processing", "compacting", "approval"],
            "待批/处理中/压缩上下文共用第一档（档内按时间倒序）")
        #expect(ordered[3].sessionId == "waiting")
        #expect(Set(ordered.suffix(2).map(\.sessionId)) == ["model", "ended"])
    }

    @Test("排序：同一相位按用户消息时间倒序，没有用户消息时回落最后活动时间")
    func sortedWithinSamePhase() {
        let now = Date()
        let older = session("older", lastUserMessageAt: now.addingTimeInterval(-600))
        let newer = session("newer", lastUserMessageAt: now.addingTimeInterval(-60))
        let silent = session("silent", lastActivity: now.addingTimeInterval(-300))

        let ordered = SessionListOrdering.sorted([older, silent, newer])
        #expect(ordered.map(\.sessionId) == ["newer", "silent", "older"])
    }

    @Test("排序是稳定的输入集合重排：数量与集合不变")
    func sortedKeepsEverySession() {
        let sessions = (0..<12).map { session("s\($0)") }
        let ordered = SessionListOrdering.sorted(sessions)
        #expect(ordered.count == sessions.count)
        #expect(Set(ordered.map(\.sessionId)) == Set(sessions.map(\.sessionId)))
    }
}
