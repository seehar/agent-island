//
//  HermesUsageScanner.swift
//  AgentIsland
//
//  Hermes 的历史不在文件里而在 SQLite（`~/.hermes/state.db`）里，因此按天统计要单独走
//  一条数据库路径（与 OpenCode 同构）。这里**只读**打开（走 `SQLiteReadOnlyConnection`，
//  与 opencode 库共用同一套「先读写、失败退只读 + `PRAGMA query_only`」的做法），按
//  「会话」为粒度取增量：
//    · token 用量的权威来源是 `session_model_usage`（每会话每模型一行）：`model` 是维度，
//      `billing_*` 列不是；该表里没有这个会话的行时才回落到 `sessions` 的合计
//      （见 `contributions(sessionId:subagentSessions:calendar:)`）；
//    · 工具调用是 `messages` 里 `tool_name` 非空的行，工具名就是这一列；
//    · 会话时间取 `max(started_at, ended_at, 该会话最后一条消息的 timestamp)`，
//      整条会话落一个桶；
//    · `delegate_task` 派生的子会话在 `sessions` 里是一行独立记录（`parent_session_id`
//      非空）：照 OpenCode 的同构口径处理——**用量计入**，但标成 `isSubagent`，因而自动
//      不计入会话数（会话数与各榜都按 `is_subagent = 0` 过滤，见 `UsageStatsStore.snapshot`
//      的 `COUNT(DISTINCT CASE WHEN is_subagent = 0 THEN session_id END)`）。扫描侧因此
//      **不过滤** `parent_session_id`。
//      取舍依据（本机 2026-09 实测）：子会话 783 条、占 144.2M 输入 token = 全库 27%，而
//      Hermes 自己的 `agent/insights.py` 完全不看 `parent_session_id`；把子会话整条排除会
//      让 Hermes 的数字只有真实值的 73%。面板的**会话列表**是另一条路径（`HermesSessionStore`
//      只列顶层会话），与本用量路径不矛盾。
//
//  幂等性由调用方保证：每条会话在统计库里是一个独立数据源，重扫时整源重放。
//

import Foundation
import SQLite3

/// Hermes 的增量游标：键集分页用的 `(updatedAt, sessionId)`。
nonisolated struct HermesUsageCursor: Equatable {
  /// 会话的最后活动时间（`max(started_at, ended_at, 最后一条消息的时间戳)`）。
  var updatedAt: Double = -1
  var sessionId = ""

  static let empty = HermesUsageCursor()

  /// 是否严格排在另一条之后（用于断言游标只向前走）。
  func isAfter(_ other: HermesUsageCursor) -> Bool {
    if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
    return sessionId > other.sessionId
  }
}

