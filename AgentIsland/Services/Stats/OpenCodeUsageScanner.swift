//
//  OpenCodeUsageScanner.swift
//  AgentIsland
//
//  OpenCode 的历史不在文件里而在 SQLite（`opencode.db`）里，因此按天统计要单独
//  走一条数据库路径。这里**只读**打开（走 `OpenCodeDatabase`，与会话列表同一套），
//  按「消息」为粒度取增量：
//    · token 在 `message.data.tokens` 里（`cache.read` / `cache.write` 对应缓存读/写），
//      模型标识取 `message.data.modelID`（提供方 `providerID` 不算维度）；
//    · 工具调用是 `part` 表里 `type == "tool"` 的行，工具名取 `data.tool`；
//    · 时间取 `message.time_created`（毫秒 epoch），子代理会话由 `session.parent_id` 判定。
//
//  OpenCode 2.x 换了表结构：消息与分片合成 `session_message`（`content` 数组内嵌
//  工具调用），会话表换成 `session_v2`，旧表从此停更。因此读取时以 v2 为准，
//  旧表只用来补齐没有被迁移的历史消息（v2 库里两者会同时存在）。
//
//  幂等性由调用方保证：每条消息在统计库里是一个独立数据源，重扫时整源重放。
//

import Foundation
import SQLite3
import os.log

/// OpenCode 的增量游标：键集分页用的 `(time_updated, id)`。
nonisolated struct OpenCodeUsageCursor: Equatable {
    var timeUpdated: Int64 = -1
    var id = ""

    static let empty = OpenCodeUsageCursor()

    /// 是否严格排在另一条之后（用于断言游标只向前走）。
    func isAfter(_ other: OpenCodeUsageCursor) -> Bool {
        if timeUpdated != other.timeUpdated { return timeUpdated > other.timeUpdated }
        return id > other.id
    }
}

