//
//  OpenCodeUsageScanner.swift
//  AgentIsland
//
//  OpenCode 的历史不在文件里而在 SQLite（`opencode.db`）里，因此按天统计要单独
//  走一条数据库路径。这里**只读**打开（走 `OpenCodeDatabase`，与会话列表同一套），
//  按「消息」为粒度取增量：
//    · token 在 `message.data.tokens` 里（`cache.read` / `cache.write` 对应缓存读/写）；
//    · 工具调用是 `part` 表里 `type == "tool"` 的行，工具名取 `data.tool`；
//    · 时间取 `message.time_created`（毫秒 epoch），子代理会话由 `session.parent_id` 判定。
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

  init(url: URL) throws {
    // 打开方式与失败原因见 `OpenCodeDatabase`：WAL 库在没有 -shm 时纯只读连接会失败。
    database = try OpenCodeDatabase.openReadOnly(
      url: url, busyTimeoutMilliseconds: 2_000)
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

    let messageRows = try query(
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

    for (id, _) in messageRows { page.messageIds.insert(id) }
    page.isMessagePageFull = messageRows.count == limit
    page.messageCursor = messageRows.last.map {
      OpenCodeUsageCursor(timeUpdated: $0.1, id: $0.0)
    } ?? messageCursor

    let partRows = try query(
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
      (self.text(statement, 0) ?? "", self.text(statement, 1) ?? "",
       sqlite3_column_int64(statement, 2))
    }

    for (_, messageId, _) in partRows where !messageId.isEmpty {
      page.messageIds.insert(messageId)
    }
    page.isPartPageFull = partRows.count == limit
    page.partCursor = partRows.last.map {
      OpenCodeUsageCursor(timeUpdated: $0.2, id: $0.0)
    } ?? partCursor

    return page
  }

  /// 子代理会话（`session.parent_id` 非空）——它们的会话不计入会话数。
  func subagentSessionIds() throws -> Set<String> {
    let ids = try query("SELECT id FROM session WHERE parent_id IS NOT NULL;", values: []) {
      statement in
      self.text(statement, 0)
    }
    return Set(ids.compactMap { $0 })
  }

  /// 一条消息的用量贡献：一条 token 记录 + 每个工具调用一条计数记录。
  func contributions(
    messageId: String, subagentSessions: Set<String>, calendar: Calendar
  ) throws -> [UsageBucketDelta] {
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

    var deltas: [UsageBucketDelta] = []
    if let tokens = json["tokens"] as? [String: Any] {
      var delta = UsageBucketDelta(
        hourKey: hourKey, sessionId: row.session, isSubagent: isSubagent, tool: "")
      delta.records = 1
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

  private func partData(messageId: String) throws -> [String] {
    try query("SELECT data FROM part WHERE message_id = ?;", values: [.text(messageId)]) {
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
