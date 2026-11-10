//
//  ChatHistoryProjectionTests.swift
//  AgentIslandTests
//
//  投影规则：子 Agent 容器**内部**的工具调用要从扁平列表里摘掉（它们已折叠进容器卡片），
//  容器本身必须留下。这条规则原先藏在 `ChatHistoryManager` 的私有方法里，删多了界面上
//  会同时出现容器与它的每一项、删少了又是同一件事画两遍。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("聊天条目投影")
struct ChatHistoryProjectionTests {
    private func item(_ id: String, _ type: ChatHistoryItemType) -> ChatHistoryItem {
        ChatHistoryItem(id: id, type: type, timestamp: Date(timeIntervalSince1970: 0))
    }

    private func toolItem(_ id: String, name: String = "Task", subagentToolIDs: [String] = [])
        -> ChatHistoryItem
    {
        let nested = subagentToolIDs.map { subagentID in
            SubagentToolCall(
                id: subagentID, name: "Read", input: [:], status: .success, timestamp: Date(timeIntervalSince1970: 0))
        }
        return item(
            id,
            .toolCall(
                ToolCallItem(
                    name: name, input: [:], status: .success, result: nil,
                    structuredResult: nil, subagentTools: nested, subagentRuns: [])))
    }

    @Test("容器内部的工具调用被摘掉，容器本身保留")
    func hidesNestedSubagentTools() {
        let chatItems = [
            item("m1", .user("hi")),
            toolItem("task-1", subagentToolIDs: ["n1", "n2"]),
            toolItem("n1", name: "Read"),
            item("m2", .assistant("done")),
            toolItem("n2", name: "Bash"),
        ]

        let projected = ChatHistoryProjection.items(from: chatItems)

        #expect(projected.map(\.id) == ["m1", "task-1", "m2"])
    }

    @Test("没有子 Agent 容器时原样返回")
    func keepsEverythingWithoutContainers() {
        let chatItems = [item("m1", .user("a")), toolItem("t1", name: "Bash"), item("m2", .assistant("b"))]

        #expect(ChatHistoryProjection.items(from: chatItems).map(\.id) == ["m1", "t1", "m2"])
        #expect(ChatHistoryProjection.items(from: []).isEmpty)
    }

    @Test("只摘被容器真实包含的 id，不误伤同名工具")
    func onlyHidesIdsListedByContainer() {
        let chatItems = [
            toolItem("task-1", subagentToolIDs: ["n1"]),
            toolItem("n1", name: "Read"),
            toolItem("n9", name: "Read"),
        ]

        #expect(ChatHistoryProjection.items(from: chatItems).map(\.id) == ["task-1", "n9"])
    }

    @Test("按会话分桶：键与描述都跟着会话走，会话消失后不留残留")
    func projectsPerSession() {
        var first = SessionState(agent: .claudeCode, sessionId: "s1", cwd: "/tmp/a")
        first.chatItems = [item("m1", .user("hi")), toolItem("task-1", subagentToolIDs: ["n1"])]
        first.subagentState = SubagentState(agentDescriptions: ["agent-a": "查日志"])
        var second = SessionState(agent: .ohMyPi, sessionId: "s2", cwd: "/tmp/b")
        second.chatItems = [item("m2", .assistant("yo"))]

        let projected = ChatHistoryProjection.project([first, second])

        #expect(projected.histories[first.sessionKey]?.map(\.id) == ["m1", "task-1"])
        #expect(projected.histories[second.sessionKey]?.map(\.id) == ["m2"])
        #expect(projected.agentDescriptions[first.sessionKey] == ["agent-a": "查日志"])
        #expect(projected.agentDescriptions[second.sessionKey]?.isEmpty == true)

        // 会话结束（从数组里消失）后，投影里也不该再留下它。
        let afterEnd = ChatHistoryProjection.project([second])
        #expect(afterEnd.histories[first.sessionKey] == nil)
        #expect(afterEnd.agentDescriptions[first.sessionKey] == nil)
    }
}
