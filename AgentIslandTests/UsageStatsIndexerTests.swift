//
//  UsageStatsIndexerTests.swift
//  AgentIslandTests
//
//  用量索引的端到端行为：用临时目录里的真实记录文件驱动生产实现（源发现 → 增量
//  读取 → 统计库聚合 → 快照查询），钉死四条不变量：
//    · 扫描两次 == 扫描一次（幂等）；
//    · 半行不消费，补完换行后只计一次；
//    · 记录被截断时整源重放，不残留旧值；
//    · 子代理只计 token、不计会话数，工具名归一后合并。
//

import Foundation
import SQLite3
import Testing

@testable import AgentIsland

@Suite("用量统计索引")
struct UsageStatsIndexerTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    return calendar
  }()

  // MARK: - 夹具

  /// 固定「今天」：当地 10:00 起算，避免测试恰好在零点附近跑时把夹具挤到昨天。
  private var todayBase: Date {
    calendar.date(byAdding: .hour, value: 10, to: calendar.startOfDay(for: Date())) ?? Date()
  }

  private var oldBase: Date {
    calendar.date(byAdding: .day, value: -8, to: todayBase) ?? todayBase
  }

  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-stats-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // 源发现走 `FileManager` 枚举，返回的是展开后的路径（macOS 上临时目录是 /var 而
    // 枚举给 /private/var）。进度行按枚举结果落库，夹具根因此一开始就取同一份规范化
    // 路径，否则「同一个文件」会因为没有唯一约束而落成两行、用量被重复计入。
    return AgentProviderRoot.canonical(url)
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// omp / pi 的记录：条目级 ISO8601 时间戳，工具调用在 `message.content[].type == "toolCall"`。
  private func piLine(
    date: Date, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, tools: [String],
    role: String = "assistant", suffix: String = "", model: String = "gpt-5.2-codex"
  ) -> String {
    let content = tools.map {
      "{\"type\":\"toolCall\",\"id\":\"\(UUID().uuidString)\",\"name\":\"\($0)\"}"
    }.joined(separator: ",")
    return """
      {"type":"message","timestamp":"\(iso(date))","message":{"role":"\(role)","model":"\(model)","usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite)},"content":[\(content)]}}\(suffix)
      """
  }

  /// Claude Code 的记录：顶层 ISO8601 时间戳，工具调用在 `message.content[].type == "tool_use"`。
  private func claudeLine(
    date: Date, isSidechain: Bool, input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
    tools: [String], suffix: String = "", model: String = "claude-sonnet-4-5"
  ) -> String {
    let content = tools.map {
      "{\"type\":\"tool_use\",\"id\":\"\(UUID().uuidString)\",\"name\":\"\($0)\",\"input\":{}}"
    }.joined(separator: ",")
    return """
      {"type":"assistant","isSidechain":\(isSidechain),"timestamp":"\(iso(date))","message":{"role":"assistant","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)},"content":[\(content)]}}\(suffix)
      """
  }

  /// CodeBuddy 的记录：顶层毫秒 epoch 时间戳，一次调用一行 `function_call`
  /// （`name` / `callId` 在顶层），token 挂在 `message.usage` 上（`input_tokens` 含缓存命中）。
  private func codeBuddyLine(
    date: Date, input: Int, output: Int, cacheRead: Int, tools: [String],
    model: String = "deepseek-v4-flash"
  ) -> String {
    let milliseconds = Int(date.timeIntervalSince1970 * 1000)
    return tools.enumerated().map { index, tool in
      """
      {"id":"cb-\(milliseconds)-\(index)","timestamp":\(milliseconds),"type":"function_call","name":"\(tool)","callId":"call_\(index)","arguments":{},"sessionId":"cb-sess","providerData":{"model":"\(model)"},"message":{"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead)}}}
      """
    }.joined(separator: "\n")
  }

  /// 搭一套两个 Agent 的临时记录树，返回根目录。
  private func makeFixtureTree() throws -> URL {
    let root = try tempRoot()

    // omp 根会话：文件名形如 `<时间戳>_<uuid>.jsonl`，会话 id 取 uuid。
    let ompRoot = root.appendingPathComponent("omp")
    try write(
      piLine(
        date: todayBase, input: 100, output: 20, cacheRead: 300, cacheWrite: 40,
        tools: ["bash", "read"]) + "\n",
      to: ompRoot.appendingPathComponent("-work-demo/2026-01-01T00-00-00-000Z_abc12345.jsonl"))

    // omp 子代理：嵌套一层目录 → 只计 token，不计会话数。
    try write(
      piLine(date: todayBase, input: 50, output: 5, cacheRead: 0, cacheWrite: 0, tools: ["bash"])
        + "\n",
      to: ompRoot.appendingPathComponent(
        "-work-demo/2026-01-01T00-00-00-000Z_abc12345/SubAgentA.jsonl"))

    // 8 天前的历史记录：只出现在「全部」里。
    try write(
      piLine(date: oldBase, input: 1000, output: 100, cacheRead: 0, cacheWrite: 0, tools: ["grep"])
        + "\n",
      to: ompRoot.appendingPathComponent("-work-demo/2026-01-01T00-00-00-000Z_0d999999.jsonl"))

    // Claude：同一份文件里既有主会话也有 sidechain 行。
    let claudeRoot = root.appendingPathComponent("claude")
    let claudeFile = claudeRoot.appendingPathComponent("proj/sess-1.jsonl")
    try write(
      claudeLine(
        date: todayBase, isSidechain: false, input: 10, output: 5, cacheRead: 7, cacheWrite: 3,
        tools: ["Bash", "mcp__fs__bash"]) + "\n"
        + claudeLine(
          date: todayBase, isSidechain: true, input: 1, output: 1, cacheRead: 0, cacheWrite: 0,
          tools: []) + "\n",
      to: claudeFile)

    return root
  }

  private func makeStore(in root: URL) throws -> UsageStatsStore {
    try UsageStatsStore(url: root.appendingPathComponent("usage.sqlite"))
  }

  /// 直接对统计库执行一段 SQL（造旧结构、读落库形状用；不走 `UsageStatsStore`）。
  private func execSQL(_ sql: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK, let handle
    else { throw UsageStatsStoreError.openFailed(url.path) }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw UsageStatsStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
    }
  }

  /// 读统计库里的一个整数标量。
  private func scalar(_ sql: String, in root: URL) throws -> Int {
    let path = root.appendingPathComponent("usage.sqlite").path
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle
    else { throw UsageStatsStoreError.openFailed(path) }
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
    else { throw UsageStatsStoreError.prepareFailed(String(cString: sqlite3_errmsg(handle))) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw UsageStatsStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func sources(root: URL) -> [UsageSourceFile] {
    TranscriptUsageScanner.sources(
      for: .ohMyPi, roots: [root.appendingPathComponent("omp")])
      + TranscriptUsageScanner.sources(
        for: .claudeCode, roots: [root.appendingPathComponent("claude")])
  }

  private func pass(_ store: UsageStatsStore) -> UsageStatsPass {
    UsageStatsPass(store: store, calendar: calendar)
  }

  /// 快照里与时间无关的部分（`indexedAt` 每次扫描都会变）。
  private func comparable(_ snapshot: UsageStatsSnapshot) -> String {
    """
    totals=\(snapshot.totals) agents=\(snapshot.agents.map { "\($0.agent.rawValue):\($0.totals)" })
    models=\(snapshot.models.map { "\($0.name):\($0.totals)" })
    tools=\(snapshot.tools) trend=\(snapshot.trend.map { $0.total })
    """
  }

  // MARK: - 用例

  @Test("首次扫描：总量含缓存、子代理不计会话、工具名归一")
  func firstScanAggregates() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    let pass = pass(store)
    pass.ingest(sources: sources(root: root))

    let today = try store.snapshot(
      window: .preset(.today), calendar: calendar, now: Date(), isIndexing: false)

    // 输入 100 + 50 + 10 + 1；输出 20 + 5 + 5 + 1；缓存读 300 + 7；缓存写 40 + 3。
    #expect(today.totals.input == 161)
    #expect(today.totals.output == 31)
    #expect(today.totals.cacheRead == 307)
    #expect(today.totals.cacheWrite == 43)
    #expect(today.totals.total == 542)
    // 会话：omp 根会话 + Claude 主会话；子代理与 sidechain 不算。
    #expect(today.totals.sessions == 2)
    // 工具：bash（omp 根 + 子代理 + Claude 的 Bash 与 mcp__fs__bash 归一后同名）+ read。
    #expect(today.totals.calls == 5)
    #expect(today.tools.map { "\($0.name):\($0.calls)" } == ["bash:4", "read:1"])

    let byAgent = Dictionary(uniqueKeysWithValues: today.agents.map { ($0.agent, $0.totals) })
    #expect(byAgent[.ohMyPi]?.total == 515)
    #expect(byAgent[.ohMyPi]?.sessions == 1)
    #expect(byAgent[.claudeCode]?.total == 27)
    #expect(byAgent[.claudeCode]?.sessions == 1)

    // 8 天前的记录只出现在「全部」里。
    let all = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    #expect(all.totals.input == 161 + 1000)
    #expect(all.totals.sessions == 3)
    #expect(all.tools.first?.name == "grep" || all.tools.contains { $0.name == "grep" })
  }

  @Test("滚动窗口：近一天 / 近一周 / 近一月按整桶截断，老记录只进更长的窗口")
  func rollingRangesWindowTheRecords() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    pass(store).ingest(sources: sources(root: root))

    let now = Date()
    // 夹具：今天的记录（omp 根 + 子代理 + Claude 主/子代理，输入 161）与 8 天前的一条
    // （输入 1000）。8 天前在「近一周」窗口外、在「近一月」窗口内。
    let day = try store.snapshot(
      window: .preset(.lastDay), calendar: calendar, now: now, isIndexing: false)
    #expect(day.totals.input == 161)
    #expect(day.trend.count == 24)

    let week = try store.snapshot(
      window: .preset(.lastWeek), calendar: calendar, now: now, isIndexing: false)
    #expect(week.totals.input == 161)
    #expect(week.totals.sessions == 2)
    #expect(week.trend.count == 7)

    let month = try store.snapshot(
      window: .preset(.lastMonth), calendar: calendar, now: now, isIndexing: false)
    #expect(month.totals.input == 161 + 1000)
    #expect(month.totals.sessions == 3)
    #expect(month.trend.count == 30)
  }

  @Test("扫描两次与扫描一次结果相同")
  func ingestIsIdempotent() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    let pass = pass(store)
    let discovered = sources(root: root)

    pass.ingest(sources: discovered)
    let first = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    pass.ingest(sources: discovered)
    let second = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)

    #expect(comparable(first) == comparable(second))
  }

  @Test("增量：追加的记录只计一次，半行要等换行")
  func appendedRecordsCountOnce() throws {
    let root = try tempRoot()
    let ompRoot = root.appendingPathComponent("omp")
    let file = ompRoot.appendingPathComponent("-work/-work_aaa11111.jsonl")
    try write(
      piLine(date: todayBase, input: 10, output: 1, cacheRead: 0, cacheWrite: 0, tools: []) + "\n",
      to: file)

    let store = try makeStore(in: root)
    let pass = pass(store)
    pass.ingest(sources: sources(root: root))
    #expect(
      try store.snapshot(window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
        .totals.input == 10)

    // 半行：写入内容但没有换行 → 不消费。
    let appended = piLine(
      date: todayBase, input: 25, output: 2, cacheRead: 0, cacheWrite: 0, tools: [])
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appended.utf8))
    try handle.close()

    pass.ingest(sources: sources(root: root))
    #expect(
      try store.snapshot(window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
        .totals.input == 10)

    // 补上换行 → 计一次；再扫一次不会重复计。
    let tail = try FileHandle(forWritingTo: file)
    try tail.seekToEnd()
    try tail.write(contentsOf: Data("\n".utf8))
    try tail.close()

    pass.ingest(sources: sources(root: root))
    pass.ingest(sources: sources(root: root))
    #expect(
      try store.snapshot(window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
        .totals.input == 35)
  }

  @Test("重新统计：把每个源从头重读一遍，修得回已经统计过的数字")
  func rebuildingReplaysEverySource() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    let pass = pass(store)
    let discovered = sources(root: root)

    pass.ingest(sources: discovered)
    let first = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)

    // 重算不该重复计数：同一批文件从头再读一遍，结果必须一模一样。
    pass.ingest(sources: discovered, rebuilding: true)
    let rebuilt = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    #expect(first.totals == rebuilt.totals)
    #expect(comparable(first) == comparable(rebuilt))

    // 桶丢了、进度还在：增量扫描认为「没有变化」而什么都不做——这一步正是
    // 「手动重算」存在的理由。
    try clearUsageBuckets(in: root)
    pass.ingest(sources: discovered)
    #expect(
      try store.snapshot(window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
        .totals.isEmpty)

    pass.ingest(sources: discovered, rebuilding: true)
    let recovered = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    #expect(comparable(first) == comparable(recovered))
  }

  @Test("记录被截断时整源重放，不留旧值")
  func truncatedFileIsReplayed() throws {
    let root = try tempRoot()
    let ompRoot = root.appendingPathComponent("omp")
    let file = ompRoot.appendingPathComponent("-work/-work_bbb22222.jsonl")
    try write(
      piLine(
        date: todayBase, input: 100, output: 20, cacheRead: 300, cacheWrite: 40, tools: ["bash"])
        + "\n",
      to: file)

    let store = try makeStore(in: root)
    let pass = pass(store)
    pass.ingest(sources: sources(root: root))
    #expect(
      try store.snapshot(window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
        .totals.total == 460)

    // 整体重写成更短的一份（模拟 compaction / 用户清理）：旧值必须消失。
    try write(
      piLine(date: todayBase, input: 3, output: 1, cacheRead: 0, cacheWrite: 0, tools: ["grep"])
        + "\n",
      to: file)
    pass.ingest(sources: sources(root: root))

    let snapshot = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    #expect(snapshot.totals.total == 4)
    #expect(snapshot.tools.map { $0.name } == ["grep"])
  }

  @Test("模型拆分：同一份记录里换模型不会合成一行，工具行不进模型榜")
  func modelsSplitWithinTheSameFile() throws {
    let root = try tempRoot()
    let claudeRoot = root.appendingPathComponent("claude")
    let file = claudeRoot.appendingPathComponent("proj/sess-models.jsonl")
    // 同一个会话、同一个小时里换过模型：两行必须落成两条桶（合并键不带模型时，
    // 它们会合成一条 125 的桶，且只留先写入的那个模型名）。
    try write(
      claudeLine(
        date: todayBase, isSidechain: false, input: 10, output: 5, cacheRead: 7, cacheWrite: 3,
        tools: ["Bash"], model: "claude-sonnet-4-5") + "\n"
        + claudeLine(
          date: todayBase, isSidechain: false, input: 100, output: 0, cacheRead: 0, cacheWrite: 0,
          tools: ["Read"], model: "gpt-5.2-codex") + "\n",
      to: file)

    let store = try makeStore(in: root)
    pass(store).ingest(sources: sources(root: root))
    let snapshot = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)

    #expect(
      snapshot.models.map { "\($0.name):\($0.totals.total)" }
        == ["gpt-5.2-codex:100", "claude-sonnet-4-5:25"])
    // 工具调用行只进工具榜：既不携带 token，也不带模型标识（否则每次调用的 token
    // 会被算进某个模型）。
    #expect(
      try scalar(
        "SELECT COALESCE(SUM(input + output + cache_read + cache_write), 0) FROM usage_bucket WHERE tool <> '';",
        in: root) == 0)
    #expect(
      try scalar("SELECT COUNT(*) FROM usage_bucket WHERE tool <> '' AND model <> '';", in: root)
        == 0)
    // 模型榜上之和就是全库总量：没有模型标识的记录（理论上有的话）不会漏进榜里，
    // 也不会被凭空算成一行。
    #expect(snapshot.models.map(\.totals.total).reduce(0, +) == snapshot.totals.total)
    // 会话数按模型各算一次（两个模型都在同一个会话里 → 都是 1）。
    #expect(snapshot.models.map(\.totals.sessions) == [1, 1])
  }

  @Test("旧库自愈：缺 model 列时整库清空重建，回填后与新库一致")
  func legacySchemaIsRebuilt() throws {
    let root = try makeFixtureTree()
    // 旧结构：`usage_bucket` 没有 model 列（主键是五元组），进度表里留着历史进度。
    try execSQL(
      """
      CREATE TABLE usage_bucket (
        source_id TEXT NOT NULL, agent TEXT NOT NULL, session_id TEXT NOT NULL,
        hour_key TEXT NOT NULL, is_subagent INTEGER NOT NULL DEFAULT 0,
        tool TEXT NOT NULL DEFAULT '', records INTEGER NOT NULL DEFAULT 0,
        calls INTEGER NOT NULL DEFAULT 0, input INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_id, hour_key, is_subagent, session_id, tool));
      INSERT INTO usage_bucket (source_id, agent, session_id, hour_key, tool, input)
        VALUES ('old', 'omp', 'sess', '2026-01-01T00', '', 7);
      CREATE TABLE indexed_source (
        source_id TEXT PRIMARY KEY, agent TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0, read_offset INTEGER NOT NULL DEFAULT 0,
        mtime REAL NOT NULL DEFAULT 0, cursor TEXT, updated_at REAL NOT NULL);
      INSERT INTO indexed_source (source_id, agent, size_bytes, read_offset, mtime, updated_at)
        VALUES ('old', 'omp', 10, 10, 0, 0);
      """,
      at: root.appendingPathComponent("usage.sqlite"))

    let store = try makeStore(in: root)
    // 旧表被整表丢弃，进度一起清掉：进度留着的话增量扫描认为「没变化」，
    // 历史记录的模型永远补不回来。
    #expect(try store.sourceRecords().isEmpty)
    #expect(
      try store.snapshot(window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
        .totals.isEmpty)

    // 下一轮从头回填：结果与「空库起步」的新库逐项一致。
    let fresh = try makeStore(in: try tempRoot())
    let discovered = sources(root: root)
    pass(store).ingest(sources: discovered)
    pass(fresh).ingest(sources: discovered)

    let rebuilt = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    let reference = try fresh.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    #expect(comparable(rebuilt) == comparable(reference))
    #expect(!rebuilt.models.isEmpty)
  }

  @Test("CodeBuddy：顶层 function_call 行同时产工具调用与 token，旧的 EOF 进度会重放一次")
  func codeBuddyRowsAreIndexedAndStaleProgressReplays() throws {
    let root = try tempRoot()
    let codeBuddyRoot = root.appendingPathComponent("codebuddy")
    // 一行同时是「一次工具调用」和「一次调用的 token」：input 1000 含 400 缓存命中
    // ⇒ 非缓存输入 600；总量 1050 = 600 + 50 + 400。
    let file = codeBuddyRoot.appendingPathComponent("Users-tester-work-demo/sess-cb.jsonl")
    // 源发现走 `FileManager` 枚举：临时目录在 macOS 上是 `/var`，枚举返回的是展开后的
    // `/private/var`。进度行按枚举结果落库，因此种子与断言都要用同一份规范化路径。
    let sourcePath = AgentProviderRoot.canonical(file).path
    let line =
      codeBuddyLine(date: todayBase, input: 1_000, output: 50, cacheRead: 400, tools: ["Bash"])
      + "\n"
    try write(line, to: file)
    let size = UInt64(line.utf8.count)

    let store = try makeStore(in: root)
    let discovered = TranscriptUsageScanner.sources(for: .codeBuddy, roots: [codeBuddyRoot])
    #expect(discovered.count == 1)

    // 造「改版前的进度行」：文件已读到底、`cursor` 里没有解析器版本。增量扫描本来会
    // 判定「没有变化」而永远跳过它——这道闸门就是为这个现场加的。
    try execSQL(
      """
      INSERT INTO indexed_source (source_id, agent, size_bytes, read_offset, mtime, cursor, updated_at)
      VALUES ('\(sourcePath)', 'codebuddy', \(size), \(size), 0, NULL, 0);
      """,
      at: root.appendingPathComponent("usage.sqlite"))

    pass(store).ingest(sources: discovered)

    let snapshot = try store.snapshot(
      window: .preset(.today), calendar: calendar, now: Date(), isIndexing: false)
    let codeBuddy = try #require(snapshot.agents.first { $0.agent == .codeBuddy })
    #expect(codeBuddy.totals.input == 600)
    #expect(codeBuddy.totals.output == 50)
    #expect(codeBuddy.totals.cacheRead == 400)
    #expect(codeBuddy.totals.total == 1_050)
    #expect(codeBuddy.totals.sessions == 1)
    #expect(codeBuddy.totals.calls == 1)
    #expect(snapshot.tools.contains { $0.name == "bash" && $0.calls == 1 })
    // 进度行现在带上了版本：下一轮回到增量语义，不会每次重读全量。
    let cursor = try store.sourceRecords()[sourcePath]?.state.cursor
    #expect(cursor != nil, "重放后进度行必须带上解析器版本，实际 cursor=\(String(describing: cursor))")
  }

  @Test("记录文件删除后历史用量仍然保留")
  func deletedFileKeepsHistory() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    try pass(store).ingest(sources: sources(root: root))
    let before = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)

    // 删掉一个记录文件，并清掉它的进度行（与索引器的清理路径一致）。
    let target = root.appendingPathComponent("claude/proj/sess-1.jsonl")
    try FileManager.default.removeItem(at: target)
    try store.forgetCursor(sourceId: target.path)

    let after = try store.snapshot(
      window: .preset(.all), calendar: calendar, now: Date(), isIndexing: false)
    #expect(comparable(before) == comparable(after))
  }

  @Test("单个记录文件消失不影响其余文件的索引")
  func vanishedSourceDoesNotBlockTheRest() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    let discovered = sources(root: root)

    // 发现之后、索引之前文件被删掉（真实场景：应用清理旧会话）。
    let vanished = root.appendingPathComponent("claude/proj/sess-1.jsonl")
    try FileManager.default.removeItem(at: vanished)

    let pass = pass(store)
    let outcome = pass.ingest(sources: discovered)
    #expect(outcome.failures == 0)

    // 其余记录的用量照常入库：omp 根会话 + 子代理（不含被删掉的 Claude 会话）。
    let snapshot = try store.snapshot(
      window: .preset(.today), calendar: calendar, now: Date(), isIndexing: false)
    #expect(snapshot.totals.input == 150)
    #expect(snapshot.totals.sessions == 1)
  }

  @Test("源发现：识别根会话、子代理与 Claude 的 subagents 目录")
  func sourceDiscoveryClassifiesSubagents() throws {
    let root = try makeFixtureTree()
    let discovered = sources(root: root)
    // 枚举可能返回 `/private/var/...`（macOS 上 /var 是软链接），而夹具路径写的是
    // `/var/...`：比较前统一去掉 `/private` 前缀，别把等价路径当成两条。
    let byPath = Dictionary(
      uniqueKeysWithValues: discovered.map { (Self.withoutPrivatePrefix($0.path), $0) })

    let ompRootFile = Self.withoutPrivatePrefix(
      ompRootPath(root).appendingPathComponent("-work-demo/2026-01-01T00-00-00-000Z_abc12345.jsonl")
        .path)
    #expect(byPath[ompRootFile]?.isSubagentFile == false)
    #expect(byPath[ompRootFile]?.sessionId == "abc12345")

    let subagentFile = Self.withoutPrivatePrefix(
      ompRootPath(root).appendingPathComponent(
        "-work-demo/2026-01-01T00-00-00-000Z_abc12345/SubAgentA.jsonl"
      ).path)
    #expect(byPath[subagentFile]?.isSubagentFile == true)

    let claudeFile = Self.withoutPrivatePrefix(
      root.appendingPathComponent("claude/proj/sess-1.jsonl").path)
    #expect(byPath[claudeFile]?.sessionId == "sess-1")

    // Claude 的 `subagents/` 目录：会话 id 取父目录名（记录本身是子代理）。
    let claudeSubagent = root.appendingPathComponent("claude/proj/sess-1/subagents/agent-x.jsonl")
    try write(
      claudeLine(
        date: todayBase, isSidechain: false, input: 2, output: 1, cacheRead: 0, cacheWrite: 0,
        tools: []) + "\n",
      to: claudeSubagent)
    let entry = sources(root: root).first {
      Self.withoutPrivatePrefix($0.path) == Self.withoutPrivatePrefix(claudeSubagent.path)
    }
    #expect(entry?.isSubagentFile == true)
    #expect(entry?.sessionId == "sess-1")
  }

  @Test("自选范围的右端是半开的：末日之后的记录不计入")
  func customWindowExcludesLaterDays() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    let pass = pass(store)
    pass.ingest(sources: sources(root: root))

    let now = Date()
    let today = calendar.startOfDay(for: now)
    guard
      let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today),
      let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)
    else {
      Issue.record("构造窗口边界失败")
      return
    }

    // 夹具里 8 天前那份记录的 1000 输入在窗口外：自选窗口只覆盖今天的 161。
    let recent = try store.snapshot(
      window: .custom(from: sevenDaysAgo, to: today), calendar: calendar, now: now,
      isIndexing: false)
    #expect(recent.totals.input == 161)
    #expect(recent.trend.count == 8)
    // 首桶就是自选的起点那天（天粒度：8 天跨度按天分桶）。
    #expect(recent.trend.first?.start == sevenDaysAgo)

    // 起点前移一天，那份记录就进来了：右端仍钉在「今天」。
    let wide = try store.snapshot(
      window: .custom(from: eightDaysAgo, to: today), calendar: calendar, now: now,
      isIndexing: false)
    #expect(wide.totals.input == 1161)
    #expect(wide.trend.count == 9)

    // 右端真的是半开的：窗口停在「8 天前」那一天时，今天的数据一点都进不来。
    let historic = try store.snapshot(
      window: .custom(from: eightDaysAgo, to: eightDaysAgo), calendar: calendar, now: now,
      isIndexing: false)
    #expect(historic.totals.input == 1000)
    #expect(historic.totals.sessions == 1)
  }

  @Test("自选窗口的左右边界：起点 00:00 计入、终点次日 00:00 不计入")
  func customWindowBoundaryIsInclusiveAtStart() throws {
    let root = try tempRoot()
    let ompRoot = root.appendingPathComponent("omp")
    let today = calendar.startOfDay(for: Date())
    guard
      let windowStart = calendar.date(byAdding: .day, value: -2, to: today),
      let windowEnd = calendar.date(byAdding: .day, value: -1, to: today),
      let hourBeforeStart = calendar.date(byAdding: .hour, value: -1, to: windowStart),
      let lastHourOfEnd = calendar.date(byAdding: .hour, value: 23, to: windowEnd)
    else {
      Issue.record("构造边界失败")
      return
    }

    // 四个边界时刻各一条：起点当日 00:00（含）、起点前一小时（不含）、
    // 终点当日 23:00（含）、终点次日 00:00（= 窗口右端，不含）。
    let instants: [(date: Date, input: Int)] = [
      (windowStart, 100),
      (hourBeforeStart, 1_000),
      (lastHourOfEnd, 10),
      (today, 1_000),
    ]
    for (index, item) in instants.enumerated() {
      try write(
        piLine(
          date: item.date, input: item.input, output: 0, cacheRead: 0, cacheWrite: 0, tools: [])
          + "\n",
        to: ompRoot.appendingPathComponent("-boundary/session-\(index).jsonl"))
    }

    let store = try makeStore(in: root)
    pass(store).ingest(sources: sources(root: root))
    let snapshot = try store.snapshot(
      window: .custom(from: windowStart, to: windowEnd), calendar: calendar, now: Date(),
      isIndexing: false)

    // 左端含（100 在）而右端不含（两个 1000 都不在）——把 `>=` 写成 `>` 或把 `<` 写成
    // `<=`，这条断言都会失败。
    #expect(snapshot.totals.input == 110)
    #expect(snapshot.totals.sessions == 2)
  }

  @Test("秋令时回拨那天：25 小时的记录全部计入，且每个有数据的整点桶都在计划里")
  func hourBucketsCoverEveryRecordedHourInDSTDay() throws {
    var zoneCalendar = calendar
    zoneCalendar.timeZone = TimeZone(identifier: "America/Havana") ?? .gmt
    guard let day = zoneCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1))
    else {
      Issue.record("构造日期失败")
      return
    }
    let start = zoneCalendar.startOfDay(for: day)

    let root = try tempRoot()
    let ompRoot = root.appendingPathComponent("omp")
    // 按**绝对时间**每小时一条：当地这一天有 25 小时（00:00 回拨重复一次）。
    // 两个 00:00 在按小时键分组时是同一个桶，因此总量是 25、桶只有 24 个。
    for hour in 0..<25 {
      try write(
        piLine(
          date: start.addingTimeInterval(Double(hour) * 3600), input: 1, output: 0, cacheRead: 0,
          cacheWrite: 0, tools: []) + "\n",
        to: ompRoot.appendingPathComponent("-dst/session-\(hour).jsonl"))
    }

    let store = try makeStore(in: root)
    // 分桶日历必须与查询日历一致：记录按当地小时键入库。
    UsageStatsPass(store: store, calendar: zoneCalendar)
      .ingest(sources: sources(root: root))

    let snapshot = try store.snapshot(
      window: .custom(from: start, to: start), calendar: zoneCalendar, now: Date(),
      isIndexing: false)

    #expect(snapshot.totals.input == 25)

    let expectedKeys = Set(
      (0..<25).map { hour in
        UsageStatsKey.hour(
          for: start.addingTimeInterval(Double(hour) * 3600), calendar: zoneCalendar)
      })
    let plannedKeys = Set(
      snapshot.trend.map {
        UsageStatsKey.bucket(for: $0.start, granularity: .hour, calendar: zoneCalendar)
      })
    let dataKeys = Set(
      snapshot.trend.filter { $0.input > 0 }.map {
        UsageStatsKey.bucket(for: $0.start, granularity: .hour, calendar: zoneCalendar)
      })

    #expect(
      plannedKeys == expectedKeys, "计划必须覆盖窗口内每个整点键，缺 \(expectedKeys.subtracting(plannedKeys))")
    #expect(dataKeys == expectedKeys, "有数据的桶必须都在计划里，缺 \(expectedKeys.subtracting(dataKeys))")
    #expect(snapshot.trend.count == expectedKeys.count)
  }

  /// 去掉 `/private` 前缀后的路径（macOS 上 `/var` 指向 `/private/var`）。
  private static func withoutPrivatePrefix(_ path: String) -> String {
    path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
  }

  private func ompRootPath(_ root: URL) -> URL {
    root.appendingPathComponent("omp")
  }
}

/// 清空用量桶但**保留读取进度**（模拟最坏情形：桶丢了、进度还在）。两个统计
/// 套件都用它造「增量扫描救了不回来、只有重算能救」的现场。
func clearUsageBuckets(in root: URL) throws {
  var handle: OpaquePointer?
  let path = root.appendingPathComponent("usage.sqlite").path
  guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let handle
  else {
    throw UsageStatsStoreError.openFailed(path)
  }
  defer { sqlite3_close(handle) }
  guard sqlite3_exec(handle, "DELETE FROM usage_bucket;", nil, nil, nil) == SQLITE_OK
  else {
    throw UsageStatsStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
  }
}
