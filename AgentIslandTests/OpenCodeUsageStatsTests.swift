//
//  OpenCodeUsageStatsTests.swift
//  AgentIslandTests
//
//  OpenCode 的历史在 SQLite 里，增量靠游标分页。这里用一个最小的假库（session /
//  message / part 三张表）钉住两条容易写错的性质：
//    · 游标必须按 `(time_updated, id)` 键集分页——只认已处理过的位置，同一毫秒写入的
//      多条不能被跳过（曾经用「全库最大时间戳」当游标，被 LIMIT 截断的那批消息就永久丢了）；
//    · 每条消息在统计库里是独立数据源、重扫整源重放，所以重复扫描不会重复计数。
//

import Foundation
import SQLite3
import Testing

@testable import AgentIsland

@Suite("OpenCode 用量索引")
struct OpenCodeUsageStatsTests {
  // MARK: - 假库

  /// 建一个最小可用的 opencode 库（只包含统计用到的表与列）。
  private func makeDatabase(in root: URL) throws -> URL {
    let url = root.appendingPathComponent("opencode.db")
    try exec(
      """
      CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT);
      CREATE TABLE message (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
      CREATE TABLE part (
        id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
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

  private func insertSession(_ id: String, parentId: String?, at url: URL) throws {
    let parent = parentId.map { "'\($0)'" } ?? "NULL"
    try exec("INSERT INTO session (id, parent_id) VALUES ('\(id)', \(parent));", at: url)
  }

  /// 插入一条消息；`tokens` 为 nil 时不写 tokens（用户消息）。
  private func insertMessage(
    id: String, session: String, created: Int64, updated: Int64,
    tokens: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)?, at url: URL
  ) throws {
    let tokensJSON: String
    if let tokens {
      tokensJSON =
        """
        "tokens":{"input":\(tokens.input),"output":\(tokens.output),\
        "cache":{"read":\(tokens.cacheRead),"write":\(tokens.cacheWrite)}},
        """
    } else {
      tokensJSON = ""
    }
    let role = tokens == nil ? "user" : "assistant"
    let data = "{\"role\":\"\(role)\",\(tokensJSON)\"time\":{\"created\":\(created)}}"
    try exec(
      """
      INSERT INTO message (id, session_id, time_created, time_updated, data)
      VALUES ('\(id)', '\(session)', \(created), \(updated), '\(data)');
      """, at: url)
  }

  private func insertPart(
    id: String, message: String, session: String, created: Int64, updated: Int64, tool: String?,
    at url: URL
  ) throws {
    let data = tool.map { "{\"type\":\"tool\",\"tool\":\"\($0)\"}" } ?? "{\"type\":\"text\"}"
    try exec(
      """
      INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
      VALUES ('\(id)', '\(message)', '\(session)', \(created), \(updated), '\(data)');
      """, at: url)
  }

  private func makeStore(in root: URL) throws -> UsageStatsStore {
    try UsageStatsStore(url: root.appendingPathComponent("usage.sqlite"))
  }

  private func snapshot(_ store: UsageStatsStore) throws -> UsageStatsSnapshot {
    try store.snapshot(range: .all, calendar: .current, now: Date(), isIndexing: false)
  }

  // MARK: - 用例

  @Test("分页增量：同毫秒不漏、重扫不重复、子代理只计用量")
  func paginatedIngestIsCompleteAndIdempotent() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-opencode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try makeDatabase(in: root)

    try insertSession("ses_root", parentId: nil, at: database)
    try insertSession("ses_child", parentId: "ses_root", at: database)

    // m4 是用户消息（无 tokens），夹在中间：它不该产生桶，但游标要越过它。
    try insertMessage(
      id: "m4", session: "ses_root", created: 500, updated: 500, tokens: nil, at: database)
    try insertMessage(
      id: "m1", session: "ses_root", created: 1_000, updated: 1_000,
      tokens: (10, 1, 100, 0), at: database)
    // m2 与 m3 的 time_updated 相同：键集分页必须靠 id 把它们分开。
    try insertMessage(
      id: "m2", session: "ses_root", created: 2_000, updated: 2_000,
      tokens: (20, 2, 200, 0), at: database)
    try insertMessage(
      id: "m3", session: "ses_child", created: 2_000, updated: 2_000,
      tokens: (5, 1, 0, 0), at: database)
    try insertPart(
      id: "p1", message: "m1", session: "ses_root", created: 1_000, updated: 1_000, tool: "bash",
      at: database)
    try insertPart(
      id: "p2", message: "m2", session: "ses_root", created: 2_000, updated: 2_000,
      tool: "mcp__x__bash", at: database)
    try insertPart(
      id: "p3", message: "m2", session: "ses_root", created: 2_000, updated: 2_000, tool: "read",
      at: database)

    let store = try makeStore(in: root)
    // 每页 2 条：强制分页，走多轮读取。
    let pass = UsageStatsPass(store: store, calendar: .current, openCodeBatchLimit: 2)
    try pass.ingestOpenCode(databaseURL: database)

    var first = try snapshot(store)
    #expect(first.totals.input == 35)  // 10 + 20 + 5（子代理的 token 计入）
    #expect(first.totals.output == 4)
    #expect(first.totals.cacheRead == 300)
    #expect(first.totals.sessions == 1)  // 子代理会话不计入
    #expect(first.totals.calls == 3)  // bash + mcp__x__bash（归一后同名）+ read
    #expect(first.tools.map { "\($0.name):\($0.calls)" } == ["bash:2", "read:1"])

    // 重复扫描：不重复计数。
    try pass.ingestOpenCode(databaseURL: database)
    let second = try snapshot(store)
    #expect(first.totals == second.totals)
    #expect(first.tools == second.tools)

    // 追加一条更晚的消息，以及一条「与已处理行同一毫秒但 id 更大」的消息：
    // 两者都必须被读到（这正是阈值游标会漏掉的情形）。
    try insertMessage(
      id: "m5", session: "ses_root", created: 3_000, updated: 3_000,
      tokens: (7, 0, 0, 0), at: database)
    try insertPart(
      id: "p5", message: "m5", session: "ses_root", created: 3_000, updated: 3_000, tool: "grep",
      at: database)
    try insertMessage(
      id: "zzz", session: "ses_root", created: 2_000, updated: 2_000,
      tokens: (1, 1, 0, 0), at: database)

    try pass.ingestOpenCode(databaseURL: database)
    first = try snapshot(store)
    #expect(first.totals.input == 35 + 7 + 1)
    #expect(first.totals.output == 4 + 0 + 1)
    #expect(first.totals.calls == 4)
    #expect(first.tools.contains { $0.name == "grep" && $0.calls == 1 })
  }

  @Test("重新统计：游标归零后全库重走一遍，修得回已经统计过的数字")
  func rebuildingReplaysEveryMessage() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-opencode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try makeDatabase(in: root)

    try insertSession("ses_root", parentId: nil, at: database)
    try insertMessage(
      id: "m1", session: "ses_root", created: 1_000, updated: 1_000,
      tokens: (10, 1, 100, 0), at: database)
    try insertMessage(
      id: "m2", session: "ses_root", created: 2_000, updated: 2_000,
      tokens: (20, 2, 200, 0), at: database)
    try insertPart(
      id: "p1", message: "m1", session: "ses_root", created: 1_000, updated: 1_000, tool: "bash",
      at: database)

    let store = try makeStore(in: root)
    // 每页 2 条：重算也要能跨页走完。
    let pass = UsageStatsPass(store: store, calendar: .current, openCodeBatchLimit: 2)
    try pass.ingestOpenCode(databaseURL: database)
    let first = try snapshot(store)

    // 重算：游标归零、每条消息按整源重放写入 —— 不重复计数。
    try pass.ingestOpenCode(databaseURL: database, rebuilding: true)
    let rebuilt = try snapshot(store)
    #expect(first.totals == rebuilt.totals)
    #expect(first.tools == rebuilt.tools)

    // 桶丢了、游标还在：增量扫描不会再读到任何消息，只有重算能救回来。
    try clearUsageBuckets(in: root)
    try pass.ingestOpenCode(databaseURL: database)
    #expect(try snapshot(store).totals.isEmpty)

    try pass.ingestOpenCode(databaseURL: database, rebuilding: true)
    #expect(try snapshot(store).totals == first.totals)
    #expect(try snapshot(store).tools == first.tools)
  }

  @Test("单轮页数用尽时报「还没读完」：指纹门不能把没追平的游标挡在门外")
  func sweepReportsPendingCatchUp() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-opencode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try makeDatabase(in: root)

    try insertSession("ses_root", parentId: nil, at: database)
    for index in 0..<25 {
      try insertMessage(
        id: "m\(index)", session: "ses_root", created: Int64(1_000 + index),
        updated: Int64(1_000 + index), tokens: (1, 1, 0, 0), at: database)
    }

    let store = try makeStore(in: root)
    // 每页 1 条 + 单轮 20 页上限：25 条一轮读不完 → 必须报 morePagesRemain（否则下一轮
    // 会拿「库没变化」当理由跳过，剩下的消息永远进不来）。
    let pass = UsageStatsPass(store: store, calendar: .current, openCodeBatchLimit: 1)
    let first = try pass.ingestOpenCode(databaseURL: database)
    #expect(first.messages == 20)
    #expect(first.morePagesRemain)

    let second = try pass.ingestOpenCode(databaseURL: database)
    #expect(second.morePagesRemain == false)

    #expect(try snapshot(store).totals.input == 25)
  }

  @Test("游标只向前走")
  func cursorsOnlyMoveForward() {
    let start = OpenCodeUsageCursor.empty
    let later = OpenCodeUsageCursor(timeUpdated: 10, id: "a")
    let sameMillis = OpenCodeUsageCursor(timeUpdated: 10, id: "b")
    let earlier = OpenCodeUsageCursor(timeUpdated: 9, id: "z")

    #expect(later.isAfter(start))
    #expect(sameMillis.isAfter(later))
    #expect(!earlier.isAfter(later))
    #expect(!later.isAfter(later))
  }
}
