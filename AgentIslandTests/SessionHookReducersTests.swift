//
//  SessionHookReducersTests.swift
//  AgentIslandTests
//
//  hook 事件折算（工具跟踪 / 子 Agent 跟踪 / 总线事件）的纯逻辑用例。
//
//  这几段原先在 `SessionStore` 的 actor 里，只能靠真实 socket 事件驱动；抽成
//  `SessionHookReducers` 的静态函数后可以直接构造 `SessionState` 断言。事件用
//  JSON 解码构造，顺带钉住集成侧的信封字段名（snake_case）没有漂。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("hook 事件折算")
struct SessionHookReducersTests {
    // MARK: - 夹具

    private func makeSession(
        agent: AgentKind = .claudeCode,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        subagentState: SubagentState = SubagentState()
    ) -> SessionState {
        SessionState(
            agent: agent,
            sessionId: "s1",
            cwd: "/tmp/project",
            phase: phase,
            chatItems: chatItems,
            subagentState: subagentState
        )
    }

    /// 用集成侧真实信封形状（snake_case）构造事件。
    private func makeEvent(_ json: [String: Any]) throws -> HookEvent {
        var payload: [String: Any] = ["session_id": "s1", "cwd": "/tmp/project"]
        payload.merge(json) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(HookEvent.self, from: data)
    }

    private func toolCallItem(id: String, name: String, status: ToolStatus) -> ChatHistoryItem {
        ChatHistoryItem(
            id: id,
            type: .toolCall(
                ToolCallItem(
                    name: name,
                    input: [:],
                    status: status,
                    result: nil,
                    structuredResult: nil,
                    subagentTools: [],
                    subagentRuns: []
                )),
            timestamp: Date()
        )
    }

    private func toolCall(_ item: ChatHistoryItem) -> ToolCallItem? {
        guard case .toolCall(let tool) = item.type else { return nil }
        return tool
    }

    // MARK: - 工具跟踪

    @Test("PreToolUse 建顶层占位卡，入参按标量拍平成字符串")
    func preToolUseCreatesPlaceholderWithFlattenedInput() throws {
        var session = makeSession()
        let event = try makeEvent([
            "event": "PreToolUse",
            "status": "running_tool",
            "tool": "Bash",
            "tool_use_id": "t1",
            "tool_input": ["command": "ls -la", "timeout": 30, "dry": true],
        ])

        SessionHookReducers.processToolTracking(event: event, session: &session)

        #expect(session.chatItems.count == 1)
        let created = session.chatItems.first.flatMap(toolCall)
        #expect(created?.name == "Bash")
        #expect(created?.status == .running)
        // 数字与布尔也进字典（两条渲染路径共用同一份入参，口径不能分叉）。
        #expect(created?.input == ["command": "ls -la", "timeout": "30", "dry": "true"])
    }

    @Test("同一 tool_use_id 重复到达不再建第二张卡")
    func preToolUseIsIdempotentForSameToolUseId() throws {
        var session = makeSession(chatItems: [
            toolCallItem(id: "t1", name: "Bash", status: .running)
        ])
        let event = try makeEvent([
            "event": "PreToolUse", "status": "running_tool", "tool": "Bash",
            "tool_use_id": "t1",
        ])

        SessionHookReducers.processToolTracking(event: event, session: &session)

        #expect(session.chatItems.count == 1)
    }

    @Test("Claude 系子 Agent 的内部工具不升成顶层卡")
    func subagentInnerToolDoesNotBecomeTopLevelCard() throws {
        var subagents = SubagentState()
        subagents.startTask(taskToolId: "task1")
        var session = makeSession(subagentState: subagents)
        let event = try makeEvent([
            "event": "PreToolUse", "status": "running_tool", "tool": "Read",
            "tool_use_id": "r1",
        ])

        SessionHookReducers.processToolTracking(event: event, session: &session)

        // 只挂在父 Task 卡下面，顶层不出现占位卡。
        #expect(session.chatItems.isEmpty)
    }

