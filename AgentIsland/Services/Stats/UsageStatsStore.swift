//
//  UsageStatsStore.swift
//  AgentIsland
//
//  用量统计自己的 SQLite 库（唯一新增的可写持久化文件）。表结构只有两处：
//    · `indexed_source`：增量读取进度（每个 JSONL 文件一行、OpenCode 每个消息一行）；
//    · `usage_bucket`：按「本地小时 + 会话 + 子代理标记 + 工具名」聚合的用量桶。
//
//  所有指标都由 `usage_bucket` 聚合得出，写入语义只有两条：
//    · `append`：只把新读到的字节 / 新处理的消息对应的增量累加进去（增量读取）；
//    · `replace` / `replaceBatch`：先删掉这些源的全部桶再重放（记录被截断 / 整体
//      重写时；OpenCode 按页回填用批版，消息与游标因此同生共死）。
//  这两条让「扫描两次 == 扫描一次」成为可测的不变量。
//
//  本类型不是线程安全的：只在 `UsageStatsIndexer` actor 内部使用。
//

import Foundation
import SQLite3
import os.log

/// 一条用量贡献：某个小时桶里某个工具（或纯 token 记录）的增量。
nonisolated struct UsageBucketDelta: Equatable {
  var hourKey: String
  var sessionId: String
  var isSubagent = false
  /// 工具名（已归一化）；空串表示这条贡献只带 token、不含工具调用。
  var tool = ""
  var records = 0
  var calls = 0
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0

  /// 合并同一桶内的两条贡献（同一份记录内的多段工具调用会走这里）。
  mutating func merge(_ other: UsageBucketDelta) {
    records += other.records
    calls += other.calls
    input += other.input
    output += other.output
    cacheRead += other.cacheRead
    cacheWrite += other.cacheWrite
  }
}

/// trend 查询的一行：某个时间桶上的四路 token 与调用次数。
private nonisolated struct TrendRow {
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0
  var calls = 0
}

/// 某个数据源的读取进度。
nonisolated struct UsageSourceState: Equatable {
  var sizeBytes: UInt64 = 0
  /// 已经消费的字节数（只到最后一个换行符）。
  var readOffset: UInt64 = 0
  var mtime: Double = 0
  /// 结构化数据源（OpenCode）用的进度标记。
  var cursor: String?
  var updatedAt: Double = 0
}

/// 数据源在库里的行。
nonisolated struct UsageSourceRecord: Equatable {
  var agent: AgentKind
  var state: UsageSourceState
}

/// 一次「整源重放」要写的内容（`replaceBatch` 用）。
nonisolated struct UsageSourceWrite {
  var sourceId: String
  var agent: AgentKind
  var deltas: [UsageBucketDelta] = []
  var state: UsageSourceState
}

