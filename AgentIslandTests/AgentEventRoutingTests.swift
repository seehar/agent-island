//
//  AgentEventRoutingTests.swift
//  AgentIslandTests
//
//  各 Agent 的集成把事件发到同一个 socket，靠信封里的 `agent` 字段归属到具体会话。
//  这条链最容易出的错是「rawValue 与集成侧的 --source 不一致」——那时事件会**静默**
//  落到 Claude 名下（`HookEvent.agentKind` 的回退），界面上只表现为「另开了一个
//  Claude 会话」。这里按 hook 脚本真实发出的 snake_case 字节构造信封，走
//  字节 → HookEvent → SessionStore 的完整路径，为每个受支持的 Agent 钉一条。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("各 Agent 的事件信封路由", .serialized)
struct AgentEventRoutingTests {
    private func makeSessionId(_ label: String) -> String { "route-\(label)-\(UUID().uuidString)" }

    /// 按集成侧的真实信封（snake_case）编码并解码，覆盖 wire 格式解析。
    private func decodeEnvelope(
        agent: AgentKind,
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        extra: [String: Any] = [:]
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "session_id": sessionId,
            "cwd": cwd,
            "event": event,
            "status": status,
            "agent": agent.rawValue,
            "pid": 42,
            "tty": "/dev/ttys001",
        ]
        for (key, value) in extra { payload[key] = value }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(HookEvent.self, from: data)
    }

    @Test("每个受支持的 Agent 都能用自己的 rawValue 建立会话，并归属到正确的 Agent")
    func everyAgentOwnsItsEvents() async throws {
        for kind in AgentKind.allCases {
            let sessionId = makeSessionId(kind.rawValue)
            let cwd = FileManager.default.temporaryDirectory
                .appendingPathComponent("island-route-\(kind.rawValue)-\(UUID().uuidString)").path
            let key = SessionKey(agent: kind, sessionId: sessionId)

            let event = try decodeEnvelope(
                agent: kind, sessionId: sessionId, cwd: cwd,
                event: "SessionStart", status: "starting")
            #expect(event.agentKind == kind, "\(kind.rawValue) 的信封被归属成了别的 Agent")

            await SessionStore.shared.process(.hookReceived(event))

            let session = await SessionStore.shared.session(for: key)
            #expect(session != nil, "\(kind.rawValue) 的事件没有建立会话")
            #expect(session?.agent == kind)
            #expect(session?.sessionId == sessionId)
            #expect(session?.tty == "ttys001", "\(kind.rawValue) 的 tty 没有被规范化")

            await SessionStore.shared.process(.sessionEnded(key: key))
            // 「结束的会话是否立刻从列表里消失」取决于「保留已结束的会话」这条偏好，
            // 而同一次测试运行里的其它套件会改它（SessionStoreReplayTests 就有这种用例），
            // 所以这里只要求它不再是活跃会话，不写 nil 断言——那会让本用例随别人的用例漂。
            if let afterEnd = await SessionStore.shared.session(for: key) {
                #expect(afterEnd.phase == .ended, "\(kind.rawValue) 的会话没有被结束")
            }
        }
    }

    @Test("审批事件：能回传决定的 Agent 进待批相位，工具名与负载原样带过来")
    func approvalEventsBecomeWaitingPhase() async throws {
        let sessionId = makeSessionId("approval")
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-route-approval-\(UUID().uuidString)").path
        let key = SessionKey(agent: .codex, sessionId: sessionId)

        let event = try decodeEnvelope(
            agent: .codex, sessionId: sessionId, cwd: cwd,
            event: "PermissionRequest", status: "waiting_for_approval",
            extra: [
                "tool": "shell",
                "tool_use_id": "call-1",
                "expects_response": true,
                "tool_input": ["command": "rm -rf build"],
            ])

        #expect(event.agentKind == .codex)
        #expect(event.expectsResponse)
        #expect(event.agentKind.approval.canDecideRemotely)

        await SessionStore.shared.process(.hookReceived(event))

        let session = await SessionStore.shared.session(for: key)
        guard case .waitingForApproval(let context)? = session?.phase else {
            Issue.record("codex 的审批事件没有进入待批相位")
            await SessionStore.shared.process(.sessionEnded(key: key))
            return
        }
        #expect(context.toolName == "shell")
        #expect(context.toolUseId == "call-1")

        await SessionStore.shared.process(.sessionEnded(key: key))
    }

    @Test("不上报审批的 Agent 只由工具事件推进相位，不会出现待批卡片")
    func nonApprovalAgentsStayInProcessing() async throws {
        // Cursor 之类没有阻塞审批 hook 的工具：PreToolUse 只把相位推到「执行中」，
        // 卡片不能变成一副点了也没用的批准按钮。
        for kind in [AgentKind.cursor, .copilot, .trae, .cline, .kimi] {
            #expect(!kind.approval.canDecideRemotely)
            let sessionId = makeSessionId(kind.rawValue)
            let cwd = FileManager.default.temporaryDirectory
                .appendingPathComponent("island-route-plain-\(kind.rawValue)-\(UUID().uuidString)").path
            let key = SessionKey(agent: kind, sessionId: sessionId)

            let event = try decodeEnvelope(
                agent: kind, sessionId: sessionId, cwd: cwd,
                event: "PreToolUse", status: "running_tool",
                extra: ["tool": "shell", "tool_use_id": "call-9"])

            await SessionStore.shared.process(.hookReceived(event))
            let session = await SessionStore.shared.session(for: key)
            #expect(session?.phase == .processing, "\(kind.rawValue) 的工具事件没有推进相位")
            #expect(session?.agent == kind)

            await SessionStore.shared.process(.sessionEnded(key: key))
        }
    }
}
