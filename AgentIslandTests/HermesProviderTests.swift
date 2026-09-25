//
//  HermesProviderTests.swift
//  AgentIslandTests
//
//  Hermes 的接入契约：会话记录不在文件树里，而在 `<HERMES_HOME>/state.db` 的 SQLite 库里
//  （`sessions` / `messages` 两张表）。这里钉六件事：
//    · Provider 的 home 解析（`$HERMES_HOME` > `~/.hermes`）与存在性闸门；
//    · 会话列表的过滤（子会话 / 已归档不收）与活动时间（进行中的会话取最后一条消息时间）；
//    · 记录解析按行 id 增量推进：不重复产出，追加一行只产出那一行；
//    · 活跃行「先落行、后补正文」时重扫游标行并原地更新气泡；
//    · 工具调用与结果：`tool_calls` 解析成工具气泡，`tool` 行按 `tool_call_id` 配对。
//
//  夹具路径：库位置由 `HermesSessionStore` / `HermesTranscriptSchema` 的显式形参给出
//  （生产传 nil，由 Provider 解析）。用例**不写全局偏好键、也不动进程环境变量**：
//  测试宿主就是真实 app 进程，`AppSettings.setAgentRootOverride` 落进的是开发者真实的
//  `com.celestial.AgentIsland` 偏好域，而本进程里并行的 `AgentConfigInstallerTests` 的
//  Hermes 用例解析配置根时会读同一个键——两边互相踩（安装器把配置写进这边的临时目录、
//  断言却去自己的 home 找），交错写入还会把已删除的临时路径留在真实偏好域里（此后真实
//  app 的 Hermes 配置根指向不存在的目录，界面永远「未安装」）。`HERMES_HOME` 同理只以
//  `HermesAgentProvider(environment:)` 注入，不 `setenv`。
//
//  因此这里既不需要 `AppSettings`，也就没有跨 suite 共享状态：不用 `.serialized`。
//
//  `databaseURL: nil`（走 Provider 解析开发者真实的 `~/.hermes`）那条路径不入用例：它
//  取决于本机装没装 Hermes，断言会随机器而变；Provider 自己的解析由下面的
//  `pathsFollowConfigRoot` 钉着。
//

import Foundation
import SQLite3
import Testing

@testable import AgentIsland

@Suite("Hermes 会话记录")
struct HermesProviderTests {
  // MARK: - 夹具

