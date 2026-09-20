//
//  OpenCodeSessionStore.swift
//  ClaudeIsland
//
//  OpenCode 的历史存在 SQLite 数据库（`~/.local/share/opencode/opencode.db`）
//  里，另有一份已冻结的旧版 JSON 目录（`storage/`）。这里提供只读访问：
//  数据库可用时走数据库，打不开或没有数据时降级到旧版 JSON。
//

import Foundation
import SQLite3
import os.log

/// OpenCode 的一条消息记录。
///
/// `user` 与 `assistant` 消息都以 `msg_...` 为 id；角色、token 用量、结束
/// 原因等都在消息 JSON 里（数据库的 `data` 列或旧版 JSON 文件内容）。
struct OpenCodeMessageRecord {
    let id: String
    /// `user` 或 `assistant`。
    let role: String
    /// 消息创建时间（毫秒 epoch）。
    let createdAt: Date
    /// 消息的原始 JSON。
    let json: [String: Any]

    /// 结束原因（`stop`/`tool-calls`/…）；生成中可能缺失。
    var finish: String? { json["finish"] as? String }

    /// token 用量（仅 assistant 消息）。
    var tokens: [String: Any]? { json["tokens"] as? [String: Any] }
}

/// OpenCode 的一条消息分片（part）记录。
struct OpenCodePartRecord {
    /// 分片 id（`prt_...`）。
    let id: String
    /// 所属消息 id。
    let messageId: String
    /// `text`/`reasoning`/`tool`/`patch`/`file`/`compaction`/`step-start`/`step-finish`。
    let type: String
    /// 排序时间（毫秒 epoch）：优先分片自身的时间戳，其次记录创建时间。
    let sortTime: Int64
    /// 分片的原始 JSON。
    let json: [String: Any]

    /// 文本内容（`text`/`reasoning` 分片）。
    var text: String? { json["text"] as? String }

    /// 工具状态字典（仅 `tool` 分片）。
    var toolState: [String: Any]? { json["state"] as? [String: Any] }
    /// 工具调用 id（仅 `tool` 分片）。
    var callId: String? { json["callID"] as? String }
    /// 工具名（仅 `tool` 分片）。
    var toolName: String? { json["tool"] as? String }
    /// 工具状态：`pending`/`running`/`completed`/`error`。
    var toolStatus: String? { toolState?["status"] as? String }
    /// 工具入参。
    var toolInput: [String: Any]? { toolState?["input"] as? [String: Any] }
    /// 工具输出（完成后才有）。
    var toolOutput: String? { toolState?["output"] as? String }
    /// 工具失败原因（`error` 状态才有；新版是字符串，旧版是对象）。
    var toolError: String? {
        guard let error = toolState?["error"] else { return nil }
        if let text = error as? String { return text }
        let object = error as? [String: Any]
        return object?["message"] as? String ?? object?["name"] as? String
    }
}

