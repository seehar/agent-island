//
//  HermesUsageStatsTests.swift
//  AgentIslandTests
//
//  Hermes 的历史在 SQLite 里（`~/.hermes/state.db`），按「会话」增量、游标分页。这里用一个
//  最小的假库（sessions / messages / session_model_usage 三张表）钉住几条容易写错的性质：
//    · 游标必须按 `(updatedAt, sessionId)` 键集分页——只认已处理过的位置，同一时间戳的多条
//      按 id 继续排，不能被跳过；
//    · 每条会话在统计库里是独立数据源、重扫整源重放，所以重复扫描不会重复计数；
//    · 子会话（`parent_session_id` 非空）的用量照算，但标成 `is_subagent`、不计入会话数；
//    · token 取 `session_model_usage` 的按模型行，没有这些行时才回落到 `sessions` 的合计。
//

import Foundation
import SQLite3
import Testing

@testable import AgentIsland

@Suite("Hermes 用量索引")
struct HermesUsageStatsTests {
  // MARK: - 假库

  /// 建一个最小可用的 hermes 库（只包含统计用到的表与列）。
  private func makeDatabase(in root: URL) throws -> URL {
    let url = root.appendingPathComponent("state.db")
    try exec(
      """
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY, parent_session_id TEXT, model TEXT,
        started_at REAL NOT NULL, ended_at REAL,
        input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
        cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0);
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL,
        tool_name TEXT, timestamp REAL NOT NULL);
      CREATE TABLE session_model_usage (
        session_id TEXT NOT NULL, model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0);
      """, at: url)
    return url
  }

  private func exec(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK, let database
    else { throw UsageStatsStoreError.openFailed("假库打不开") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw UsageStatsStoreError.stepFailed(String(cString: sqlite3_errmsg(database)))
    }
  }

