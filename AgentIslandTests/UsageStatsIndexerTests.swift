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
    return url
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
    role: String = "assistant", suffix: String = ""
  ) -> String {
    let content = tools.map {
      "{\"type\":\"toolCall\",\"id\":\"\(UUID().uuidString)\",\"name\":\"\($0)\"}"
    }.joined(separator: ",")
    return """
      {"type":"message","timestamp":"\(iso(date))","message":{"role":"\(role)","usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite)},"content":[\(content)]}}\(suffix)
      """
  }

  /// Claude Code 的记录：顶层 ISO8601 时间戳，工具调用在 `message.content[].type == "tool_use"`。
  private func claudeLine(
    date: Date, isSidechain: Bool, input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
    tools: [String], suffix: String = ""
  ) -> String {
    let content = tools.map {
      "{\"type\":\"tool_use\",\"id\":\"\(UUID().uuidString)\",\"name\":\"\($0)\",\"input\":{}}"
    }.joined(separator: ",")
    return """
      {"type":"assistant","isSidechain":\(isSidechain),"timestamp":"\(iso(date))","message":{"role":"assistant","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)},"content":[\(content)]}}\(suffix)
      """
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
      range: .today, calendar: calendar, now: Date(), isIndexing: false)

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
    let all = try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
    #expect(all.totals.input == 161 + 1000)
    #expect(all.totals.sessions == 3)
    #expect(all.tools.first?.name == "grep" || all.tools.contains { $0.name == "grep" })
  }

  @Test("扫描两次与扫描一次结果相同")
  func ingestIsIdempotent() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    let pass = pass(store)
    let discovered = sources(root: root)

    pass.ingest(sources: discovered)
    let first = try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
    pass.ingest(sources: discovered)
    let second = try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)

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
      try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
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
      try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
        .totals.input == 10)

    // 补上换行 → 计一次；再扫一次不会重复计。
    let tail = try FileHandle(forWritingTo: file)
    try tail.seekToEnd()
    try tail.write(contentsOf: Data("\n".utf8))
    try tail.close()

    pass.ingest(sources: sources(root: root))
    pass.ingest(sources: sources(root: root))
    #expect(
      try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
        .totals.input == 35)
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
      try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
        .totals.total == 460)

    // 整体重写成更短的一份（模拟 compaction / 用户清理）：旧值必须消失。
    try write(
      piLine(date: todayBase, input: 3, output: 1, cacheRead: 0, cacheWrite: 0, tools: ["grep"])
        + "\n",
      to: file)
    pass.ingest(sources: sources(root: root))

    let snapshot = try store.snapshot(
      range: .all, calendar: calendar, now: Date(), isIndexing: false)
    #expect(snapshot.totals.total == 4)
    #expect(snapshot.tools.map { $0.name } == ["grep"])
  }

  @Test("记录文件删除后历史用量仍然保留")
  func deletedFileKeepsHistory() throws {
    let root = try makeFixtureTree()
    let store = try makeStore(in: root)
    try pass(store).ingest(sources: sources(root: root))
    let before = try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)

    // 删掉一个记录文件，并清掉它的进度行（与索引器的清理路径一致）。
    let target = root.appendingPathComponent("claude/proj/sess-1.jsonl")
    try FileManager.default.removeItem(at: target)
    try store.forgetCursor(sourceId: target.path)

    let after = try store.snapshot(range: .all, calendar: calendar, now: Date(), isIndexing: false)
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
    let failures = pass.ingest(sources: discovered)
    #expect(failures == 0)

    // 其余记录的用量照常入库：omp 根会话 + 子代理（不含被删掉的 Claude 会话）。
    let snapshot = try store.snapshot(range: .today, calendar: calendar, now: Date(), isIndexing: false)
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

  /// 去掉 `/private` 前缀后的路径（macOS 上 `/var` 指向 `/private/var`）。
  private static func withoutPrivatePrefix(_ path: String) -> String {
    path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
  }

  private func ompRootPath(_ root: URL) -> URL {
    root.appendingPathComponent("omp")
  }
}
