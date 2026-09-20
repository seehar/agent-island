//
//  TmuxSessionMatcherTests.swift
//  AgentIslandTests
//
//  tmux 目录匹配的公开入口是 findSessionId：它先把 pane 可见文本采成片段，再去会话
//  记录里数命中。私有的 extractSnippets / countMatchingSnippets 只被它调用，而它需要
//  活的 tmux 目标（测试里不得往用户的 tmux server 里建会话），因此这里钉的是选路的
//  安全底线：认不出来时返回 nil，绝不猜一个会话 id。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("tmux 会话匹配")
struct TmuxSessionMatcherTests {
    private var target: TmuxTarget {
        TmuxTarget(session: "island-no-such-session", window: "0", pane: "0")
    }

    @Test("目标不存在时返回 nil，不会猜一个会话 id")
    func unknownTargetYieldsNil() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-tmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = #"{"type":"user","message":{"role":"user","content":"这段文字不会出现在任何 pane 里"}}"#
        try content.write(
            to: directory.appendingPathComponent("aaaaaaaa-1111-2222-3333-444444444444.jsonl"),
            atomically: true, encoding: .utf8)

        let matched = await TmuxSessionMatcher.shared.findSessionId(forTarget: target, projectDir: directory)
        #expect(matched == nil)
    }

    @Test("目录不存在时返回 nil")
    func missingDirectoryYieldsNil() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-missing-\(UUID().uuidString)", isDirectory: true)
        let matched = await TmuxSessionMatcher.shared.findSessionId(forTarget: target, projectDir: directory)
        #expect(matched == nil)
    }
}