  private func insertSession(
    _ id: String, parentId: String? = nil, model: String = "glm-5.2", startedAt: Double,
    endedAt: Double? = nil,
    tokens: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int) = (0, 0, 0, 0),
    at url: URL
  ) throws {
    let parent = parentId.map { "'\($0)'" } ?? "NULL"
    let ended = endedAt.map { "\($0)" } ?? "NULL"
    try exec(
      """
      INSERT INTO sessions (id, parent_session_id, model, started_at, ended_at,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
      VALUES ('\(id)', \(parent), '\(model)', \(startedAt), \(ended),
        \(tokens.input), \(tokens.output), \(tokens.cacheRead), \(tokens.cacheWrite));
      """, at: url)
  }

  private func insertModelUsage(
    session: String, model: String,
    tokens: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int), at url: URL
  ) throws {
    try exec(
      """
      INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens,
        cache_read_tokens, cache_write_tokens)
      VALUES ('\(session)', '\(model)', \(tokens.input), \(tokens.output),
        \(tokens.cacheRead), \(tokens.cacheWrite));
      """, at: url)
  }

  /// 插一条消息；只有 `role == "tool"` 的行带 `tool_name`（真实库就是这样）。
  private func insertMessage(
    session: String, role: String = "tool", toolName: String? = nil, timestamp: Double,
    at url: URL
  ) throws {
    let name = toolName.map { "'\($0)'" } ?? "NULL"
    try exec(
      """
      INSERT INTO messages (session_id, role, tool_name, timestamp)
      VALUES ('\(session)', '\(role)', \(name), \(timestamp));
      """, at: url)
  }

  private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-hermes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeStore(in root: URL) throws -> UsageStatsStore {
    try UsageStatsStore(url: root.appendingPathComponent("usage.sqlite"))
  }

  private func readSnapshot(_ store: UsageStatsStore) throws -> UsageStatsSnapshot {
    try store.snapshot(window: .preset(.all), calendar: .current, now: Date(), isIndexing: false)
  }

  /// 直接读统计库的第一列（绕开快照，拿断言用的原始事实）。
  ///
  /// 与统计库自己的连接一样设忙等超时：这里开的是**另一条连接**（WAL 库上第一条语句要能
  /// 等到 `-shm` 就绪），不设超时的话瞬时 BUSY 会被下面的循环吞成「没有行」——断言就会以
  /// 「读到空」的形式莫名其妙地红，且看不出原因。
  private func column(_ sql: String, in root: URL) throws -> [String] {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(root.appendingPathComponent("usage.sqlite").path, &handle,
        SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle
    else { throw UsageStatsStoreError.openFailed("统计库打不开") }
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 2_000)

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw UsageStatsStoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }

    var results: [String] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      // 查询出错必须抛出来：吞成空数组会让断言以「读不到」的形式失败，查不出真因。
      guard status == SQLITE_ROW else {
        throw UsageStatsStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
      }
      guard let pointer = sqlite3_column_text(statement, 0) else { continue }
      results.append(String(cString: pointer))
    }
    return results
  }

  /// 某个会话的桶被标成了子代理还是主会话（`is_subagent` 列）。
  private func subagentFlags(ofSession sessionId: String, in root: URL) throws -> [String] {
    try column(
      "SELECT DISTINCT is_subagent FROM usage_bucket WHERE session_id = '\(sessionId)';",
      in: root)
  }

  private func indexedHermesSourceCount(in root: URL) throws -> [String] {
    try column("SELECT COUNT(*) FROM indexed_source WHERE source_id LIKE 'hermes:%';", in: root)
  }

  // MARK: - 用例

  @Test("一条会话：token 按模型落桶、工具调用按 tool_name 计数")
  func sessionProducesModelAndToolBuckets() throws {
    let root = try tempRoot()
    let database = try makeDatabase(in: root)

    // 会话的最后活动时间由 `ended_at` 决定（消息都比它早）。
    let ended = Date(timeIntervalSince1970: 1_787_000_000)
    let started = ended.timeIntervalSince1970 - 3_600
    try insertSession(
      "ses_root", model: "glm-5.2", startedAt: started,
      endedAt: ended.timeIntervalSince1970, at: database)
    try insertModelUsage(
      session: "ses_root", model: "glm-5.2", tokens: (1_000, 100, 4_000, 10), at: database)
    try insertModelUsage(
      session: "ses_root", model: "claude-opus-4.6", tokens: (20, 2, 30, 0), at: database)
    try insertMessage(
      session: "ses_root", toolName: "terminal", timestamp: started + 10, at: database)
    try insertMessage(
      session: "ses_root", toolName: "terminal", timestamp: started + 20, at: database)
    try insertMessage(
      session: "ses_root", toolName: "mcp__x__bash", timestamp: started + 30, at: database)
    // assistant 的调用声明行与 user 行都没有 `tool_name`：不产生工具计数。
    try insertMessage(
      session: "ses_root", role: "assistant", timestamp: started + 40, at: database)
    try insertMessage(session: "ses_root", role: "user", timestamp: started + 50, at: database)

    let store = try makeStore(in: root)
    let pass = UsageStatsPass(store: store, calendar: .current)
    let sweep = try pass.ingestHermes(databaseURL: database)

    #expect(sweep.sessions == 1)
    #expect(sweep.morePagesRemain == false)

    let snapshot = try readSnapshot(store)
    #expect(snapshot.totals.input == 1_020)
    #expect(snapshot.totals.output == 102)
    #expect(snapshot.totals.cacheRead == 4_030)
    #expect(snapshot.totals.cacheWrite == 10)
    #expect(snapshot.totals.sessions == 1)
    #expect(snapshot.totals.calls == 3)
    // 工具名归一：`mcp__x__bash` → `bash`。
    #expect(snapshot.tools.map { "\($0.name):\($0.calls)" } == ["terminal:2", "bash:1"])
    // 模型维度取 `session_model_usage.model`，按四路 token 之和排序。
    #expect(
      snapshot.models.map { "\($0.name):\($0.totals.total)" }
        == ["glm-5.2:5110", "claude-opus-4.6:52"])
    // 整条会话落进「最后活动时间」那一个桶：token 与工具调用同桶。
    let hourKey = UsageStatsKey.hour(for: ended, calendar: .current)
    #expect(try column("SELECT DISTINCT hour_key FROM usage_bucket;", in: root) == [hourKey])
    // 统计库里是「一条会话一行 + 一条游标行」。
    #expect(try indexedHermesSourceCount(in: root) == ["2"])
  }

  @Test("同一游标重跑与整源重放都不重复计数")
  func repeatedSweepDoesNotDoubleCount() throws {
    let root = try tempRoot()
    let database = try makeDatabase(in: root)

    let started = 1_787_000_000.0
    try insertSession("ses_root", startedAt: started, endedAt: started + 60, at: database)
    try insertModelUsage(
      session: "ses_root", model: "glm-5.2", tokens: (1_000, 100, 4_000, 10), at: database)
    try insertMessage(
      session: "ses_root", toolName: "terminal", timestamp: started + 10, at: database)

    let store = try makeStore(in: root)
    let pass = UsageStatsPass(store: store, calendar: .current)
    try pass.ingestHermes(databaseURL: database)
    let first = try readSnapshot(store)
    #expect(first.totals.calls == 1)

    // 游标已经越过这条会话：再跑一轮什么都不该变。
    try pass.ingestHermes(databaseURL: database)
    let second = try readSnapshot(store)
    #expect(first.totals == second.totals)
    #expect(first.tools == second.tools)
    #expect(first.models == second.models)

    // 会话又长了一条消息（最后活动时间前移）⇒ 这条会话被**整源重放**：旧桶换成新桶，
    // 而不是在旧桶上叠加。
    try insertMessage(
      session: "ses_root", toolName: "read", timestamp: started + 120, at: database)
    try pass.ingestHermes(databaseURL: database)
    let third = try readSnapshot(store)
    #expect(third.totals.calls == 2)
    #expect(third.totals.input == 1_000)
    #expect(third.totals.cacheRead == 4_000)
    // 两个工具的 calls 都是 1：榜的并列顺序由 SQL 决定，因此排序后再比。
    #expect(
      third.tools.map { "\($0.name):\($0.calls)" }.sorted() == ["read:1", "terminal:1"])
    #expect(try indexedHermesSourceCount(in: root) == ["2"])
  }

  @Test("重新统计：游标归零后全库重走一遍，修得回已经统计过的数字")
  func rebuildingReplaysEverySession() throws {
    let root = try tempRoot()
    let database = try makeDatabase(in: root)

    let started = 1_787_000_000.0
    try insertSession("ses_a", startedAt: started, endedAt: started + 60, at: database)
    try insertSession("ses_b", startedAt: started + 100, endedAt: started + 200, at: database)
    try insertModelUsage(
      session: "ses_a", model: "glm-5.2", tokens: (10, 1, 100, 0), at: database)
    try insertModelUsage(
      session: "ses_b", model: "claude-opus-4.6", tokens: (20, 2, 200, 0), at: database)
    try insertMessage(session: "ses_a", toolName: "terminal", timestamp: started + 10, at: database)
    try insertMessage(session: "ses_b", toolName: "grep", timestamp: started + 110, at: database)

    let store = try makeStore(in: root)
    // 每页 1 条：重算也要能跨页走完。
    let pass = UsageStatsPass(store: store, calendar: .current, hermesBatchLimit: 1)
    try pass.ingestHermes(databaseURL: database)
    let first = try readSnapshot(store)
    #expect(first.totals.sessions == 2)

    // 重算：游标归零、每条会话按整源重放写入 —— 不重复计数。
    try pass.ingestHermes(databaseURL: database, rebuilding: true)
    let rebuilt = try readSnapshot(store)
    #expect(first.totals == rebuilt.totals)
    #expect(first.tools == rebuilt.tools)

    // 桶丢了、游标还在：增量扫描不会再读到任何会话，只有重算能救回来。
    try clearUsageBuckets(in: root)
    try pass.ingestHermes(databaseURL: database)
    #expect(try readSnapshot(store).totals.isEmpty)

    try pass.ingestHermes(databaseURL: database, rebuilding: true)
    #expect(try readSnapshot(store).totals == first.totals)
    #expect(try readSnapshot(store).tools == first.tools)
  }

  @Test("子会话（parent_session_id 非空）：用量计入、不计入会话数、桶标 is_subagent")
  func childSessionsCountUsageButNotSessions() throws {
    let root = try tempRoot()
    let database = try makeDatabase(in: root)

    let started = 1_787_000_000.0
    try insertSession("ses_root", startedAt: started, endedAt: started + 600, at: database)
    try insertModelUsage(
      session: "ses_root", model: "glm-5.2", tokens: (10, 1, 0, 0), at: database)
    try insertMessage(
      session: "ses_root", toolName: "terminal", timestamp: started + 100, at: database)

    // `delegate_task` 派生的子会话在 `sessions` 里是一行独立记录：用量照算（Hermes 自己的
    // `insights.py` 也不排除子会话），只是不计入会话数。
    try insertSession(
      "ses_child", parentId: "ses_root", startedAt: started + 200,
      endedAt: started + 300, at: database)
    try insertModelUsage(
      session: "ses_child", model: "glm-5.2", tokens: (5_000, 500, 0, 0), at: database)
    try insertMessage(
      session: "ses_child", toolName: "terminal", timestamp: started + 250, at: database)

    let store = try makeStore(in: root)
    let pass = UsageStatsPass(store: store, calendar: .current)
    try pass.ingestHermes(databaseURL: database)

    let snapshot = try readSnapshot(store)
    #expect(snapshot.totals.input == 5_010)
    #expect(snapshot.totals.output == 501)
    #expect(snapshot.totals.calls == 2)
    #expect(snapshot.totals.sessions == 1)  // 子会话不计入会话数
    // 子会话自己的桶标成 is_subagent（与 OpenCode 的 subagentSessionIds 同一口径）。
    #expect(try subagentFlags(ofSession: "ses_child", in: root) == ["1"])
    #expect(try subagentFlags(ofSession: "ses_root", in: root) == ["0"])
  }

  @Test("游标只向前走：同一时间戳的多条按 id 继续排，一条都不丢")
  func cursorsOnlyMoveForward() throws {
    let root = try tempRoot()
    let database = try makeDatabase(in: root)

    // 两条会话的最后活动时间完全相同（只有 `started_at`、没有任何消息）：键集分页必须靠 id
    // 把后一条排出来——用「全库最大时间戳」当游标的那版实现会把它整条丢掉。
    let started = 1_787_000_000.0
    try insertSession("a", startedAt: started, at: database)
    try insertSession("b", startedAt: started, at: database)
    try insertModelUsage(session: "a", model: "glm-5.2", tokens: (10, 1, 0, 0), at: database)
    try insertModelUsage(session: "b", model: "glm-5.2", tokens: (20, 2, 0, 0), at: database)

    let store = try makeStore(in: root)
    // 每页 1 条：强制走两页。
    let pass = UsageStatsPass(store: store, calendar: .current, hermesBatchLimit: 1)
    let sweep = try pass.ingestHermes(databaseURL: database)

    #expect(sweep.sessions == 2)
    // 游标停在最后一条上：`(updatedAt, sessionId)` 两项都写进游标行。
    #expect(
      try column("SELECT cursor FROM indexed_source WHERE source_id = 'hermes:sweep';", in: root)
        == ["\(started):b"])

    let snapshot = try readSnapshot(store)
    #expect(snapshot.totals.input == 30)
    #expect(snapshot.totals.sessions == 2)

    let empty = HermesUsageCursor.empty
    let first = HermesUsageCursor(updatedAt: started, sessionId: "a")
    let second = HermesUsageCursor(updatedAt: started, sessionId: "b")
    let earlier = HermesUsageCursor(updatedAt: started - 1, sessionId: "z")

    #expect(first.isAfter(empty))
    #expect(second.isAfter(first))
    #expect(earlier.isAfter(first) == false)
    #expect(first.isAfter(first) == false)
  }

  @Test("没有按模型记账行的会话回落到 sessions 的合计，且不会与按模型的行重复计")
  func sessionsTotalsAreTheFallback() throws {
    let root = try tempRoot()
    let database = try makeDatabase(in: root)

    let started = 1_787_000_000.0
    // 本机 8723 条会话里有 5 条如此（合计 6.1M 输入 token）：没有 `session_model_usage` 行时
    // 整条丢掉会让总量少 1% 左右。
    try insertSession(
      "ses_root", model: "glm-5.2", startedAt: started, endedAt: started + 60,
      tokens: (1_000, 10, 200, 0), at: database)
    try insertMessage(
      session: "ses_root", toolName: "terminal", timestamp: started + 10, at: database)

    let store = try makeStore(in: root)
    let pass = UsageStatsPass(store: store, calendar: .current)
    try pass.ingestHermes(databaseURL: database)

    let snapshot = try readSnapshot(store)
    #expect(snapshot.totals.input == 1_000)
    #expect(snapshot.totals.output == 10)
    #expect(snapshot.totals.cacheRead == 200)
    #expect(snapshot.totals.sessions == 1)
    #expect(snapshot.models.map { $0.name } == ["glm-5.2"])

    // 补上按模型的行之后必须走 smu 那一支：同一批 token 不能被计两次。
    try insertModelUsage(
      session: "ses_root", model: "glm-5.2", tokens: (1_000, 10, 200, 0), at: database)
    try pass.ingestHermes(databaseURL: database, rebuilding: true)

    let rebuilt = try readSnapshot(store)
    #expect(rebuilt.totals.input == 1_000)
    #expect(rebuilt.totals.output == 10)
    #expect(rebuilt.totals.cacheRead == 200)
    #expect(rebuilt.totals.sessions == 1)
  }
}
