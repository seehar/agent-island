//
//  UsageStatsStore.swift
//  AgentIsland
//
//  用量统计自己的 SQLite 库（唯一新增的可写持久化文件）。表结构只有两处：
//    · `indexed_source`：增量读取进度（每个 JSONL 文件一行、OpenCode 每个消息一行）；
//    · `usage_bucket`：按「本地小时 + 会话 + 子代理标记 + 工具名 + 模型」聚合的用量桶。
//
//  所有指标都由 `usage_bucket` 聚合得出，写入语义只有两条：
//    · `append`：只把新读到的字节 / 新处理的消息对应的增量累加进去（增量读取）；
//    · `replace` / `replaceBatch`：先删掉这些源的全部桶再重放（记录被截断 / 整体
//      重写时；OpenCode 按页回填用批版，消息与游标因此同生共死）。
//  这两条让「扫描两次 == 扫描一次」成为可测的不变量。
//
//  库头用 `PRAGMA user_version` 记住结构版本：打开库时由 `UsageStatsSchema` 决定建表 /
//  重建 / 什么都不做（判定在 `init(url:)` 里，动作是 `createSchema` 与 `dropLegacySchema`）。
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
  /// 模型标识；空串表示这条贡献不参与模型拆分（工具调用计数行一律为空）。
  var model = ""
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
    // 结构版本决定打开时做什么（见 `UsageStatsSchema`）：全新库建表、旧库重建、
    // 已是最新版什么都不做。重建会把读取进度一起清掉，下一轮从头回填历史数字。
    let storedVersion = try userVersion()
    let columns = try bucketColumns()
    switch UsageStatsSchema.migration(of: storedVersion, bucketColumns: columns) {
    case .create, .none:
      // 建表是幂等的（`CREATE … IF NOT EXISTS`）：全新库由此建起来，结构已经最新的库
      // 什么都不动（存量数字因此不会被清），版本号在下面按需补写。
      try createSchema()
    case .rebuild:
      try dropLegacySchema()
      try createSchema()
    }
    // 版本号只在真的对不上时才写：`PRAGMA user_version = n` 即使值没变也会开一个写事务，
    // 而统计库有两条连接（索引器写、页面读），读侧每次打开都白写一下是没有必要的争用。
    if storedVersion != UsageStatsSchema.current {
      try execute("PRAGMA user_version = \(UsageStatsSchema.current);")
    }
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

  /// 库里的结构版本（`PRAGMA user_version`；全新库、以及引入版本号之前建的库都是 0）。
  private func userVersion() throws -> Int {
    try query("PRAGMA user_version;", values: []) { statement in
      Int(sqlite3_column_int64(statement, 0))
    }.first ?? 0
  }

  /// `usage_bucket` 的列名；表还不存在（全新库）时返回 `nil`。
  private func bucketColumns() throws -> [String]? {
    let columns = try query("PRAGMA table_info(usage_bucket);", values: []) { statement in
      self.text(statement, 1)
    }
    return columns.isEmpty ? nil : columns
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
        model       TEXT NOT NULL DEFAULT '',
        records     INTEGER NOT NULL DEFAULT 0,
        calls       INTEGER NOT NULL DEFAULT 0,
        input       INTEGER NOT NULL DEFAULT 0,
        output      INTEGER NOT NULL DEFAULT 0,
        cache_read  INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_id, hour_key, is_subagent, session_id, tool, model)
      );
      """)
    try execute("CREATE INDEX IF NOT EXISTS usage_bucket_hour ON usage_bucket(hour_key, agent);")
    try execute("CREATE INDEX IF NOT EXISTS usage_bucket_tool ON usage_bucket(tool);")
    try execute("CREATE INDEX IF NOT EXISTS usage_bucket_model ON usage_bucket(model, hour_key);")
  }

  /// 整表重建：SQLite 改不了主键，旧结构一律 drop 重来（判定在 `UsageStatsSchema.migration`
  /// 里，这里只负责动作）。`indexed_source` 的读取进度一起清掉——进度留着的话历史记录的
  /// 新列永远补不回来，只能让下一轮从头回填（统计的唯一事实源是磁盘上的记录，重建不丢数据）。
  private func dropLegacySchema() throws {
    try execute("DROP TABLE usage_bucket;")
    try execute("DROP TABLE IF EXISTS indexed_source;")
    Self.logger.notice("用量统计库结构升级：旧表结构落后，已清空，下一轮将重新回填。")
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
    // 这里**不**按「没有 deltas」提前返回：整源重放（`replace`）时进度行必须跟着写，
    // 否则「这一遍什么都没读出来」的源会永远停在旧进度上，每轮都被再重放一次。
    let sql =
      """
      INSERT INTO usage_bucket
        (source_id, agent, session_id, hour_key, is_subagent, tool, model,
         records, calls, input, output, cache_read, cache_write)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id, hour_key, is_subagent, session_id, tool, model) DO UPDATE SET
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
      bind(statement, 7, .text(delta.model))
      bind(statement, 8, .integer(Int64(delta.records)))
      bind(statement, 9, .integer(Int64(delta.calls)))
      bind(statement, 10, .integer(Int64(delta.input)))
      bind(statement, 11, .integer(Int64(delta.output)))
      bind(statement, 12, .integer(Int64(delta.cacheRead)))
      bind(statement, 13, .integer(Int64(delta.cacheWrite)))
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

    snapshot.models =
      try query(
        """
        SELECT model, COALESCE(SUM(input), 0), COALESCE(SUM(output), 0),
               COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_write), 0),
               COALESCE(SUM(calls), 0),
               COUNT(DISTINCT CASE WHEN is_subagent = 0 THEN session_id END)
        FROM usage_bucket
        WHERE model <> '' \(filter.clause.isEmpty ? "" : "AND \(filter.clause)")
        GROUP BY model
        ORDER BY (SUM(input) + SUM(output) + SUM(cache_read) + SUM(cache_write)) DESC, model ASC;
        """, values: values
      ) { statement in
        guard let name = self.text(statement, 0) else { return nil }
        return ModelUsage(
          name: name,
          totals: UsageTotals(
            input: Int(sqlite3_column_int64(statement, 1)),
            output: Int(sqlite3_column_int64(statement, 2)),
            cacheRead: Int(sqlite3_column_int64(statement, 3)),
            cacheWrite: Int(sqlite3_column_int64(statement, 4)),
            sessions: Int(sqlite3_column_int64(statement, 6)),
            calls: Int(sqlite3_column_int64(statement, 5))
          ))
      }.compactMap { $0 }

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

