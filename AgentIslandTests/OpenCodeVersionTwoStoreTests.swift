//
//  OpenCodeVersionTwoStoreTests.swift
//  AgentIslandTests
//
//  OpenCode 2.x 换了表结构：会话在 `session_v2`，消息与分片合进 `session_message`
//  （`assistant.data.content` 内嵌 text/reasoning/tool）。旧的 `session` / `message` /
//  `part` 三张表从此停更——只读旧表的版本会表现为「OpenCode 永远没有会话」。
//  这里用假库钉住三件事：v2 数据能读成会话与聊天气泡；没被迁移的历史消息仍能从
//  旧表读出来；消息 id 不严格同序时增量读取也不能漏消息。
//

import Foundation
import SQLite3
import Testing

@testable import AgentIsland

// 这些用例都会改「opencode 数据根」这个全局偏好（`AppSettings.agentRootOverride`），
// 并行跑会互相把对方的路径改走；串行执行。
@Suite("OpenCode v2 读取", .serialized)
struct OpenCodeVersionTwoStoreTests {
    // MARK: - 假库

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func exec(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK, let database
        else { throw OpenCodeDatabaseError.openFailed("假库打不开") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeDatabaseError.stepFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// 建一个含两代表结构的库（模拟从 1.x 迁移上来的 2.x 库）。
    private func makeDatabase(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("opencode.db")
        try exec(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            CREATE TABLE message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE TABLE part (
                id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            """, at: url)
        return url
    }

    private func insertVersionTwoSession(
        _ id: String, parentId: String? = nil, directory: String = "/tmp/work", title: String,
        updated: Int64, at url: URL
    ) throws {
        let parent = parentId.map { "'\($0)'" } ?? "NULL"
        try exec(
            """
            INSERT INTO session_v2 (id, parent_id, directory, title, time_created, time_updated)
            VALUES ('\(id)', \(parent), '\(directory)', '\(title)', \(updated), \(updated));
            """, at: url)
    }

    private func insertVersionTwoMessage(
        id: String, session: String, type: String, seq: Int, created: Int64, data: String,
        at url: URL
    ) throws {
        try exec(
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES ('\(id)', '\(session)', '\(type)', \(seq), \(created), \(created), '\(data)');
            """, at: url)
    }

    private func withDataRoot<T>(_ path: URL, _ body: () throws -> T) rethrows -> T {
        let previous = AppSettings.agentRootOverride(.opencode)
        AppSettings.setAgentRootOverride(.opencode, path: path.path)
        defer { AppSettings.setAgentRootOverride(.opencode, path: previous) }
        return try body()
    }

    // MARK: - 用例

    @Test("v2 会话表：只发现根会话，按最近活动排序")
    func discoversVersionTwoSessions() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try makeDatabase(in: root)

        try insertVersionTwoSession(
            "ses_old", title: "旧会话", updated: 1_000, at: database)
        try insertVersionTwoSession(
            "ses_new", title: "新会话", updated: 9_000, at: database)
        // 子代理会话不进列表。
        try insertVersionTwoSession(
            "ses_child", parentId: "ses_new", title: "子会话", updated: 9_500, at: database)

        try withDataRoot(root) {
            let sessions = OpenCodeSessionStore.sessions(
                since: Date(timeIntervalSince1970: 0), limit: 10)
            #expect(sessions.map(\.sessionId) == ["ses_new", "ses_old"])
            #expect(sessions.first?.title == "新会话")
            #expect(sessions.first?.cwd == "/tmp/work")
        }
    }

    @Test("v2 消息与内嵌分片：文本、推理、工具都还原成解析器认识的形状")
    func readsVersionTwoMessagesAndParts() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try makeDatabase(in: root)
        let session = "ses_a"
        try insertVersionTwoSession(session, title: "会话", updated: 2_000, at: database)

        try insertVersionTwoMessage(
            id: "msg_user", session: session, type: "user", seq: 1, created: 1_000,
            data: #"{"time":{"created":1000},"text":"hello v2","files":[],"agents":[]}"#,
            at: database)
        try insertVersionTwoMessage(
            id: "msg_assistant", session: session, type: "assistant", seq: 2, created: 2_000,
            data: """
                {"time":{"created":2000},"agent":"build",
                  "model":{"id":"glm-5.3","providerID":"opencode"},
                  "content":[
                      {"type":"reasoning","text":"think"},
                      {"type":"text","text":"answer"},
                      {"type":"tool","id":"call_1","name":"bash",
                        "state":{"status":"completed","input":{"command":"ls"},"output":"ok"}}],
                  "finish":"stop",
                  "tokens":{"input":10,"output":5,"cache":{"read":7,"write":3}}}
                """,
            at: database)

        try withDataRoot(root) {
            let messages = OpenCodeSessionStore.messages(
                sessionId: session, sinceCreated: nil, limit: 10)
            #expect(messages.map(\.id) == ["msg_user", "msg_assistant"])
            #expect(messages.map(\.role) == ["user", "assistant"])
            #expect(messages.last?.finish == "stop")

            let parts = OpenCodeSessionStore.parts(messageIds: messages.map(\.id))
            #expect(parts["msg_user"]?.map(\.type) == ["text"])
            #expect(parts["msg_user"]?.first?.text == "hello v2")
            #expect(parts["msg_assistant"]?.map(\.type) == ["reasoning", "text", "tool"])
            let tool = parts["msg_assistant"]?.last
            // v2 的 `id` / `name` 必须映射成旧版分片的 `callID` / `tool`。
            #expect(tool?.callId == "call_1")
            #expect(tool?.toolName == "bash")
            #expect(tool?.toolStatus == "completed")
            #expect(tool?.toolInput?["command"] as? String == "ls")
            #expect(tool?.toolOutput == "ok")
        }
    }

    @Test("端到端：v2 会话能解析出气泡、工具卡与 token 用量")
    func parsesVersionTwoTranscript() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try makeDatabase(in: root)
        let session = "ses_e2e"
        try insertVersionTwoSession(session, title: "会话", updated: 2_000, at: database)
        try insertVersionTwoMessage(
            id: "msg_u", session: session, type: "user", seq: 1, created: 1_000,
            data: #"{"time":{"created":1000},"text":"跑一下测试"}"#, at: database)
        try insertVersionTwoMessage(
            id: "msg_a", session: session, type: "assistant", seq: 2, created: 2_000,
            data: """
                {"time":{"created":2000},
                  "content":[
                      {"type":"text","text":"好"},
                      {"type":"tool","id":"call_9","name":"bash",
                        "state":{"status":"completed","input":{"command":"swift test"},"output":"pass"}}],
                  "finish":"stop",
                  "tokens":{"input":100,"output":20,"cache":{"read":40,"write":5}}}
                """,
            at: database)

        try withDataRoot(root) {
            var state = TranscriptParseState()
            let result = OpenCodeTranscriptSchema().read(
                sessionId: session, cwd: "/tmp/work", state: &state)

            #expect(result.newMessages.map(\.id) == ["msg_u", "msg_a"])
            let assistant = result.newMessages.last
            #expect(assistant?.content.count == 2)
            if case .toolUse(let tool)? = assistant?.content.last {
                #expect(tool.id == "call_9")
                #expect(tool.name == "bash")
            } else {
                Issue.record("助手消息里应当出现工具卡")
            }
            #expect(state.usage.inputTokens == 100)
            #expect(state.usage.outputTokens == 20)
            #expect(state.usage.cacheReadTokens == 40)
            #expect(state.usage.cacheCreationTokens == 5)
            #expect(state.toolResults["call_9"]?.content == "pass")
            #expect(state.completedToolIds.contains("call_9"))
        }
    }

    @Test("纯 v2 库（没有旧表）也能读消息与分片")
    func readsVersionTwoOnlyDatabase() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("opencode.db")
        try exec(
            """
            CREATE TABLE session_v2 (
              id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            CREATE TABLE session_message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
              seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
              data TEXT NOT NULL);
            """, at: database)
        try insertVersionTwoSession("ses_solo", title: "会话", updated: 2_000, at: database)
        try insertVersionTwoMessage(
            id: "m1", session: "ses_solo", type: "user", seq: 1, created: 1_000,
            data: #"{"time":{"created":1000},"text":"hi"}"#, at: database)
        try insertVersionTwoMessage(
            id: "m2", session: "ses_solo", type: "assistant", seq: 2, created: 2_000,
            data:
                #"{"time":{"created":2000},"content":[{"type":"text","text":"ok"}],"finish":"stop"}"#,
            at: database)

        try withDataRoot(root) {
            let messages = OpenCodeSessionStore.messages(
                sessionId: "ses_solo", sinceCreated: nil, limit: 10)
            #expect(messages.map(\.id) == ["m1", "m2"])
            let parts = OpenCodeSessionStore.parts(messageIds: ["m1", "m2"])
            #expect(parts["m1"]?.first?.text == "hi")
            #expect(parts["m2"]?.first?.text == "ok")
        }
    }

    @Test("v2 库里未被迁移的历史会话仍能从旧表读出")
    func fallsBackToLegacyTablesForUnmigratedSessions() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try makeDatabase(in: root)

        // 只有旧表里有这个会话与它的消息/分片。
        try exec(
            """
            INSERT INTO session (id, parent_id, directory, title, time_created, time_updated)
            VALUES ('ses_legacy', NULL, '/tmp/old', '旧会话', 1, 1);
            INSERT INTO message (id, session_id, time_created, time_updated, data)
            VALUES ('msg_old', 'ses_legacy', 1, 1, '{"role":"user","time":{"created":1}}');
            INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
            VALUES ('prt_old', 'msg_old', 'ses_legacy', 1, 1, '{"type":"text","text":"旧内容"}');
            """, at: database)

        try withDataRoot(root) {
            let messages = OpenCodeSessionStore.messages(
                sessionId: "ses_legacy", sinceCreated: nil, limit: 10)
            #expect(messages.map(\.id) == ["msg_old"])
            let parts = OpenCodeSessionStore.parts(messageIds: ["msg_old"])
            #expect(parts["msg_old"]?.first?.text == "旧内容")
        }
    }

