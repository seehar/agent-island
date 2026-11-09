//
//  TranscriptPathMemo.swift
//  AgentIsland
//
//  「会话 id → 记录文件路径」的记忆表：给那些**只能靠遍历目录**找回记录文件的 Provider 用。
//
//  为什么要有它：不是所有 Agent 的记录都能由 (sessionId, cwd) 直接拼出路径——
//  pi/omp 的记录在 `<sessions>/<编码 cwd>/<时间戳>_<id>.jsonl` 里，兜底分支要遍历全部分桶；
//  Codex 按写入日期分层（`sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`），一次查找最多四层
//  `contentsOfDirectory`。而 `transcriptFile(sessionId:cwd:)` 在每次增量读取时都会被调一次
//  （`JSONLTranscriptSchema.read` 的第一行），采样（2026-11-09，10s）里解析路径上约三成样本
//  落在 `contentsOfDirectoryAtURL`。
//
//  一个会话的记录文件在生命周期里不会移动：分桶/日期目录由创建时刻决定，文件名里的会话 id
//  由 Agent 自己生成。因此解出来的路径可以直接复用。
//

import Foundation

/// `sessionId → 记录文件` 的记忆表。
///
/// 只记**命中过**的结果：没找到时会话可能还没写出首个记录，这个「没有」不能缓存。
/// 键里带上记录根目录，用户切换 Agent 配置目录后旧条目自然失效。
nonisolated final class TranscriptPathMemo: @unchecked Sendable {
    nonisolated static let shared = TranscriptPathMemo()

    private let lock = NSLock()
    private var paths: [String: URL] = [:]

    /// 上限只是兜底：一次运行里同时存在的会话数远小于它。
    private static let capacity = 512

    private init() {}

    /// 已经解出过的路径；没解过返回 nil。
    nonisolated func lookup(root: URL, sessionId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return paths[Self.key(root: root, sessionId: sessionId)]
    }

    /// 记下一条解析结果。
    nonisolated func store(_ url: URL, root: URL, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        if paths.count >= Self.capacity { paths.removeAll(keepingCapacity: true) }
        paths[Self.key(root: root, sessionId: sessionId)] = url
    }

    /// 让某条记忆失效（记录被删除/重建时用）。
    nonisolated func forget(root: URL, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        paths.removeValue(forKey: Self.key(root: root, sessionId: sessionId))
    }

    private static func key(root: URL, sessionId: String) -> String {
        root.path + "|" + sessionId
    }
}