/// OpenCode 的只读会话存储。
///
/// 权威来源是 SQLite 数据库；数据库缺失或打不开时退回到已冻结的旧版 JSON
/// 目录。所有查询都用独立短连接执行：打开 → 查 → 关闭，避免长期持锁。
/// 参数一律走绑定值，SQL 文本里不出现任何外部数据。
enum OpenCodeSessionStore {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "OpenCode")

    /// 数据库拿不到锁时的等待上限；宁可返回空结果也不长时间阻塞调用方。
    private static let busyTimeoutMilliseconds: Int32 = 500

    /// 单条 SQL 里 `IN (...)` 的占位符个数上限。
    private static let parameterChunkSize = 400

    // MARK: - 位置

    /// 会话数据根目录（`~/.local/share/opencode`）。
    static var dataDirectory: URL? {
        AgentRegistry.provider(for: .opencode).paths()?.dataDir
    }

    /// 权威数据库文件；不存在时返回 nil。
    static var databaseURL: URL? {
        guard let dataDirectory else { return nil }
        let database = dataDirectory.appendingPathComponent("opencode.db")
        return FileManager.default.fileExists(atPath: database.path) ? database : nil
    }

    /// 旧版（已冻结）的 JSON 目录根。
    private static var legacyStorageURL: URL? {
        guard let dataDirectory else { return nil }
        let storage = dataDirectory.appendingPathComponent("storage")
        return FileManager.default.fileExists(atPath: storage.path) ? storage : nil
    }

    // MARK: - 会话

    /// `since` 之后有活动的顶层会话，按活动时间从新到旧排序。
    static func sessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
        guard limit > 0 else { return [] }
        let sinceMilliseconds = Self.milliseconds(of: since)
        if let sessions = databaseSessions(
            sinceMilliseconds: sinceMilliseconds, limit: limit)
        {
            return sessions
        }
        return legacySessions(sinceMilliseconds: sinceMilliseconds, limit: limit)
    }

    // MARK: - 消息

    /// `sessionId` 下 `sinceCreated` 之后创建的消息，按创建时间从旧到新排序。
    static func messages(sessionId: String, sinceCreated: Date?, limit: Int)
        -> [OpenCodeMessageRecord]
    {
        guard limit > 0 else { return [] }
        if let messages = databaseMessages(
            sessionId: sessionId, sinceCreated: sinceCreated, limit: limit)
        {
            return messages
        }
        return legacyMessages(sessionId: sessionId, sinceCreated: sinceCreated, limit: limit)
    }

    // MARK: - 分片

    /// 按消息 id 分组的分片，组内已按时间排好序。
    static func parts(messageIds: [String]) -> [String: [OpenCodePartRecord]] {
        guard !messageIds.isEmpty else { return [:] }
        if let parts = databaseParts(messageIds: messageIds) {
            return parts
        }
        return legacyParts(messageIds: messageIds)
    }

    // MARK: - 数据库查询

    /// 用独立的只读短连接执行一条语句；数据库不可用时返回 nil。
    ///
    /// `body` 返回 nil 表示本次查询失败（例如中途拿到 `SQLITE_BUSY`），
    /// 调用方据此降级到旧版 JSON。
    private static func withStatement<T>(
        _ sql: String,
        values: [SQLiteValue],
        body: (OpaquePointer) -> T?
    ) -> T? {
        guard let databaseURL else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            logger.debug("opencode 数据库打不开，降级到旧版 JSON 目录")
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            logger.debug("opencode 查询准备失败：\(String(cString: sqlite3_errmsg(database)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transientDestructor)
            }
        }
        return body(statement)
    }

    /// SQL 绑定值。目前只用到整数与文本两种。
    private enum SQLiteValue {
        case integer(Int64)
        case text(String)
    }

    /// 告诉 SQLite 复制绑定的字符串，调用返回后即可释放。
    private static let transientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    /// 读取某一列的文本值。
    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    /// 逐行执行查询；中途出错返回 nil（调用方降级）。
    private static func rows<T>(
        _ statement: OpaquePointer,
        _ row: () -> T?
    ) -> [T]? {
        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { return nil }
            guard let value = row() else { return nil }
            values.append(value)
        }
    }

    /// 表实际拥有的列名。旧版本 schema 可能没有 `data`（消息/分片写在表列里）。
    private static func columns(ofTable table: String) -> Set<String>? {
        // 表名来自本文件内的字面量，不来自外部输入。
        let names: [String]? = withStatement("PRAGMA table_info(\(table))", values: []) {
            statement in
            rows(statement) { () -> String? in
                text(statement, 1)
            }
        }
        return names.map(Set.init)
    }

    private static func databaseSessions(sinceMilliseconds: Int64, limit: Int)
        -> [DiscoveredAgentSession]?
    {
        withStatement(
            """
            SELECT id, directory, title, time_updated
            FROM session
            WHERE parent_id IS NULL AND time_updated >= ?
            ORDER BY time_updated DESC
            LIMIT ?
            """,
            values: [.integer(sinceMilliseconds), .integer(Int64(limit))]
        ) { statement in
            rows(statement) { () -> DiscoveredAgentSession? in
                guard let id = text(statement, 0) else { return nil }
                return DiscoveredAgentSession(
                    agent: .opencode,
                    sessionId: id,
                    cwd: text(statement, 1) ?? "",
                    title: text(statement, 2),
                    transcriptPath: nil,
                    updatedAt: Self.date(milliseconds: sqlite3_column_int64(statement, 3))
                )
            }
        }
    }

    private static func databaseMessages(
        sessionId: String, sinceCreated: Date?, limit: Int
    ) -> [OpenCodeMessageRecord]? {
        guard let columns = columns(ofTable: "message") else { return nil }
        // 列名取自固定的白名单字面量，缺列时用 NULL 占位。
        let jsonColumn = columns.contains("data") ? "data" : "NULL"
        let roleColumn = columns.contains("role") ? "role" : "NULL"
        let sinceMilliseconds = sinceCreated.map { Self.milliseconds(of: $0) } ?? 0

        return withStatement(
            """
            SELECT id, time_created, \(jsonColumn), \(roleColumn)
            FROM message
            WHERE session_id = ? AND time_created >= ?
            ORDER BY time_created ASC, id ASC
            LIMIT ?
            """,
            values: [.text(sessionId), .integer(sinceMilliseconds), .integer(Int64(limit))]
        ) { statement in
            rows(statement) { () -> OpenCodeMessageRecord? in
                guard let id = text(statement, 0) else { return nil }
                var json = text(statement, 2).flatMap(Self.jsonObject(from:)) ?? [:]
                // 旧版 schema 没有 `data` 列，角色在表列里。
                if json["role"] == nil, let role = text(statement, 3) {
                    json["role"] = role
                }
                return OpenCodeMessageRecord(
                    id: id,
                    role: json["role"] as? String ?? "assistant",
                    createdAt: Self.date(milliseconds: sqlite3_column_int64(statement, 1)),
                    json: json
                )
            }
        }
    }

    private static func databaseParts(messageIds: [String]) -> [String: [OpenCodePartRecord]]? {
        guard let columns = columns(ofTable: "part") else { return nil }
        let jsonColumn = columns.contains("data") ? "data" : "NULL"
        let typeColumn = columns.contains("type") ? "type" : "NULL"
        let messageColumn = columns.contains("message_id") ? "message_id" : "messageID"

        var grouped: [String: [OpenCodePartRecord]] = [:]
        var offset = 0
        while offset < messageIds.count {
            let chunk = Array(messageIds[offset..<min(offset + parameterChunkSize, messageIds.count)])
            offset += parameterChunkSize

            // 占位符个数由本文件常量决定；id 值一律走绑定参数。
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let records: [OpenCodePartRecord]? = withStatement(
                """
                SELECT id, \(messageColumn), time_created, \(jsonColumn), \(typeColumn)
                FROM part
                WHERE \(messageColumn) IN (\(placeholders))
                ORDER BY time_created ASC, id ASC
                """,
                values: chunk.map { SQLiteValue.text($0) }
            ) { statement in
                rows(statement) { () -> OpenCodePartRecord? in
                    guard let id = text(statement, 0), let messageId = text(statement, 1) else {
                        return nil
                    }
                    var json = text(statement, 3).flatMap(Self.jsonObject(from:)) ?? [:]
                    if json["type"] == nil, let type = text(statement, 4) {
                        json["type"] = type
                    }
                    return OpenCodePartRecord(
                        id: id,
                        messageId: messageId,
                        type: json["type"] as? String ?? "",
                        sortTime: Self.partSortTime(
                            json: json, fallback: sqlite3_column_int64(statement, 2)),
                        json: json
                    )
                }
            }
            guard let records else { return nil }

            for record in records {
                grouped[record.messageId, default: []].append(record)
            }
        }

        return grouped.mapValues { records in
            records.sorted { ($0.sortTime, $0.id) < ($1.sortTime, $1.id) }
        }
    }

    // MARK: - 旧版 JSON 兜底

    private static func legacySessions(sinceMilliseconds: Int64, limit: Int)
        -> [DiscoveredAgentSession]
    {
        guard let storage = legacyStorageURL else { return [] }
        let sessionRoot = storage.appendingPathComponent("session")
        let projectDirectories =
            (try? FileManager.default.contentsOfDirectory(
                at: sessionRoot, includingPropertiesForKeys: nil)) ?? []

        var sessions: [DiscoveredAgentSession] = []
        for projectDirectory in projectDirectories {
            for file in jsonFiles(in: projectDirectory) {
                guard let json = jsonObject(at: file),
                    // 子会话（委派给别的 Agent）不进入列表。
                    json["parentID"] == nil,
                    let id = json["id"] as? String,
                    let updated = milliseconds(in: json["time"], key: "updated"),
                    updated >= sinceMilliseconds
                else { continue }
                sessions.append(
                    DiscoveredAgentSession(
                        agent: .opencode,
                        sessionId: id,
                        cwd: json["directory"] as? String ?? "",
                        title: json["title"] as? String,
                        transcriptPath: nil,
                        updatedAt: date(milliseconds: updated)
                    )
                )
            }
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        return Array(sessions.prefix(limit))
    }

    private static func legacyMessages(sessionId: String, sinceCreated: Date?, limit: Int)
        -> [OpenCodeMessageRecord]
    {
        guard let storage = legacyStorageURL else { return [] }
        let directory = storage.appendingPathComponent("message").appendingPathComponent(sessionId)
        let sinceMilliseconds = sinceCreated.map { milliseconds(of: $0) } ?? 0

        var records: [OpenCodeMessageRecord] = []
        for file in jsonFiles(in: directory) {
            guard let json = jsonObject(at: file),
                let id = json["id"] as? String,
                let created = milliseconds(in: json["time"], key: "created"),
                created >= sinceMilliseconds
            else { continue }
            records.append(
                OpenCodeMessageRecord(
                    id: id,
                    role: json["role"] as? String ?? "assistant",
                    createdAt: date(milliseconds: created),
                    json: json
                )
            )
        }
        records.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return Array(records.prefix(limit))
    }

    private static func legacyParts(messageIds: [String]) -> [String: [OpenCodePartRecord]] {
        guard let storage = legacyStorageURL else { return [:] }
        var grouped: [String: [OpenCodePartRecord]] = [:]
        for messageId in messageIds {
            let directory = storage.appendingPathComponent("part").appendingPathComponent(messageId)
            var records: [OpenCodePartRecord] = []
            for file in jsonFiles(in: directory) {
                guard let json = jsonObject(at: file), let id = json["id"] as? String else {
                    continue
                }
                // 旧版分片没有自身时间戳时，用文件修改时间代替（写入顺序即创建顺序）。
                let fallback = TranscriptFileReader.modificationDate(of: file)
                    .map { milliseconds(of: $0) } ?? 0
                records.append(
                    OpenCodePartRecord(
                        id: id,
                        messageId: messageId,
                        type: json["type"] as? String ?? "",
                        sortTime: partSortTime(json: json, fallback: fallback),
                        json: json
                    )
                )
            }
            if !records.isEmpty {
                grouped[messageId] = records.sorted {
                    ($0.sortTime, $0.id) < ($1.sortTime, $1.id)
                }
            }
        }
        return grouped
    }

    // MARK: - 解析辅助

    /// 分片的排序时间：优先分片自身的时间戳，其次工具执行开始时间，最后记录时间。
    private static func partSortTime(json: [String: Any], fallback: Int64) -> Int64 {
        if let start = milliseconds(in: json["time"], key: "start") { return start }
        if let state = json["state"] as? [String: Any],
            let start = milliseconds(in: state["time"], key: "start")
        {
            return start
        }
        return fallback
    }

    /// 从 `{"created":…,"updated":…,"start":…}` 这类时间字典里取毫秒值。
    private static func milliseconds(in time: Any?, key: String) -> Int64? {
        ((time as? [String: Any])?[key] as? NSNumber)?.int64Value
    }

    private static func milliseconds(of date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// 列出目录下的全部 `.json` 文件；目录不存在时返回空。
    private static func jsonFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private nonisolated static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 从 OpenCode 自己的数据库/旧版目录枚举会话的发现来源。
struct OpenCodeSessionDiscovery: AgentSessionDiscoverySource {
    var kind: AgentKind { .opencode }

    func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
        OpenCodeSessionStore.sessions(since: since, limit: limit)
    }
}