nonisolated final class OpenCodeUsageReader {
    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "UsageStats")

    private var database: OpaquePointer?
    /// 库是否是 OpenCode 2.x 的表结构（`session_message` + `session_v2`）。
    private let isVersionTwo: Bool
    /// 旧表是否还在。全新的 2.x 安装可能**完全没有** 1.x 的 `message` / `part` 表，
    /// 此时任何指向旧表的 SQL 都会在 prepare 阶段失败——必须跳过，而不是让整轮
    /// 扫描抛错（否则统计页对纯 v2 用户直接不可用）。
    private let hasLegacyMessageTable: Bool
    private let hasLegacyPartTable: Bool

    init(url: URL) throws {
        // 打开方式与失败原因见 `OpenCodeDatabase`：WAL 库在没有 -shm 时纯只读连接会失败。
        let opened = try OpenCodeDatabase.openReadOnly(
            url: url, busyTimeoutMilliseconds: 2_000)
        database = opened
        isVersionTwo =
            Self.tableExists(opened, named: "session_message")
            && Self.tableExists(opened, named: "session_v2")
        hasLegacyMessageTable = Self.tableExists(opened, named: "message")
        hasLegacyPartTable = Self.tableExists(opened, named: "part")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    /// 需要（重新）索引的消息：自身有更新，或它的某个 part 有更新。
    struct DirtyPage {
        var messageIds: Set<String> = []
        /// 本页读完后两种游标的新位置（没有新行时保持原值）。
        var messageCursor = OpenCodeUsageCursor.empty
        var partCursor = OpenCodeUsageCursor.empty
        /// 该页是否被 `limit` 截断（还有更多没读完，调用方可以继续下一页）。
        var isMessagePageFull = false
        var isPartPageFull = false
    }

    /// 取一页需要重新索引的消息。
    ///
    /// 游标按 `(time_updated, id)` 做**键集分页**，而不是「取全库最大时间戳」那种阈值
    /// 游标：阈值游标只读了被 `LIMIT` 截断的前一批，却把游标推到全库最大值，中间没读
    /// 到的消息就永远丢掉了。键集分页只认「排序上确实在游标之后」的条目，同一毫秒内
    /// 写入的多条按 id 继续排，既不漏也不会反复取到同一页。
    func dirtyMessages(
        messageCursor: OpenCodeUsageCursor, partCursor: OpenCodeUsageCursor, limit: Int
    ) throws -> DirtyPage {
        var page = DirtyPage()

        // 两代表结构里的「消息」都要读：v2 新数据在 `session_message`，旧库/未迁移的
        // 历史消息在 `message`。两路各自按键集取一页，再按游标顺序合并成一页——
        // 只取合并后的前 `limit` 条并把游标推到它的末尾，未读到的留到下一页，不会丢。
        let legacyMessageRows: [(String, Int64)]
        if hasLegacyMessageTable {
            legacyMessageRows = try query(
                """
                SELECT id, time_updated FROM message
                WHERE time_updated > ? OR (time_updated = ? AND id > ?)
                ORDER BY time_updated, id LIMIT ?;
                """,
                values: [
                    .integer(messageCursor.timeUpdated), .integer(messageCursor.timeUpdated),
                    .text(messageCursor.id), .integer(Int64(limit)),
                ]
            ) { statement in
                self.text(statement, 0).map { ($0, sqlite3_column_int64(statement, 1)) }
            }.compactMap { $0 }
        } else {
            legacyMessageRows = []
        }

        let versionTwoMessageRows: [(String, Int64)]
        if isVersionTwo {
            versionTwoMessageRows = try query(
                """
                SELECT id, time_updated FROM session_message
                WHERE type = 'assistant' AND (time_updated > ? OR (time_updated = ? AND id > ?))
                ORDER BY time_updated, id LIMIT ?;
                """,
                values: [
                    .integer(messageCursor.timeUpdated), .integer(messageCursor.timeUpdated),
                    .text(messageCursor.id), .integer(Int64(limit)),
                ]
            ) { statement in
                self.text(statement, 0).map { ($0, sqlite3_column_int64(statement, 1)) }
            }.compactMap { $0 }
        } else {
            versionTwoMessageRows = []
        }

        let mergedRows = (legacyMessageRows + versionTwoMessageRows).sorted {
            ($0.1, $0.0) < ($1.1, $1.0)
        }
        let messageRows = Array(mergedRows.prefix(limit))

        for (id, _) in messageRows { page.messageIds.insert(id) }
        page.isMessagePageFull =
            mergedRows.count > limit || legacyMessageRows.count == limit
            || versionTwoMessageRows.count == limit
        page.messageCursor =
            messageRows.last.map {
                OpenCodeUsageCursor(timeUpdated: $0.1, id: $0.0)
            } ?? messageCursor

        let partRows: [(String, String, Int64)]
        if hasLegacyPartTable {
            partRows = try query(
                """
                SELECT id, message_id, time_updated FROM part
                WHERE time_updated > ? OR (time_updated = ? AND id > ?)
                ORDER BY time_updated, id LIMIT ?;
                """,
                values: [
                    .integer(partCursor.timeUpdated), .integer(partCursor.timeUpdated),
                    .text(partCursor.id), .integer(Int64(limit)),
                ]
            ) { statement in
                (
                    self.text(statement, 0) ?? "", self.text(statement, 1) ?? "",
                    sqlite3_column_int64(statement, 2)
                )
            }
        } else {
            partRows = []
        }

        for (_, messageId, _) in partRows where !messageId.isEmpty {
            page.messageIds.insert(messageId)
        }
        page.isPartPageFull = partRows.count == limit
        page.partCursor =
            partRows.last.map {
                OpenCodeUsageCursor(timeUpdated: $0.2, id: $0.0)
            } ?? partCursor

        return page
    }

    /// 子代理会话（`session.parent_id` 非空）——它们的会话不计入会话数。
    func subagentSessionIds() throws -> Set<String> {
        let table = isVersionTwo ? "session_v2" : "session"
        let ids = try query(
            "SELECT id FROM \(table) WHERE parent_id IS NOT NULL;", values: []
        ) { statement in
            self.text(statement, 0)
        }
        return Set(ids.compactMap { $0 })
    }

    /// 一条消息的用量贡献：一条 token 记录 + 每个工具调用一条计数记录。
    func contributions(
        messageId: String, subagentSessions: Set<String>, calendar: Calendar
    ) throws -> [UsageBucketDelta] {
        if isVersionTwo,
            let deltas = try versionTwoContributions(
                messageId: messageId, subagentSessions: subagentSessions, calendar: calendar)
        {
            return deltas
        }
        // 纯 v2 新装没有旧 `message` 表：没有可回落的数据。
        guard hasLegacyMessageTable else { return [] }
        guard
            let row = try query(
                "SELECT session_id, time_created, data FROM message WHERE id = ?;",
                values: [.text(messageId)],
                row: { statement in
                    (
                        session: self.text(statement, 0) ?? "",
                        created: sqlite3_column_int64(statement, 1),
                        data: self.text(statement, 2) ?? ""
                    )
                }
            ).first
        else { return [] }

        guard let json = Self.jsonObject(row.data), (json["role"] as? String) == "assistant" else {
            return []
        }

        let date = Date(timeIntervalSince1970: Double(row.created) / 1000)
        let hourKey = UsageStatsKey.hour(for: date, calendar: calendar)
        let isSubagent = subagentSessions.contains(row.session)
        // 只有 token 行带模型标识；工具调用计数行不带（工具榜不按模型拆）。
        let model = (json["modelID"] as? String) ?? ""

        var deltas: [UsageBucketDelta] = []
        if let tokens = json["tokens"] as? [String: Any] {
            var delta = UsageBucketDelta(
                hourKey: hourKey, sessionId: row.session, isSubagent: isSubagent, tool: "")
            delta.records = 1
            delta.model = model
            delta.input = Self.intValue(tokens["input"])
            delta.output = Self.intValue(tokens["output"])
            if let cache = tokens["cache"] as? [String: Any] {
                delta.cacheRead = Self.intValue(cache["read"])
                delta.cacheWrite = Self.intValue(cache["write"])
            }
            deltas.append(delta)
        }

        // 工具调用：同一轮里的多个工具各自计数一次。
        var callsByTool: [String: Int] = [:]
        for part in try partData(messageId: messageId) {
            guard let partJSON = Self.jsonObject(part), (partJSON["type"] as? String) == "tool",
                let name = partJSON["tool"] as? String, !name.isEmpty
            else { continue }
            let normalized = GenericToolResultBuilder.normalizedName(name)
            callsByTool[normalized, default: 0] += 1
        }
        for (tool, calls) in callsByTool {
            var delta = UsageBucketDelta(
                hourKey: hourKey, sessionId: row.session, isSubagent: isSubagent, tool: tool)
            delta.calls = calls
            deltas.append(delta)
        }

        return deltas
    }

    /// v2 消息的用量贡献；消息不在 v2 表里时返回 nil（调用方回落到旧表）。
    ///
    /// v2 把分片内嵌进消息：token 在 `data.tokens`、模型在 `data.model.id`、工具调用
    /// 在 `data.content` 里（`type == "tool"` 的条目的 `name`）。
    private func versionTwoContributions(
        messageId: String, subagentSessions: Set<String>, calendar: Calendar
    ) throws -> [UsageBucketDelta]? {
        guard
            let row = try query(
                "SELECT session_id, time_created, type, data FROM session_message WHERE id = ?;",
                values: [.text(messageId)],
                row: { statement in
                    (
                        session: self.text(statement, 0) ?? "",
                        created: sqlite3_column_int64(statement, 1),
                        type: self.text(statement, 2) ?? "",
                        data: self.text(statement, 3) ?? ""
                    )
                }
            ).first
        else { return nil }

        // 用户消息只占游标，不产生桶。
        guard row.type == "assistant", let json = Self.jsonObject(row.data) else { return [] }

        let date = Date(timeIntervalSince1970: Double(row.created) / 1000)
        let hourKey = UsageStatsKey.hour(for: date, calendar: calendar)
        let isSubagent = subagentSessions.contains(row.session)
        let model = ((json["model"] as? [String: Any])?["id"] as? String) ?? ""

        var deltas: [UsageBucketDelta] = []
        if let tokens = json["tokens"] as? [String: Any] {
            var delta = UsageBucketDelta(
                hourKey: hourKey, sessionId: row.session, isSubagent: isSubagent, tool: "")
            delta.records = 1
            delta.model = model
            delta.input = Self.intValue(tokens["input"])
            delta.output = Self.intValue(tokens["output"])
            if let cache = tokens["cache"] as? [String: Any] {
                delta.cacheRead = Self.intValue(cache["read"])
                delta.cacheWrite = Self.intValue(cache["write"])
            }
            deltas.append(delta)
        }

        var callsByTool: [String: Int] = [:]
        for element in json["content"] as? [[String: Any]] ?? [] {
            guard (element["type"] as? String) == "tool",
                let name = element["name"] as? String, !name.isEmpty
            else { continue }
            callsByTool[GenericToolResultBuilder.normalizedName(name), default: 0] += 1
        }
        for (tool, calls) in callsByTool {
            var delta = UsageBucketDelta(
                hourKey: hourKey, sessionId: row.session, isSubagent: isSubagent, tool: tool)
            delta.calls = calls
            deltas.append(delta)
        }

        return deltas
    }

    /// 表是否存在（用于在 v1 / v2 表结构之间选择）。
    private static func tableExists(_ database: OpaquePointer, named name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
                -1, &statement, nil) == SQLITE_OK, let statement
        else { return false }
        sqlite3_bind_text(statement, 1, name, -1, transientDestructor)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func partData(messageId: String) throws -> [String] {
        guard hasLegacyPartTable else { return [] }
        return try query("SELECT data FROM part WHERE message_id = ?;", values: [.text(messageId)])
        {
            statement in
            self.text(statement, 0)
        }.compactMap { $0 }
    }

    // MARK: - SQLite / JSON 辅助

    /// 查询失败**必须抛错**：把 `SQLITE_BUSY` / 语句错误当成「没有数据」返回空数组，
    /// 会让一整轮扫描静默地什么都不做（日志里也看不出原因）。
    private func query<T>(
        _ sql: String, values: [SQLiteValue], row: (OpaquePointer) -> T?
    ) throws -> [T] {
        guard let database else { throw OpenCodeDatabaseError.openFailed("库未打开") }
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK,
            let statement = handle
        else {
            throw OpenCodeDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, Int32(offset + 1), text, -1, Self.transientDestructor)
            case .integer(let number):
                sqlite3_bind_int64(statement, Int32(offset + 1), number)
            case .double(let number):
                sqlite3_bind_double(statement, Int32(offset + 1), number)
            case .null:
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }

        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw OpenCodeDatabaseError.stepFailed(String(cString: sqlite3_errmsg(database)))
            }
            if let value = row(statement) { results.append(value) }
        }
        return results
    }

    private static let transientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }
}