  /// 临时 home：先建目录再归一（`realpath` 对不存在的路径无效，见 AgentProviderTests）。
  private func tempHome() throws -> URL {
    let raw = FileManager.default.temporaryDirectory
      .appendingPathComponent("hermes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    return AgentProviderRoot.canonical(raw)
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// 造一个最小可用的 `state.db`（只包含读取路径用到的列），返回库文件位置。
  @discardableResult
  private func makeDatabase(in home: URL) throws -> URL {
    let url = home.appendingPathComponent(".hermes/state.db")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try execute(
      """
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        parent_session_id TEXT,
        started_at REAL NOT NULL,
        ended_at REAL,
        title TEXT,
        cwd TEXT,
        archived INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT,
        tool_call_id TEXT,
        tool_calls TEXT,
        tool_name TEXT,
        timestamp REAL NOT NULL,
        token_count INTEGER,
        finish_reason TEXT,
        reasoning TEXT,
        reasoning_content TEXT
      );
      """,
      at: url)
    return url
  }

  /// 直连库执行 SQL：夹具自己建库、插数，不过生产代码。
  private func execute(_ sql: String, at url: URL) throws {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK,
      let handle
    else { throw HermesFixtureError.database("夹具库打不开：\(url.path)") }
    defer { sqlite3_close(handle) }

    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw HermesFixtureError.database(String(cString: sqlite3_errmsg(handle)))
    }
  }

  /// SQL 字面量：字符串里的单引号按 SQL 规则翻倍，nil 写成 NULL。
  private func literal(_ value: String?) -> String {
    guard let value else { return "NULL" }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
  }

  private func insertSession(
    id: String,
    startedAt: TimeInterval,
    endedAt: TimeInterval?,
    title: String? = nil,
    cwd: String? = nil,
    archived: Int = 0,
    parent: String? = nil,
    at url: URL
  ) throws {
    let ended = endedAt.map { String($0) } ?? "NULL"
    try execute(
      """
      INSERT INTO sessions(id, parent_session_id, started_at, ended_at, title, cwd, archived)
      VALUES (\(literal(id)), \(literal(parent)), \(startedAt), \(ended), \(literal(title)),
              \(literal(cwd)), \(archived));
      """,
      at: url)
  }

  private func insertMessage(
    session: String,
    role: String,
    content: String? = nil,
    toolCallId: String? = nil,
    toolCalls: String? = nil,
    toolName: String? = nil,
    timestamp: TimeInterval,
    finishReason: String? = nil,
    reasoning: String? = nil,
    reasoningContent: String? = nil,
    at url: URL
  ) throws {
    try execute(
      """
      INSERT INTO messages(session_id, role, content, tool_call_id, tool_calls, tool_name,
                           timestamp, finish_reason, reasoning, reasoning_content)
      VALUES (\(literal(session)), \(literal(role)), \(literal(content)), \(literal(toolCallId)),
              \(literal(toolCalls)), \(literal(toolName)), \(timestamp),
              \(literal(finishReason)), \(literal(reasoning)), \(literal(reasoningContent)));
      """,
      at: url)
  }

  // MARK: - Provider

  @Test("配置根：缺根时 paths() 为 nil，有根时给出 home，$HERMES_HOME 压过它")
  func pathsFollowConfigRoot() throws {
    let home = try tempHome()
    defer { remove(home) }

    let provider = HermesAgentProvider(home: home)
    #expect(provider.paths() == nil, "缺 ~/.hermes 时应为 nil")
    #expect(provider.databaseFile == nil)
    // 记录类 API 在缺根时安全返回（历史在库里，这些一律为空）
    #expect(provider.transcriptFile(sessionId: "s1", cwd: "/tmp/demo") == nil)
    #expect(provider.isTranscriptFile("/tmp/whatever.jsonl") == false)
    #expect(provider.sessionId(fromTranscriptFile: "/tmp/whatever.jsonl") == nil)
    #expect(try provider.cwd(fromTranscriptFile: "/tmp/whatever.jsonl") == nil)
    #expect(provider.subagentTranscriptFiles(sessionId: "s1", cwd: "/tmp/demo").isEmpty)

    let hermesHome = home.appendingPathComponent(".hermes")
    try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
    #expect(provider.paths()?.configDir.path == hermesHome.path)
    #expect(provider.paths()?.sessionsDir == nil, "记录不在文件树里")
    #expect(provider.databaseFile == nil, "home 在、库还没建时不该给库路径")

    let database = try makeDatabase(in: home)
    #expect(provider.databaseFile?.path == database.path)

    // `$HERMES_HOME` 覆盖（含 `~/` 展开）
    let overridden = HermesAgentProvider(home: home, environment: ["HERMES_HOME": "~/hermes-alt"])
    #expect(overridden.paths() == nil, "覆盖根不存在时不应给 paths()")
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent("hermes-alt"), withIntermediateDirectories: true)
    #expect(
      overridden.paths()?.configDir.path == home.appendingPathComponent("hermes-alt").path)
    #expect(overridden.databaseFile == nil, "另一个 home 里没有库")

    // 空白值视作未设置
    let blank = HermesAgentProvider(home: home, environment: ["HERMES_HOME": "   "])
    #expect(blank.paths()?.configDir.path == hermesHome.path)