    @Test("非 Claude 系在 Task 运行期间的工具仍属根会话，要建卡")
    func rootToolDuringTaskStillCreatesCard() throws {
        var subagents = SubagentState()
        subagents.startTask(taskToolId: "task1")
        var session = makeSession(agent: .ohMyPi, subagentState: subagents)
        let event = try makeEvent([
            "event": "PreToolUse", "status": "running_tool", "tool": "bash",
            "tool_use_id": "b1", "agent": "omp",
        ])

        SessionHookReducers.processToolTracking(event: event, session: &session)

        #expect(session.chatItems.count == 1)
    }

    @Test("PostToolUse 把待批/运行中的卡推进到成功")
    func postToolUseAdvancesCardToSuccess() throws {
        var session = makeSession(chatItems: [
            toolCallItem(id: "t1", name: "Bash", status: .waitingForApproval),
            toolCallItem(id: "t2", name: "Read", status: .success),
        ])
        let event = try makeEvent([
            "event": "PostToolUse", "status": "processing", "tool_use_id": "t1",
        ])

        SessionHookReducers.processToolTracking(event: event, session: &session)

        #expect(toolCall(session.chatItems[0])?.status == .success)
        // 已经是终态的卡不被重写（卡片还带着结果正文，重建会丢）。
        #expect(toolCall(session.chatItems[1])?.status == .success)
    }

    // MARK: - 子 Agent 表

    @Test("子 Agent 表按 parentToolCallId 写进对应 Task 卡")
    func subagentRunsLandOnTaskCard() {
        var subagents = SubagentState()
        subagents.upsertSubagent(
            id: "jobA", agent: "scout", status: .running, parentToolCallId: "task1")
        var session = makeSession(
            chatItems: [toolCallItem(id: "task1", name: "Task", status: .running)],
            subagentState: subagents
        )

        SessionHookReducers.syncSubagentRunsToChatItems(session: &session)

        let runs = toolCall(session.chatItems[0])?.subagentRuns ?? []
        #expect(runs.count == 1)
        #expect(runs.first?.id == "jobA")
    }

    @Test("没有任何子 Agent 时不动卡片（记录解析出来的行不能被空表擦掉）")
    func emptySubagentTableLeavesCardUntouched() {
        var session = makeSession(chatItems: [
            toolCallItem(id: "task1", name: "Task", status: .running)
        ])

        SessionHookReducers.syncSubagentRunsToChatItems(session: &session)

        #expect(toolCall(session.chatItems[0])?.subagentRuns.isEmpty == true)
    }

    // MARK: - 子 Agent 总线事件

    @Test("总线事件：子 Agent 在跑把相位提到处理中，全部结束落回等输入")
    func subagentBusEventDrivesPhase() throws {
        var session = makeSession()
        let started = try makeEvent([
            "event": "SubagentLifecycle",
            "status": "processing",
            "subagent_id": "jobA",
            "subagent_agent": "scout",
            "subagent_status": "running",
        ])

        SessionHookReducers.processSubagentBusEvent(event: started, session: &session)
        #expect(session.phase == .processing)
        #expect(session.subagentState.runningSubagentCount == 1)

        let finished = try makeEvent([
            "event": "SubagentLifecycle",
            "status": "processing",
            "subagent_id": "jobA",
            "subagent_agent": "scout",
            "subagent_status": "completed",
        ])
        SessionHookReducers.processSubagentBusEvent(event: finished, session: &session)

        #expect(session.phase == .waitingForInput)
        #expect(session.subagentState.runningSubagentCount == 0)
    }

    @Test("待批在手时子 Agent 的进度不许把「等待审批」拉走")
    func pendingDecisionBlocksBusEventPhaseChange() throws {
        var session = makeSession(
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: Date())))
        var event = try makeEvent([
            "event": "SubagentLifecycle",
            "status": "processing",
            "subagent_id": "jobA",
            "subagent_agent": "scout",
            "subagent_status": "running",
        ])
        event = event.withLivePending(true)

        SessionHookReducers.processSubagentBusEvent(event: event, session: &session)

        #expect(session.phase.isWaitingForApproval)
    }
}
