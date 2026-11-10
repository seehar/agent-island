//
//  ChatScrollStateTests.swift
//  AgentIslandTests
//
//  聊天页「跟随到底」的三条判据：流式时末条正文变长也算尾部在动；暂停期间只在条数增长时
//  计数；回到最新要同时清空计数并重置基线。它们原先只活在视图里，改坏的表现是「答案输出时
//  视口自己往上漂」或「回到最新的数字不动」。
//
//  注意：`#expect` 的自动闭包里不能直接写 mutating 调用（`'$0' is immutable`），
//  所以每次先 `let` 再断言。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("聊天滚动状态")
struct ChatScrollStateTests {
    private func item(_ id: String, _ text: String) -> ChatHistoryItem {
        ChatHistoryItem(id: id, type: .assistant(text), timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test("未暂停时：条目增加要跟随，内容不变不跟随")
    func followsNewMessages() {
        var state = ChatScrollState()
        let old = [item("m1", "a")]
        let grown = state.noteHistoryChanged(from: old, to: old + [item("m2", "b")])
        #expect(grown)

        let unchanged = state.noteHistoryChanged(from: old, to: old)
        #expect(!unchanged)
    }

    @Test("未暂停时：条目数不变、末条正文变长（流式输出）也要跟随")
    func followsStreamingTail() {
        var state = ChatScrollState()
        let before = [item("m1", "a"), item("m2", "半句")]
        let after = [item("m1", "a"), item("m2", "半句接着说完了")]
        let follow = state.noteHistoryChanged(from: before, to: after)
        #expect(follow)
    }

    @Test("暂停期间不跟随，只把新增条数攒进计数")
    func countsWhilePaused() {
        var state = ChatScrollState()
        let base = [item("m1", "a")]
        state.pause(atCount: base.count)

        let oneMore = base + [item("m2", "b")]
        let follow1 = state.noteHistoryChanged(from: base, to: oneMore)
        #expect(!follow1)
        #expect(state.newMessageCount == 1)

        let twoMore = oneMore + [item("m3", "c")]
        let follow2 = state.noteHistoryChanged(from: oneMore, to: twoMore)
        #expect(!follow2)
        #expect(state.newMessageCount == 2)

        // 内容变化（条数不变）不计数。
        let streamed = Array(twoMore.dropLast()) + [item("m3", "c 变长")]
        let follow3 = state.noteHistoryChanged(from: twoMore, to: streamed)
        #expect(!follow3)
        #expect(state.newMessageCount == 2)
    }

    @Test("回到最新：恢复跟随并清空计数")
    func resumeClearsCount() {
        var state = ChatScrollState()
        let base = [item("m1", "a")]
        state.pause(atCount: base.count)
        _ = state.noteHistoryChanged(from: base, to: base + [item("m2", "b")])
        #expect(state.newMessageCount == 1)

        state.resume(atCount: 2)
        #expect(!state.isPaused)
        #expect(state.newMessageCount == 0)

        let follow = state.noteHistoryChanged(from: base, to: base + [item("m3", "c")])
        #expect(follow)
    }
}
