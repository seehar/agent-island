//
//  HermesSessionStore.swift
//  AgentIsland
//
//  Hermes（Nous Research）把会话记录在它自己的 SQLite 库（`~/.hermes/state.db`）里：
//  `sessions` 表是会话索引（`id` / `cwd` / `title` / `started_at` / `ended_at` /
//  `parent_session_id` / `archived`），`messages` 表是正文（自增主键 `id` 天然就是
//  增量游标）。这里提供只读访问：打开 → 查 → 关闭，每条查询一个短连接。
//

import Foundation
import SQLite3
import os.log

/// Hermes 的一条消息记录。
nonisolated struct HermesMessageRecord {
    /// 行 id（自增主键）：既是排序键，也是增量游标（`id > 游标` 即新消息）。
    let id: Int64
    /// `user` / `assistant` / `tool` / `system`（本机实测还有 `session_meta`）。
    let role: String
    /// 正文；NULL 与空串都当作没有正文（只有工具调用的助手消息写成空串）。
    let text: String?
    /// 助手消息里的工具调用（OpenAI 风格）；解析不出就是空数组。
    let toolCalls: [(id: String, name: String, arguments: String)]
    /// 工具结果消息对应的调用 id。
    let toolCallId: String?
    /// 工具名：工具结果消息带在表列里，助手消息带在 `toolCalls` 里。
    let toolName: String?
    /// 消息时间（REAL 的 unix 秒）。
    let timestamp: Date
    /// 该行携带的 token 数；本机 6.4 万行实测恒为 NULL（会话级用量在 `sessions` 的列里）。
    let tokenCount: Int?
    /// `stop` / `tool_calls` / `length`……生成中可能为空。
    let finishReason: String?
    /// 思考过程：`reasoning` 优先，其次 `reasoning_content`（两个列都有人写）。
    let reasoning: String?
}

