//
//  TranscriptEmissionTests.swift
//  AgentIslandTests
//
//  `TranscriptEmission.chatMessage` 的规则用例。
//
//  这个 helper 把 12 个 transcript schema 的记账尾部收口成一处，因此它自己的四条规则
//  必须钉住：标题只写一次、时间戳只随用户文本、末条消息随首段文本、写末条消息时清掉
//  过期的工具名。改这里等于改所有 Agent 的列表标题与排序依据。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("记录发射记账")
struct TranscriptEmissionTests {
    private func message(_ id: String, role: ChatRole, text: String, at: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, timestamp: at, content: [.text(text)])
    }

    @Test("标题只由第一条用户文本决定，后续用户消息不覆盖")
    func firstUserMessageWins() {
        var state = TranscriptParseState()
        var result = TranscriptReadResult()
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)

        TranscriptEmission.chatMessage(
            message("m1", role: .user, text: "第一条", at: first), isUser: true, text: "第一条",
            timestamp: first, state: &state, result: &result)
        TranscriptEmission.chatMessage(
            message("m2", role: .user, text: "第二条", at: second), isUser: true, text: "第二条",
            timestamp: second, state: &state, result: &result)

        #expect(state.firstUserMessage == "第一条")
        // 排序依据跟着最新一条用户消息走。
        #expect(state.lastUserMessageDate == second)
        #expect(state.messages.count == 2)
        #expect(result.newMessages.count == 2)
        #expect(result.activity.count == 2)
    }

    @Test("助手消息不写标题与用户时间戳，但更新末条消息")
    func assistantMessageSkipsTitleFields() {
        var state = TranscriptParseState()
        var result = TranscriptReadResult()
        let now = Date(timeIntervalSince1970: 300)

        TranscriptEmission.chatMessage(
            message("m1", role: .assistant, text: "好的", at: now), isUser: false, text: "好的",
            timestamp: now, state: &state, result: &result)

        #expect(state.firstUserMessage == nil)
        #expect(state.lastUserMessageDate == nil)
        #expect(result.activity.isEmpty)
        #expect(state.lastMessage == "好的")
        #expect(state.lastMessageRole == ChatRole.assistant.rawValue)
    }

    @Test("写末条消息时清掉过期的工具名")
    func staleToolNameIsCleared() {
        var state = TranscriptParseState()
        state.lastToolName = "Bash"
        var result = TranscriptReadResult()
        let now = Date(timeIntervalSince1970: 400)

        TranscriptEmission.chatMessage(
            message("m1", role: .user, text: "继续", at: now), isUser: true, text: "继续",
            timestamp: now, state: &state, result: &result)

        #expect(state.lastToolName == nil)
        #expect(state.lastMessageRole == ChatRole.user.rawValue)
    }

    @Test("没有文本块时不写末条消息、不发提示词事件，但消息本身仍然入队")
    func missingTextOnlyEnqueuesMessage() {
        var state = TranscriptParseState()
        var result = TranscriptReadResult()
        let now = Date(timeIntervalSince1970: 500)

        TranscriptEmission.chatMessage(
            message("m1", role: .assistant, text: "", at: now), isUser: false, text: nil,
            timestamp: now, state: &state, result: &result)

        #expect(state.messages.count == 1)
        #expect(state.lastMessage == nil)
        #expect(state.lastUserMessageDate == nil)
        #expect(result.activity.isEmpty)
    }
}