/// 统计库的结构版本，以及「打开这个库时该做什么」的判定。
///
/// 版本沿革（`PRAGMA user_version`）：
///   · 0：引入版本号之前建的库（`usage_bucket` 缺 `model` 列、主键是五元组）；
///   · 1：当前版本——`usage_bucket` 带 `model` 列，主键是六元组。
///
/// **加列 / 改表时的做法**：把 `current` 加一，并在 `migration(of:bucketColumns:)` 里
/// 追加一条按 `storedVersion` 分档的分支说明怎么升（能让 `ALTER TABLE` 解决的别整表重建，
/// 重建会丢历史数字、只能靠磁盘记录回填）。
nonisolated enum UsageStatsSchema {
  /// 当前代码要求的结构版本。
  static let current = 1

  /// 打开库时要做的事。
  enum Migration: Equatable {
    /// 全新库（或表被手工删了）：按最新结构建表。
    case create
    /// 结构本来就是当前结构：不需要重建（打开时不动既有数据，只在版本号落后时补写）。
    case none
    /// 旧结构：整表重建（历史数字由磁盘记录回填，见 `UsageStatsStore.dropLegacySchema`）。
    case rebuild
  }

  /// 库里的结构版本与列名 → 打开时该做什么。纯函数，单测直接调它。
  ///
  /// 判据分两层：**列**说明结构本身对不对，**版本号**只说明这是哪一档库。
  ///
  /// - Parameters:
  ///   - storedVersion: 库里的 `PRAGMA user_version`；引入版本号之前的库是 0。
  ///   - bucketColumns: 库里 `usage_bucket` 的列名；**表不存在**时传 `nil`。
  ///   - currentVersion: 代码要求的版本（默认 `UsageStatsSchema.current`）。
  static func migration(
    of storedVersion: Int,
    bucketColumns: [String]?,
    currentVersion: Int = UsageStatsSchema.current
  ) -> Migration {
    guard let columns = bucketColumns else { return .create }

    // 版本号 0（引入版本号之前建的库）与「已经是最新版本」这两档都只按列判断：列齐全
    // 说明库本来就是当前结构（只需补上版本号，**不要**白白清掉用户的历史数字再等一轮
    // 全量回填），缺 `model` 列的才是真的旧库，只能重建。
    if storedVersion == currentVersion {
      return columns.contains("model") ? .none : .rebuild
    }
    if storedVersion == 0 {
      // 版本号 0 = 「引入版本号之前建的库」。它的结构**只可能是 v1**（`usage_bucket` 带
      // `model`），因此只有当前代码也正好是 v1 时才按列判断；以后 `current` 升到 2 时，
      // 0 号库必须先升到 2（不能因为「列里有 model」被判成已是最新，那会用 v2 的代码读到
      // 缺列的表）。列判断写死 `model` 这件事因此只在这一档里成立。
      if currentVersion != 1 { return .rebuild }
      return columns.contains("model") ? .none : .rebuild
    }

    // 版本号与代码对不上（以后新增的旧版本会落到这里）：整表重建兜底。加列时在这里
    // 追加一条「旧版本号 → 怎么升」的分支；能让 `ALTER TABLE` 解决的别走重建（重建会丢
    // 历史数字），那时再给 `Migration` 添一个档。
    return .rebuild
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