/// Hermes 的只读会话存储。
///
/// 所有查询都用独立短连接执行：打开 → 查 → 关闭，避免长期持锁；参数一律走绑定值，
/// SQL 文本里不出现任何外部数据。查询失败返回 nil，由调用方降级为「没有会话」——
/// 库打不开、语句准备失败、中途拿到 `SQLITE_BUSY` 都算。短连接与取值辅助在
/// `SQLiteQueryRunner`（与 OpenCode 共用）。
nonisolated enum HermesSessionStore {
    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Hermes")

    /// 短连接的日志口径（短连接与取值走与 OpenCode 共用的 `SQLiteQueryRunner`）。
    private static let queryLog = SQLiteQueryRunner.Log(
        logger: logger, label: "hermes", unavailableNotice: "本轮的会话与记录读取被跳过")

    // MARK: - 位置

    /// 权威库位置：由 Provider 决定（`$HERMES_HOME` → 用户指定目录 → `~/.hermes` 下的
    /// `state.db`）；库文件不存在时返回 nil。
    ///
    /// `override` 是调用方显式指定的库（用例的确定性夹具走它，**不必动任何全局偏好或
    /// 环境变量**，理由见 `HermesProviderTests` 的说明），生产路径传 nil。
    private static func resolvedDatabaseURL(_ override: URL?) -> URL? {
        override ?? (AgentRegistry.provider(for: .hermes) as? HermesAgentProvider)?.databaseFile
    }

    // MARK: - 会话

    /// `since` 之后有活动的顶层会话，按活动时间从新到旧排序。
    ///
    /// 活动时间取**三者最大**：开始时间、结束时间、最后一条消息时间——进行中的会话
    /// `ended_at` 为空，只有最后一条消息能说明它还在动。SQLite 的多参 `max()` 是标量
    /// 函数，因此这个表达式既能当过滤条件也能排序；`messages` 上的
    /// `idx_messages_session(session_id, timestamp)` 支撑那个相关子查询。
    ///
    /// 子会话（`parent_session_id` 非空）与已归档的会话不进入列表：前者是子 Agent 的
    /// 派生记录，后者是用户明确收起来的。
    static func sessions(since: Date, limit: Int, databaseURL: URL? = nil)
        -> [DiscoveredAgentSession]
    {
        guard limit > 0 else { return [] }
        return databaseSessions(since: since, limit: limit, databaseURL: databaseURL) ?? []
    }

    // MARK: - 消息

    /// `sessionId` 下 `sinceRowId` 之后的消息，按行 id 从旧到新排序（行 id 即游标）。
    static func messages(
        sessionId: String, sinceRowId: Int64, limit: Int, databaseURL: URL? = nil
    ) -> [HermesMessageRecord] {
        guard limit > 0 else { return [] }
        return databaseMessages(
            sessionId: sessionId, sinceRowId: sinceRowId, limit: limit, databaseURL: databaseURL
        ) ?? []
    }

    // MARK: - 查询

    private static func databaseSessions(since: Date, limit: Int, databaseURL: URL?)
        -> [DiscoveredAgentSession]?
    {
        SQLiteQueryRunner.withStatement(
            """
            SELECT id, cwd, title,
                   max(started_at, coalesce(ended_at, 0),
                       coalesce((SELECT max(timestamp) FROM messages m WHERE m.session_id = s.id), 0)) AS activity
            FROM sessions s
            WHERE parent_session_id IS NULL
              AND coalesce(archived, 0) = 0
              AND max(started_at, coalesce(ended_at, 0),
                      coalesce((SELECT max(timestamp) FROM messages m WHERE m.session_id = s.id), 0)) >= ?
            ORDER BY activity DESC
            LIMIT ?
            """,
            values: [.double(since.timeIntervalSince1970), .integer(Int64(limit))],
            databaseURL: resolvedDatabaseURL(databaseURL),
            log: queryLog
        ) { statement in
            SQLiteQueryRunner.rows(statement) { () -> DiscoveredAgentSession? in
                guard let id = SQLiteQueryRunner.nonEmptyText(statement, 0) else { return nil }
                return DiscoveredAgentSession(
                    agent: .hermes,
                    sessionId: id,
                    cwd: SQLiteQueryRunner.nonEmptyText(statement, 1) ?? "",
                    title: SQLiteQueryRunner.nonEmptyText(statement, 2),
                    transcriptPath: nil,
                    updatedAt: Date(
                        timeIntervalSince1970: SQLiteQueryRunner.double(statement, 3))
                )
            }
        }
    }

    private static func databaseMessages(
        sessionId: String, sinceRowId: Int64, limit: Int, databaseURL: URL?
    ) -> [HermesMessageRecord]? {
        SQLiteQueryRunner.withStatement(
            """
            SELECT id, role, content, tool_call_id, tool_calls, tool_name, timestamp,
                   token_count, finish_reason, reasoning, reasoning_content
            FROM messages
            WHERE session_id = ? AND id > ?
            ORDER BY id
            LIMIT ?
            """,
            values: [.text(sessionId), .integer(sinceRowId), .integer(Int64(limit))],
            databaseURL: resolvedDatabaseURL(databaseURL),
            log: queryLog
        ) { statement in
            SQLiteQueryRunner.rows(statement) { () -> HermesMessageRecord? in
                guard let role = SQLiteQueryRunner.nonEmptyText(statement, 1) else { return nil }
                return HermesMessageRecord(
                    id: SQLiteQueryRunner.integer(statement, 0),
                    role: role,
                    text: SQLiteQueryRunner.nonEmptyText(statement, 2),
                    toolCalls: toolCalls(from: SQLiteQueryRunner.nonEmptyText(statement, 4)),
                    toolCallId: SQLiteQueryRunner.nonEmptyText(statement, 3),
                    toolName: SQLiteQueryRunner.nonEmptyText(statement, 5),
                    timestamp: Date(
                        timeIntervalSince1970: SQLiteQueryRunner.double(statement, 6)),
                    tokenCount: sqlite3_column_type(statement, 7) == SQLITE_NULL
                        ? nil : Int(SQLiteQueryRunner.integer(statement, 7)),
                    finishReason: SQLiteQueryRunner.nonEmptyText(statement, 8),
                    reasoning: SQLiteQueryRunner.nonEmptyText(statement, 9)
                        ?? SQLiteQueryRunner.nonEmptyText(statement, 10)
                )
            }
        }
    }

    /// 解析 `tool_calls` 列的 JSON 数组（OpenAI 风格
    /// `[{"id":…,"function":{"name":…,"arguments":…}}]`）；形状不对就返回空数组
    /// （宁可少画一个工具气泡，也不要凭空猜一个工具名）。
    private static func toolCalls(from json: String?)
        -> [(id: String, name: String, arguments: String)]
    {
        guard let json, let data = json.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let id = (entry["id"] as? String) ?? (entry["call_id"] as? String),
                let function = entry["function"] as? [String: Any],
                let name = function["name"] as? String
            else { return nil }
            return (id: id, name: name, arguments: function["arguments"] as? String ?? "")
        }
    }
}

/// 从 Hermes 自己的 SQLite 库枚举会话的发现来源。
nonisolated struct HermesSessionDiscovery: AgentSessionDiscoverySource {
    var kind: AgentKind { .hermes }

    func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
        HermesSessionStore.sessions(since: since, limit: limit)
    }
}