nonisolated final class HermesUsageReader {
  private var database: OpaquePointer?

  init(url: URL) throws {
    // 与 opencode 那条路径共用同一个打开方式：这些库都是 WAL，纯只读连接在没有 `-shm`
    // 时第一条语句就失败，因此要先读写打开再 `PRAGMA query_only` 钉成只读（见
    // `SQLiteReadOnlyConnection` 的说明）。
    database = try SQLiteReadOnlyConnection.open(
      url: url, busyTimeoutMilliseconds: 2_000)
  }

  deinit {
    if let database { sqlite3_close(database) }
  }

  /// 需要（重新）索引的会话。
  struct DirtyPage {
    /// 本页需要重扫的会话 id（按游标顺序，含子会话）。
    var sessionIds: [String] = []
    /// 本页读完后游标的新位置（没有新行时保持原值）。
    var cursor = HermesUsageCursor.empty
    /// 该页是否被 `limit` 截断（还有更多没读完，调用方可以继续下一页）。
    var isPageFull = false
  }

  /// 取一页需要重新索引的会话（含子会话：它们也要算用量，只是标成子代理）。
  ///
  /// 游标按 `(updatedAt, sessionId)` 做**键集分页**，而不是「取全库最大时间戳」那种阈值
  /// 游标：阈值游标只读了被 `LIMIT` 截断的前一批，却把游标推到全库最大值，中间没读到的
  /// 会话就永远丢掉了。键集分页只认「排序上确实在游标之后」的条目，同一个时间戳的多条按
  /// id 继续排，既不漏也不会反复取到同一页。
  ///
  /// `updatedAt` 与会话落进哪个时间桶用的是**同一个表达式**（会话的最后活动时间），所以
  /// 先在外层子查询里算成列，过滤与排序才能都用上它。
  func dirtySessions(cursor: HermesUsageCursor, limit: Int) throws -> DirtyPage {
    var page = DirtyPage()
    let rows = try query(
      """
      SELECT id, updated FROM (
        SELECT s.id AS id,
               max(s.started_at, COALESCE(s.ended_at, 0),
                   COALESCE((SELECT max(m.timestamp) FROM messages m WHERE m.session_id = s.id),
                            0)) AS updated
        FROM sessions s
      )
      WHERE updated > ? OR (updated = ? AND id > ?)
      ORDER BY updated, id LIMIT ?;
      """,
      values: [
        .double(cursor.updatedAt), .double(cursor.updatedAt), .text(cursor.sessionId),
        .integer(Int64(limit)),
      ]
    ) { statement in
      self.text(statement, 0).map { ($0, sqlite3_column_double(statement, 1)) }
    }.compactMap { $0 }

    page.sessionIds = rows.map { $0.0 }
    page.isPageFull = rows.count == limit
    page.cursor = rows.last.map {
      HermesUsageCursor(updatedAt: $0.1, sessionId: $0.0)
    } ?? cursor

    return page
  }

  /// 子代理会话（`parent_session_id` 非空，即 `delegate_task` 派生的那些）——它们的用量
  /// 照常计入，只是不计入会话数（与 OpenCode 的 `subagentSessionIds()` 同一口径）。
  func subagentSessionIds() throws -> Set<String> {
    let ids = try query(
      "SELECT id FROM sessions WHERE parent_session_id IS NOT NULL;", values: []
    ) { statement in
      self.text(statement, 0)
    }
    return Set(ids.compactMap { $0 })
  }

  /// 一条会话的用量贡献：每个模型一条 token 记录 + 每个工具一条计数记录。
  func contributions(
    sessionId: String, subagentSessions: Set<String>, calendar: Calendar
  ) throws -> [UsageBucketDelta] {
    guard
      let session = try query(
        """
        SELECT max(s.started_at, COALESCE(s.ended_at, 0),
                   COALESCE(
                     (SELECT max(m.timestamp) FROM messages m WHERE m.session_id = s.id), 0)),
               COALESCE(s.model, ''), s.input_tokens, s.output_tokens, s.cache_read_tokens,
               s.cache_write_tokens
        FROM sessions s WHERE s.id = ?;
        """,
        values: [.text(sessionId)],
        row: { statement in
          (
            updatedAt: sqlite3_column_double(statement, 0),
            model: self.text(statement, 1) ?? "",
            input: Int(sqlite3_column_int64(statement, 2)),
            output: Int(sqlite3_column_int64(statement, 3)),
            cacheRead: Int(sqlite3_column_int64(statement, 4)),
            cacheWrite: Int(sqlite3_column_int64(statement, 5))
          )
        }
      ).first
    else { return [] }

    let hourKey = UsageStatsKey.hour(
      for: Date(timeIntervalSince1970: session.updatedAt), calendar: calendar)
    let isSubagent = subagentSessions.contains(sessionId)
    var deltas: [UsageBucketDelta] = []

    // token：按 `model` 拆（`billing_*` 列不是维度）。同一会话同一模型可能有多行——那是
    // 不同计费口径拆出来的，先求和。
    let models = try query(
      """
      SELECT model, SUM(input_tokens), SUM(output_tokens),
             SUM(cache_read_tokens), SUM(cache_write_tokens)
      FROM session_model_usage WHERE session_id = ? GROUP BY model;
      """,
      values: [.text(sessionId)],
      row: { statement in
        (
          model: self.text(statement, 0) ?? "",
          input: Int(sqlite3_column_int64(statement, 1)),
          output: Int(sqlite3_column_int64(statement, 2)),
          cacheRead: Int(sqlite3_column_int64(statement, 3)),
          cacheWrite: Int(sqlite3_column_int64(statement, 4))
        )
      }
    )

    for tokens in models {
      var delta = UsageBucketDelta(
        hourKey: hourKey, sessionId: sessionId, isSubagent: isSubagent, tool: "")
      delta.records = 1
      delta.model = tokens.model
      delta.input = tokens.input
      delta.output = tokens.output
      delta.cacheRead = tokens.cacheRead
      delta.cacheWrite = tokens.cacheWrite
      deltas.append(delta)
    }

    // 这个会话没有按模型的记账行时回落到 `sessions` 的合计：本机 8723 条会话里有 5 条如此
    // （合计 6.1M 输入 token），丢掉它们会让总量少 1% 左右。模型维度取该会话的 `model`
    // 列，没有就留空（空模型的桶不进模型榜）。按模型的行存在时**必须**走上面那支，否则
    // 同一批 token 会被计两次。
    if models.isEmpty,
      session.input != 0 || session.output != 0 || session.cacheRead != 0
        || session.cacheWrite != 0
    {
      var delta = UsageBucketDelta(
        hourKey: hourKey, sessionId: sessionId, isSubagent: isSubagent, tool: "")
      delta.records = 1
      delta.model = session.model
      delta.input = session.input
      delta.output = session.output
      delta.cacheRead = session.cacheRead
      delta.cacheWrite = session.cacheWrite
      deltas.append(delta)
    }

    // 工具调用：`tool_name` 非空的行各计一次。
    //
    // **不限定 role**：Hermes 自己的口径是「role == 'tool' 或带 tool_calls 的消息」计入
    // `sessions.tool_call_count`（见其 `hermes_state.py`），而 `tool_name` 这一列在本机
    // 只写在 `role == 'tool'` 的行上（27,932 行，与各会话 `tool_call_count` 之和 27,875
    // 基本一致）；assistant 行的调用声明在 `tool_calls` JSON 里、没有工具名列，所以把它
    // 限定成 assistant 会一条都统计不到。子会话的调用同样计入（桶标 `isSubagent`）。
    let calls = try query(
      """
      SELECT tool_name, COUNT(*) FROM messages
      WHERE session_id = ? AND tool_name IS NOT NULL AND trim(tool_name) <> ''
      GROUP BY tool_name;
      """,
      values: [.text(sessionId)],
      row: { statement in
        (name: self.text(statement, 0) ?? "", calls: Int(sqlite3_column_int64(statement, 1)))
      }
    )

    var callsByTool: [String: Int] = [:]
    for call in calls where !call.name.isEmpty {
      callsByTool[GenericToolResultBuilder.normalizedName(call.name), default: 0] += call.calls
    }
    for (tool, toolCalls) in callsByTool {
      var delta = UsageBucketDelta(
        hourKey: hourKey, sessionId: sessionId, isSubagent: isSubagent, tool: tool)
      delta.calls = toolCalls
      deltas.append(delta)
    }

    return deltas
  }

  // MARK: - SQLite 辅助

  /// 查询失败**必须抛错**：把 `SQLITE_BUSY` / 语句错误当成「没有数据」返回空数组，
  /// 会让一整轮扫描静默地什么都不做（日志里也看不出原因）。
  private func query<T>(
    _ sql: String, values: [SQLiteValue], row: (OpaquePointer) -> T?
  ) throws -> [T] {
    guard let database else { throw HermesUsageReaderError.openFailed("库未打开") }
    var handle: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK,
      let statement = handle
    else {
      throw HermesUsageReaderError.prepareFailed(String(cString: sqlite3_errmsg(database)))
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
        throw HermesUsageReaderError.stepFailed(String(cString: sqlite3_errmsg(database)))
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
}

/// Hermes 库的读取失败原因。
///
/// 打开失败是 `SQLiteReadOnlyConnection` 抛的（共用实现自带文案）；这三个分支覆盖读取
/// 自己的三种失败，文案必须点明是 Hermes 的库——排查时把库名认错最费时间。
nonisolated enum HermesUsageReaderError: Error, CustomStringConvertible {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)

  var description: String {
    switch self {
    case .openFailed(let message): return "打开 Hermes 库失败：\(message)"
    case .prepareFailed(let message): return "Hermes 库语句准备失败：\(message)"
    case .stepFailed(let message): return "Hermes 库执行失败：\(message)"
    }
  }
}