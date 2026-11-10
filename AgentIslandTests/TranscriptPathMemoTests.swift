//
//  TranscriptPathMemoTests.swift
//  AgentIslandTests
//
//  记录路径记忆表的契约：按「记录根 + 会话 id」隔离（串了就会把别的 Agent 的记录文件
//  当成自己的）、能失效、有上限兜底。表本身很简单，但键写错的表现是**跨 Agent 串文件**，
//  属于编译与渲染都抓不到的一类事故。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("记录路径记忆表")
struct TranscriptPathMemoTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("不同记录根下同名会话互不影响")
    func isolatesByRoot() {
        let memo = TranscriptPathMemo.shared
        let ompRoot = url("/tmp/memo-test/omp/sessions")
        let codexRoot = url("/tmp/memo-test/codex/sessions")
        let ompPath = url("/tmp/memo-test/omp/sessions/a/1_abc.jsonl")
        let codexPath = url("/tmp/memo-test/codex/sessions/2026/11/09/rollout-x-abc.jsonl")

        memo.store(ompPath, root: ompRoot, sessionId: "abc")
        memo.store(codexPath, root: codexRoot, sessionId: "abc")

        #expect(memo.lookup(root: ompRoot, sessionId: "abc") == ompPath)
        #expect(memo.lookup(root: codexRoot, sessionId: "abc") == codexPath)
        #expect(memo.lookup(root: url("/tmp/memo-test/other"), sessionId: "abc") == nil)

        memo.forget(root: ompRoot, sessionId: "abc")
        memo.forget(root: codexRoot, sessionId: "abc")
    }

    @Test("记住的路径可以反复取回，forget 之后失效")
    func storesAndForgets() {
        let memo = TranscriptPathMemo.shared
        let root = url("/tmp/memo-test/forget/sessions")
        let path = url("/tmp/memo-test/forget/sessions/b/2_def.jsonl")

        memo.store(path, root: root, sessionId: "def")
        for _ in 0..<3 {
            #expect(memo.lookup(root: root, sessionId: "def") == path)
        }

        memo.forget(root: root, sessionId: "def")
        #expect(memo.lookup(root: root, sessionId: "def") == nil)
    }

    @Test("超过上限后整体重置，不返回别人的路径")
    func resetsWhenOverCapacity() {
        let memo = TranscriptPathMemo.shared
        let root = url("/tmp/memo-test/capacity/sessions")

        for index in 0..<(TranscriptPathMemoTests.capacity + 16) {
            memo.store(
                url("/tmp/memo-test/capacity/\(index).jsonl"), root: root, sessionId: "s\(index)")
        }
        let last = url("/tmp/memo-test/capacity/\(TranscriptPathMemoTests.capacity + 15).jsonl")
        memo.store(last, root: root, sessionId: "s\(TranscriptPathMemoTests.capacity + 15)")
        #expect(
            memo.lookup(root: root, sessionId: "s\(TranscriptPathMemoTests.capacity + 15)") == last)
    }

    /// 上限值（与实现里的 `capacity` 同量级；这里用一个足够大的数只为把表填满一次）。
    private static let capacity = 512
}