    @Test("消息 id 不与时间同序时也不漏消息（只用「产出过没有」判定新内容）")
    func doesNotDropMessagesWithOutOfOrderIds() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try makeDatabase(in: root)
        let session = "ses_order"
        try insertVersionTwoSession(session, title: "会话", updated: 3_000, at: database)
        // 两条消息时间递增，但 id 的字典序相反（v2 里系统消息会造成这种情况）。
        try insertVersionTwoMessage(
            id: "msg_z", session: session, type: "assistant", seq: 1, created: 1_000,
            data:
                #"{"time":{"created":1000},"content":[{"type":"text","text":"先"}],"finish":"stop"}"#,
            at: database)

        try withDataRoot(root) {
            var state = TranscriptParseState()
            // 第一轮先读到 msg_z，游标停在该消息上（此时它是「id 更大」的那条）。
            _ = OpenCodeTranscriptSchema().read(
                sessionId: session, cwd: "/tmp/work", state: &state)

            // 之后写入的消息时间更晚，但 id 的字典序更小（v2 里系统消息会造成这种倒挂）。
            try insertVersionTwoMessage(
                id: "msg_a", session: session, type: "user", seq: 2, created: 2_000,
                data: #"{"time":{"created":2000},"text":"后"}"#, at: database)

            let result = OpenCodeTranscriptSchema().read(
                sessionId: session, cwd: "/tmp/work", state: &state)
            #expect(result.newMessages.map(\.id) == ["msg_a"])
        }
    }
}