    // 「用户在设置面板里指定目录」的优先级（环境变量压过它、它压过自动检测）不在本例覆盖：
    // 写入那个键就是写真实 app 的偏好域，会与本进程并行的安装器用例抢同一个键（见文件头）。
    // 读写语义由 `AgentRootOverrideSettingsTests.roundTripOverride` 钉，解析由
    // `AgentProviderTests.userOverridePathResolution` 钉——各 Provider 共用同一段代码。
  }

  // MARK: - 会话列表

  @Test("会话列表：只收顶层未归档的会话，活动时间取「开始 / 结束 / 最后一条消息」的最大值")
  func sessionsFilterAndOrder() throws {
    let home = try tempHome()
    defer { remove(home) }
    let database = try makeDatabase(in: home)
    let now = Date().timeIntervalSince1970

    // A：进行中（`ended_at` 为空），活动时间只能靠最后一条消息 —— 应排第一
    try insertSession(
      id: "active", startedAt: now - 7200, endedAt: nil, title: "进行中", cwd: "/tmp/active",
      at: database)
    try insertMessage(
      session: "active", role: "user", content: "你好", timestamp: now - 60, at: database)
    // B：已结束：活动时间 = `ended_at`
    try insertSession(
      id: "ended", startedAt: now - 3600, endedAt: now - 90, cwd: "/tmp/ended", at: database)
    // C：没有消息、也没有结束时间：活动时间回落到 `started_at`（写成 0 就会被整条漏掉）
    try insertSession(id: "started-only", startedAt: now - 1200, endedAt: nil, at: database)
    // D：活动时间在窗口之外 → 不收
    try insertSession(id: "old", startedAt: now - 86400, endedAt: now - 80000, at: database)
    // E：子会话（`parent_session_id` 非空）→ 不收
    try insertSession(
      id: "child", startedAt: now - 10, endedAt: nil, parent: "active", at: database)
    // F：已归档 → 不收
    try insertSession(id: "archived", startedAt: now - 10, endedAt: nil, archived: 1, at: database)

    let since = Date(timeIntervalSince1970: now - 1800)
    let found = HermesSessionStore.sessions(since: since, limit: 10, databaseURL: database)
    #expect(found.map(\.sessionId) == ["active", "ended", "started-only"])
    #expect(found.allSatisfy { $0.agent == .hermes })
    #expect(found.allSatisfy { $0.transcriptPath == nil }, "历史在库里，没有记录文件")
    #expect(found[0].cwd == "/tmp/active")
    #expect(found[0].title == "进行中")
    #expect(abs(found[0].updatedAt.timeIntervalSince1970 - (now - 60)) < 1)
    #expect(abs(found[1].updatedAt.timeIntervalSince1970 - (now - 90)) < 1)
    #expect(found[2].cwd == "", "没有 cwd 的会话给空串（与 OpenCode 同一口径）")
    #expect(found[2].title == nil)

    // limit 按活动时间从新到旧裁剪
    #expect(
      HermesSessionStore.sessions(since: since, limit: 1, databaseURL: database)
        .map(\.sessionId) == ["active"])

    // 库不在时降级为「没有会话」，而不是崩或抛；而且**只读打开不会凭空建文件**
    let missing = home.appendingPathComponent("missing/state.db")
    #expect(
      HermesSessionStore.sessions(since: since, limit: 10, databaseURL: missing).isEmpty)
    #expect(
      HermesSessionStore.messages(
        sessionId: "active", sinceRowId: 0, limit: 10, databaseURL: missing
      ).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
  }

  // MARK: - 记录解析

  @Test("增量：第一次读产出两行气泡，无新消息时不再产出，追加一行只产出那一行")
  func schemaReadsIncrementally() throws {
    let home = try tempHome()
    defer { remove(home) }
    let database = try makeDatabase(in: home)
    let now = Date().timeIntervalSince1970

    try insertSession(id: "s1", startedAt: now - 600, endedAt: nil, cwd: "/tmp/demo", at: database)
    try insertMessage(
      session: "s1", role: "user", content: "帮我看看这个库", timestamp: now - 300, at: database)
    try insertMessage(
      session: "s1", role: "assistant", content: "看完了", timestamp: now - 200,
      finishReason: "stop", at: database)
    // 别的会话的消息不该混进来（顺带让行 id 跳号，证明游标是「每会话」的）
    try insertSession(id: "s2", startedAt: now - 600, endedAt: nil, at: database)
    try insertMessage(
      session: "s2", role: "user", content: "另一条会话", timestamp: now - 150, at: database)

    let schema = HermesTranscriptSchema(databaseURL: database)
    #expect(schema.agent == .hermes)
    #expect(schema.transcriptFile(sessionId: "s1", cwd: "/tmp/demo") == nil)
    var state = TranscriptParseState()

    let first = schema.read(sessionId: "s1", cwd: "/tmp/demo", state: &state)
    #expect(first.newMessages.map(\.id) == ["hermes-message-1", "hermes-message-2"])
    #expect(first.newMessages.map(\.role) == [.user, .assistant])
    #expect(first.newMessages[0].textContent == "帮我看看这个库")
    #expect(first.isNewContent)
    #expect(first.activity.contains(.promptSubmitted(text: "帮我看看这个库")))
    #expect(first.activity.contains(.turnFinished), "finish_reason=stop 即本轮结束")
    #expect(state.messages.count == 2, "对话历史要留在解析状态里")
    #expect(state.firstUserMessage == "帮我看看这个库")
    #expect(abs((state.lastUserMessageDate?.timeIntervalSince1970 ?? 0) - (now - 300)) < 1)
    // 只有用户行写「最后一条消息」，助手行不写（按方案的角色分工）
    #expect(state.lastMessage == "帮我看看这个库")
    #expect(state.lastMessageRole == ChatRole.user.rawValue)

    let second = schema.read(sessionId: "s1", cwd: "/tmp/demo", state: &state)
    #expect(second.newMessages.isEmpty)
    #expect(!second.isNewContent)
    #expect(second.activity.isEmpty)

    try insertMessage(
      session: "s1", role: "user", content: "再补一句", timestamp: now - 10, at: database)
    let third = schema.read(sessionId: "s1", cwd: "/tmp/demo", state: &state)
    #expect(third.newMessages.map(\.id) == ["hermes-message-4"], "只产出新追加的那一行")
    #expect(third.newMessages[0].textContent == "再补一句")
    #expect(state.messages.count == 3)
  }

  @Test("活跃行重扫：正文与 finish_reason 晚到时原地更新气泡，本轮结束只在补报那一次")
  func boundaryRowIsRescanned() throws {
    let home = try tempHome()
    defer { remove(home) }
    let database = try makeDatabase(in: home)
    let now = Date().timeIntervalSince1970

    try insertSession(id: "s1", startedAt: now - 600, endedAt: nil, at: database)
    // 先落行、后补正文：助手行进库时只有半截内容、没有 finish_reason（活跃行的真实形态）
    try insertMessage(
      session: "s1", role: "assistant", content: "正在写", timestamp: now - 60, at: database)

    let schema = HermesTranscriptSchema(databaseURL: database)
    var state = TranscriptParseState()

    let first = schema.read(sessionId: "s1", cwd: "", state: &state)
    #expect(first.newMessages.map(\.id) == ["hermes-message-1"])
    #expect(first.newMessages[0].textContent == "正在写")
    #expect(!first.activity.contains(.turnFinished), "还没有 finish_reason=stop")

    // 同一行补齐：正文加长 + finish_reason=stop（行 id 不变，游标也就没动）
    try execute(
      "UPDATE messages SET content = '写完了，这是完整答复', finish_reason = 'stop' WHERE id = 1;",
      at: database)

    let second = schema.read(sessionId: "s1", cwd: "", state: &state)
    #expect(second.newMessages.isEmpty, "重扫游标行不该冒重复气泡")
    #expect(!second.isNewContent)
    #expect(state.messages.count == 1)
    #expect(state.messages[0].textContent == "写完了，这是完整答复", "气泡内容应原地更新")
    #expect(second.activity == [.turnFinished], "晚到的 stop 在重扫时才上报")

    // 再扫一次：本轮结束已经报过，不重复
    let third = schema.read(sessionId: "s1", cwd: "", state: &state)
    #expect(third.newMessages.isEmpty)
    #expect(third.activity.isEmpty)
    #expect(!third.isNewContent)
  }

  @Test("思考过程与角色分支：reasoning / reasoning_content 产出 .thinking，system 不产气泡")
  func reasoningAndSystemRolls() throws {
    let home = try tempHome()
    defer { remove(home) }
    let database = try makeDatabase(in: home)
    let now = Date().timeIntervalSince1970

    try insertSession(id: "s1", startedAt: now - 600, endedAt: nil, at: database)
    // 1：只有 reasoning
    try insertMessage(
      session: "s1", role: "assistant", timestamp: now - 300, reasoning: "先想 A", at: database)
    // 2：system 行没有用户可见内容
    try insertMessage(
      session: "s1", role: "system", content: "系统提示", timestamp: now - 250, at: database)
    // 3：reasoning 为空时用 reasoning_content
    try insertMessage(
      session: "s1", role: "assistant", timestamp: now - 200, reasoningContent: "再想 B",
      at: database)

    let schema = HermesTranscriptSchema(databaseURL: database)
    var state = TranscriptParseState()
    let result = schema.read(sessionId: "s1", cwd: "", state: &state)

    #expect(result.newMessages.map(\.id) == ["hermes-message-1", "hermes-message-3"])
    #expect(result.newMessages[0].content == [.thinking("先想 A")])
    #expect(result.newMessages[1].content == [.thinking("再想 B")])
    #expect(result.activity.isEmpty, "没有 finish_reason=stop 就没有本轮结束")
    #expect(state.messages.count == 2)
    // 单列 `token_count` 分不出输入/输出：这一支不产出任何 token 数字
    #expect(state.usage == UsageInfo())
  }

  @Test("工具调用：`tool_calls` 解析成工具气泡，`tool` 行按 tool_call_id 配对")
  func toolCallsPairWithResults() throws {
    let home = try tempHome()
    defer { remove(home) }
    let database = try makeDatabase(in: home)
    let now = Date().timeIntervalSince1970

    try insertSession(id: "s1", startedAt: now - 600, endedAt: nil, at: database)
    // 本机实测形状：`arguments` 是 JSON 字符串，`id` 与 `call_id` 同名
    try insertMessage(
      session: "s1", role: "assistant",
      toolCalls: #"""
        [{"id": "call_1", "call_id": "call_1", "type": "function", "function": {"name": "terminal", "arguments": "{\"command\": \"ls -la\", \"timeout\": 15}"}}]
        """#,
      timestamp: now - 120, finishReason: "tool_calls", at: database)
    try insertMessage(
      session: "s1", role: "tool",
      content: #"{"output": "ok", "exit_code": 0, "error": null}"#,
      toolCallId: "call_1", toolName: "terminal", timestamp: now - 100, at: database)

    let schema = HermesTranscriptSchema(databaseURL: database)
    var state = TranscriptParseState()
    let result = schema.read(sessionId: "s1", cwd: "", state: &state)

    #expect(result.newMessages.count == 1, "工具结果行不产出气泡")
    let blocks = result.newMessages.first?.content ?? []
    #expect(blocks.count == 1)
    guard case .toolUse(let tool)? = blocks.first else {
      Issue.record("工具调用应产出 .toolUse 气泡")
      return
    }
    #expect(tool.id == "call_1")
    #expect(tool.name == "terminal")
    #expect(tool.input == ["command": "ls -la", "timeout": "15"])

    #expect(
      state.toolResults["call_1"]?.content == #"{"output": "ok", "exit_code": 0, "error": null}"#)
    #expect(state.toolResults["call_1"]?.isError == false)
    #expect(state.structuredResults["call_1"] != nil, "工具结果也要有结构化形状")
    #expect(state.completedToolIds.contains("call_1"))
    #expect(state.toolInputs["call_1"] == ["command": "ls -la", "timeout": "15"])
    #expect(
      result.activity.contains(.toolFinished(id: "call_1", name: "terminal", isError: false)))
    #expect(!result.activity.contains(.turnFinished), "tool_calls 不是本轮结束")
  }

  @Test("生产接线：注册表 / 发现源 / 记录解析器三处都指向 Hermes")
  func productionWiringIsRegistered() {
    // 本 suite 的库位置是**注入**的（`databaseURL:`），因此「生产路径经 Provider 找到库」这条
    // 接线不会被任何用例走到：少了下面任一行，生产环境会静默退化成「Hermes 永远没有会话」
    // （注册表兜底会回落到 ClaudeAgentProvider，不会报错）。三处注册表都是「漏了不报错」的
    // 那一类，所以必须有这条钉子。
    #expect(AgentRegistry.provider(for: .hermes) is HermesAgentProvider)
    #expect(AgentTranscriptSchemaRegistry.schema(for: .hermes) is HermesTranscriptSchema)
    let discovery = AgentDiscoverySources.source(for: .hermes)
    #expect(discovery is HermesSessionDiscovery)
    #expect(discovery?.kind == .hermes)
  }
}

enum HermesFixtureError: Error, CustomStringConvertible {
  case database(String)

  var description: String {
    switch self {
    case .database(let message): return "Hermes 夹具库失败：\(message)"
    }
  }
}