/// 统计库。
nonisolated final class UsageStatsStore {
  private static let logger = Logger(
    subsystem: "com.celestial.AgentIsland", category: "UsageStats")

  private var database: OpaquePointer?

  // MARK: - 打开与建表

  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知原因"
      if let handle { sqlite3_close(handle) }
      throw UsageStatsStoreError.openFailed(message)
    }
    database = handle
    sqlite3_busy_timeout(handle, 2_000)
    // WAL + NORMAL：写入随时可能被应用退出打断，这两项让「半途退出」不损坏库。
    try execute("PRAGMA journal_mode = WAL;")
    try execute("PRAGMA synchronous = NORMAL;")
    try createSchema()
  }

  deinit {
    if let database { sqlite3_close(database) }
  }

  /// 应用自己的统计库位置（`~/Library/Application Support/AgentIsland/usage.sqlite`）。
  static var defaultDatabaseURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("AgentIsland/usage.sqlite")
  }

  private func createSchema() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS indexed_source (
        source_id   TEXT PRIMARY KEY,
        agent       TEXT NOT NULL,
        size_bytes  INTEGER NOT NULL DEFAULT 0,
        read_offset INTEGER NOT NULL DEFAULT 0,
        mtime       REAL NOT NULL DEFAULT 0,
        cursor      TEXT,
        updated_at  REAL NOT NULL
      );
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS usage_bucket (
        source_id   TEXT NOT NULL,
        agent       TEXT NOT NULL,
        session_id  TEXT NOT NULL,
        hour_key    TEXT NOT NULL,
        is_subagent INTEGER NOT NULL DEFAULT 0,
        tool        TEXT NOT NULL DEFAULT '',
        records     INTEGER NOT NULL DEFAULT 0,
        calls       INTEGER NOT NULL DEFAULT 0,
        input       INTEGER NOT NULL DEFAULT 0,
        output      INTEGER NOT NULL DEFAULT 0,
        cache_read  INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_id, hour_key, is_subagent, session_id, tool)
      );
      """)
    try execute("CREATE INDEX IF NOT EXISTS usage_bucket_hour ON usage_bucket(hour_key, agent);")
    try execute("CREATE INDEX IF NOT EXISTS usage_bucket_tool ON usage_bucket(tool);")
  }

  // MARK: - 进度

  func state(ofSource sourceId: String) throws -> UsageSourceRecord? {
    try query(
      """
      SELECT agent, size_bytes, read_offset, mtime, cursor, updated_at
      FROM indexed_source WHERE source_id = ?;
      """,
      values: [.text(sourceId)]
    ) { statement in
      guard let agentRaw = self.text(statement, 0), let agent = AgentKind(rawValue: agentRaw) else {
        return nil
      }
      return UsageSourceRecord(
        agent: agent,
        state: UsageSourceState(
          sizeBytes: UInt64(max(0, sqlite3_column_int64(statement, 1))),
          readOffset: UInt64(max(0, sqlite3_column_int64(statement, 2))),
          mtime: sqlite3_column_double(statement, 3),
          cursor: self.text(statement, 4),
          updatedAt: sqlite3_column_double(statement, 5)
        ))
    }.first
  }

  /// 全部源的读取进度（一轮扫描开始时读一次）。
  ///
  /// 逐个源查一次是本机 3 万个源 × 10 µs ≈ 0.3 秒/轮；一次读完只要 20 毫秒上下——
  /// 一轮里只有本进程在写统计库，因此这份快照就是那一轮的事实。
  func sourceRecords() throws -> [String: UsageSourceRecord] {
    let rows = try query(
      """
      SELECT source_id, agent, size_bytes, read_offset, mtime, cursor, updated_at
      FROM indexed_source;
      """,
      values: []
    ) { statement -> (String, UsageSourceRecord)? in
      guard let sourceId = self.text(statement, 0),
        let agentRaw = self.text(statement, 1),
        let agent = AgentKind(rawValue: agentRaw)
      else { return nil }
      return (
        sourceId,
        UsageSourceRecord(
          agent: agent,
          state: UsageSourceState(
            sizeBytes: UInt64(max(0, sqlite3_column_int64(statement, 2))),
            readOffset: UInt64(max(0, sqlite3_column_int64(statement, 3))),
            mtime: sqlite3_column_double(statement, 4),
            cursor: self.text(statement, 5),
            updatedAt: sqlite3_column_double(statement, 6)
          )
        )
      )
    }
    return Dictionary(rows, uniquingKeysWith: { _, latest in latest })
  }

  func indexedSourceCount() throws -> Int {
    try query("SELECT COUNT(*) FROM indexed_source;", values: []) { statement in
      Int(sqlite3_column_int64(statement, 0))
    }.first ?? 0
  }

  // MARK: - 写入

  /// 增量写入：把 `deltas` 累加进已有桶，并推进读取进度。
  func append(
    _ deltas: [UsageBucketDelta], sourceId: String, agent: AgentKind, state: UsageSourceState
  ) throws {
    try transaction {
      try upsert(deltas, sourceId: sourceId, agent: agent)
      try writeSource(sourceId: sourceId, agent: agent, state: state)
    }
  }

  /// 整源重放：先清掉这个源的全部桶，再写入 `deltas`。
  func replace(
    _ deltas: [UsageBucketDelta], sourceId: String, agent: AgentKind, state: UsageSourceState
  ) throws {
    try replaceBatch([
      UsageSourceWrite(sourceId: sourceId, agent: agent, deltas: deltas, state: state)
    ])
  }

  /// 一批源一起整源重放（同一个事务）。
  ///
  /// OpenCode 的按页回填用它：一页 4000 条消息逐条开事务太碎（实测 0.14 ms/条，整页
  /// 一次事务快一个量级），而且「消息重放」与「游标推进」因此落在同一个事务里——写到
  /// 一半崩掉不会留下「游标已过、消息没入库」的洞。
  func replaceBatch(_ writes: [UsageSourceWrite]) throws {
    guard !writes.isEmpty else { return }
    try transaction {
      for write in writes {
        try execute(
          "DELETE FROM usage_bucket WHERE source_id = ?;", values: [.text(write.sourceId)])
        try upsert(write.deltas, sourceId: write.sourceId, agent: write.agent)
        try writeSource(sourceId: write.sourceId, agent: write.agent, state: write.state)
      }
    }
  }

  /// 记录文件已经不存在：只清进度，**保留**历史桶（统计是历史事实）。
  func forgetCursor(sourceId: String) throws {
    try execute("DELETE FROM indexed_source WHERE source_id = ?;", values: [.text(sourceId)])
  }

  private func upsert(_ deltas: [UsageBucketDelta], sourceId: String, agent: AgentKind) throws {
    guard !deltas.isEmpty else { return }
    let sql =
      """
      INSERT INTO usage_bucket
        (source_id, agent, session_id, hour_key, is_subagent, tool,
         records, calls, input, output, cache_read, cache_write)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id, hour_key, is_subagent, session_id, tool) DO UPDATE SET
        records = records + excluded.records,
        calls = calls + excluded.calls,
        input = input + excluded.input,
        output = output + excluded.output,
        cache_read = cache_read + excluded.cache_read,
        cache_write = cache_write + excluded.cache_write;
      """
    var handle: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK,
      let statement = handle
    else {
      throw UsageStatsStoreError.prepareFailed(errorMessage)
    }
    defer { sqlite3_finalize(statement) }

    for delta in deltas {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bind(statement, 1, .text(sourceId))
      bind(statement, 2, .text(agent.rawValue))
      bind(statement, 3, .text(delta.sessionId))
      bind(statement, 4, .text(delta.hourKey))
      bind(statement, 5, .integer(delta.isSubagent ? 1 : 0))
      bind(statement, 6, .text(delta.tool))
      bind(statement, 7, .integer(Int64(delta.records)))
      bind(statement, 8, .integer(Int64(delta.calls)))
      bind(statement, 9, .integer(Int64(delta.input)))
      bind(statement, 10, .integer(Int64(delta.output)))
      bind(statement, 11, .integer(Int64(delta.cacheRead)))
      bind(statement, 12, .integer(Int64(delta.cacheWrite)))
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw UsageStatsStoreError.stepFailed(errorMessage)
      }
    }
  }

  private func writeSource(sourceId: String, agent: AgentKind, state: UsageSourceState) throws {
    let sql =
      """
      INSERT INTO indexed_source
        (source_id, agent, size_bytes, read_offset, mtime, cursor, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id) DO UPDATE SET
        agent = excluded.agent,
        size_bytes = excluded.size_bytes,
        read_offset = excluded.read_offset,
        mtime = excluded.mtime,
        cursor = excluded.cursor,
        updated_at = excluded.updated_at;
      """
    try execute(
      sql,
      values: [
        .text(sourceId), .text(agent.rawValue), .integer(Int64(state.sizeBytes)),
        .integer(Int64(state.readOffset)), .double(state.mtime),
        state.cursor.map { SQLiteValue.text($0) } ?? .null,
        .double(state.updatedAt > 0 ? state.updatedAt : Date().timeIntervalSince1970),
      ])
  }

  // MARK: - 查询

  /// 取某个窗口的快照。`isIndexing` 由索引器给出（库本身不知道索引状态）。
  /// `isIndexing` 与 `indexedAt` 都由索引器给出：库本身不知道「上一轮扫描什么时候跑完」，
  /// 而用 `MAX(updated_at)` 代替会显示成「最后一次有记录发生变化的时间」——没有新记录时
  /// 这个时间会一直冻结在几小时前，看起来像索引停了。
  func snapshot(
    window: StatsWindow, calendar: Calendar, now: Date, isIndexing: Bool, indexedAt: Date? = nil
  ) throws -> UsageStatsSnapshot {
    var snapshot = UsageStatsSnapshot(window: window)
    snapshot.isIndexing = isIndexing
    snapshot.indexedAt = indexedAt

    let filter = windowFilter(window, now: now, calendar: calendar)
    let values = filter.values
    let windowClause = filter.clause.isEmpty ? "" : "WHERE \(filter.clause)"

    snapshot.totals =
      try query(
        """
        SELECT COALESCE(SUM(input), 0), COALESCE(SUM(output), 0),
               COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_write), 0),
               COALESCE(SUM(calls), 0),
               COUNT(DISTINCT CASE WHEN is_subagent = 0 THEN session_id END)
        FROM usage_bucket \(windowClause);
        """, values: values
      ) { statement in
        UsageTotals(
          input: Int(sqlite3_column_int64(statement, 0)),
          output: Int(sqlite3_column_int64(statement, 1)),
          cacheRead: Int(sqlite3_column_int64(statement, 2)),
          cacheWrite: Int(sqlite3_column_int64(statement, 3)),
          sessions: Int(sqlite3_column_int64(statement, 5)),
          calls: Int(sqlite3_column_int64(statement, 4))
        )
      }.first ?? UsageTotals()

    snapshot.agents =
      try query(
        """
        SELECT agent, COALESCE(SUM(input), 0), COALESCE(SUM(output), 0),
               COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_write), 0),
               COALESCE(SUM(calls), 0),
               COUNT(DISTINCT CASE WHEN is_subagent = 0 THEN session_id END)
        FROM usage_bucket \(windowClause)
        GROUP BY agent;
        """, values: values
      ) { statement in
        guard let raw = self.text(statement, 0), let agent = AgentKind(rawValue: raw) else {
          return nil
        }
        return AgentUsage(
          agent: agent,
          totals: UsageTotals(
            input: Int(sqlite3_column_int64(statement, 1)),
            output: Int(sqlite3_column_int64(statement, 2)),
            cacheRead: Int(sqlite3_column_int64(statement, 3)),
            cacheWrite: Int(sqlite3_column_int64(statement, 4)),
            sessions: Int(sqlite3_column_int64(statement, 6)),
            calls: Int(sqlite3_column_int64(statement, 5))
          ))
      }
      .compactMap { $0 }
      .sorted { $0.totals.total > $1.totals.total }

    snapshot.tools =
      try query(
        """
        SELECT tool, COALESCE(SUM(calls), 0) FROM usage_bucket
        WHERE tool <> '' \(filter.clause.isEmpty ? "" : "AND \(filter.clause)")
        GROUP BY tool ORDER BY 2 DESC;
        """, values: values
      ) { statement in
        guard let name = self.text(statement, 0) else { return nil }
        return ToolUsage(name: name, calls: Int(sqlite3_column_int64(statement, 1)))
      }.compactMap { $0 }

    snapshot.trend = try trend(window: window, filter: filter, calendar: calendar, now: now)
    return snapshot
  }

  /// 趋势桶：粒度与首尾桶都取自 `StatsWindow.trendPlan`（与视图的横轴、桶数同源），
  /// **补齐空桶**，视图直接画。四路 token 各自返回一列：曲线按需选路，口径与总览卡同一份。
  private func trend(
    window: StatsWindow, filter: (clause: String, values: [SQLiteValue]), calendar: Calendar,
    now: Date
  ) throws -> [TrendPoint] {
    let plan = window.trendPlan(now: now, calendar: calendar)
    let grouping = plan.granularity == .hour ? "hour_key" : "substr(hour_key, 1, 10)"
    let rows = try query(
      """
      SELECT \(grouping) AS bucket,
             COALESCE(SUM(input), 0), COALESCE(SUM(output), 0),
             COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_write), 0),
             COALESCE(SUM(calls), 0)
      FROM usage_bucket
      \(filter.clause.isEmpty ? "" : "WHERE \(filter.clause)")
      GROUP BY bucket ORDER BY bucket;
      """,
      values: filter.values
    ) { statement in
      (
        self.text(statement, 0) ?? "",
        TrendRow(
          input: Int(sqlite3_column_int64(statement, 1)),
          output: Int(sqlite3_column_int64(statement, 2)),
          cacheRead: Int(sqlite3_column_int64(statement, 3)),
          cacheWrite: Int(sqlite3_column_int64(statement, 4)),
          calls: Int(sqlite3_column_int64(statement, 5)))
      )
    }
    let byKey = Dictionary(rows, uniquingKeysWith: { first, _ in first })

    return plan.bucketStarts(calendar: calendar).map { start in
      let key = UsageStatsKey.bucket(for: start, granularity: plan.granularity, calendar: calendar)
      let row = byKey[key] ?? TrendRow()
      return TrendPoint(
        start: start, input: row.input, output: row.output, cacheRead: row.cacheRead,
        cacheWrite: row.cacheWrite, calls: row.calls)
    }
  }

  /// 窗口的时间过滤（左闭右开）：`hour_key` 是零填充的 `yyyy-MM-dd'T'HH` 键，字符串
  /// 比较即时间比较。空片段表示不限时间（`StatsRange.all`）。
  private func windowFilter(_ window: StatsWindow, now: Date, calendar: Calendar) -> (
    clause: String, values: [SQLiteValue]
  ) {
    let bounds = window.keyBounds(now: now, calendar: calendar)
    var parts: [String] = []
    var values: [SQLiteValue] = []
    if let start = bounds.start {
      parts.append("hour_key >= ?")
      values.append(.text(start))
    }
    if let end = bounds.end {
      parts.append("hour_key < ?")
      values.append(.text(end))
    }
    return (parts.joined(separator: " AND "), values)
  }

  // MARK: - SQLite 辅助

  private var errorMessage: String {
    guard let database else { return "数据库未打开" }
    return String(cString: sqlite3_errmsg(database))
  }

  private func execute(_ sql: String, values: [SQLiteValue] = []) throws {
    var handle: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK,
      let statement = handle
    else {
      throw UsageStatsStoreError.prepareFailed(errorMessage)
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      bind(statement, Int32(offset + 1), value)
    }
    // PRAGMA 会返回结果行，因此这里一直 step 到 DONE 为止。
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw UsageStatsStoreError.stepFailed(errorMessage) }
    }
  }

  private func query<T>(
    _ sql: String, values: [SQLiteValue], row: (OpaquePointer) -> T?
  ) throws -> [T] {
    var handle: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK,
      let statement = handle
    else {
      throw UsageStatsStoreError.prepareFailed(errorMessage)
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      bind(statement, Int32(offset + 1), value)
    }

    var results: [T] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw UsageStatsStoreError.stepFailed(errorMessage) }
      if let value = row(statement) { results.append(value) }
    }
    return results
  }

  private func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      try body()
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: SQLiteValue) {
    switch value {
    case .text(let text):
      sqlite3_bind_text(statement, index, text, -1, Self.transientDestructor)
    case .integer(let number):
      sqlite3_bind_int64(statement, index, number)
    case .double(let number):
      sqlite3_bind_double(statement, index, number)
    case .null:
      sqlite3_bind_null(statement, index)
    }
  }

  private static let transientDestructor = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)

  private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
  }
}

/// 绑定值。
nonisolated enum SQLiteValue {
  case text(String)
  case integer(Int64)
  case double(Double)
  case null
}

/// 统计库的失败原因。
nonisolated enum UsageStatsStoreError: Error, CustomStringConvertible {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)

  var description: String {
    switch self {
    case .openFailed(let message): return "打开统计库失败：\(message)"
    case .prepareFailed(let message): return "统计库语句准备失败：\(message)"
    case .stepFailed(let message): return "统计库执行失败：\(message)"
    }
  }
}
