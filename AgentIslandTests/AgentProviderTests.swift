//
//  AgentProviderTests.swift
//  AgentIslandTests
//
//  记录布局的契约：每个 Provider 在临时 home 下按真实布局造出记录树，钉死四件事：
//    · `paths()` 只在配置根存在时给值（缺根一律 nil），记录 API 在缺根时安全返回；
//    · 目录发现能认出会话，且 `sessionId` / `cwd` 与记录一致；
//    · `isTranscriptFile` 不认别的 Agent 的记录（否则会话会串台）；
//    · `$CODEX_HOME` / `$GROK_HOME` 覆盖（含 `~/` 展开）生效；
//    · 用户在设置面板里指定的配置目录（`AppSettings.agentRootOverride`）优先于自动检测，
//      但被环境变量压过（Claude 例外见 `ClaudePaths`，Cline 例外见 `ClineAgentProvider`）。
//  记录内容只要能解析出 cwd 就够，不追求真实对话。
//
//  `.serialized`：用户指定目录是本进程的偏好（`UserDefaults.standard`），与安装器用例写的是
//  同一个键，串行跑才不会互相看见对方设的值。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("Agent Provider 记录布局", .serialized)
struct AgentProviderTests {
  // MARK: - 夹具

  private func tempHome() throws -> URL {
    // 必须走与应用同一套归一：macOS 的临时目录 `/var/…` 实际是 `/private/var/…`，
    // 而 FileManager 的目录遍历返回的是展开后的路径。夹具用未展开的写法建目录、
    // 断言里拿展开后的路径比较，就会得到「provider 什么都找不到」的假故障。
    // 注意顺序：先建目录再归一——`realpath` 对不存在的路径无效。
    let raw = FileManager.default.temporaryDirectory
      .appendingPathComponent("agent-provider-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    return AgentProviderRoot.canonical(raw)
  }

  @discardableResult
  private func write(_ text: String, to url: URL, modified: Date? = nil) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if let modified {
      try FileManager.default.setAttributes(
        [.modificationDate: modified], ofItemAtPath: url.path)
    }
    return url
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// 发现窗口：夹具都是刚写的，往前一小时必定覆盖。
  private var recentSince: Date { Date().addingTimeInterval(-3600) }

  private func sessions(_ source: any AgentSessionDiscoverySource, limit: Int = 8)
    -> [DiscoveredAgentSession]
  {
    source.recentSessions(since: recentSince, limit: limit)
  }

  /// 全部新增 Agent 的 Provider（临时 home 版）。
  private func newProviders(home: URL) -> [any AgentProvider] {
    [
      CodexAgentProvider(home: home),
      GeminiAgentProvider(home: home),
      CursorAgentProvider(home: home),
      CopilotAgentProvider(home: home),
      ClaudeFamilyAgentProvider(kind: .qoder, home: home),
      ClaudeFamilyAgentProvider(kind: .factory, home: home),
      ClaudeFamilyAgentProvider(kind: .codeBuddy, home: home),
      KimiAgentProvider(home: home),
      ClineAgentProvider(home: home),
      GrokAgentProvider(home: home),
      PlainConfigOnlyAgentProvider(kind: .trae, home: home),
      PlainConfigOnlyAgentProvider(kind: .traeCli, home: home),
      PlainConfigOnlyAgentProvider(kind: .deepSeekHarness, home: home),
    ]
  }

  // MARK: - 注册表与配置根

  @Test("注册表为每个 AgentKind 都注册了 Provider")
  func registryCoversEveryKind() {
    for kind in AgentKind.allCases {
      #expect(AgentRegistry.provider(for: kind).kind == kind, "\(kind.rawValue) 未注册")
    }
  }

  @Test("配置根存在才有 paths()，缺根时为 nil")
  func pathsFollowConfigRoot() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cases: [(provider: any AgentProvider, relativeRoot: String)] = [
      (CodexAgentProvider(home: home), ".codex"),
      (GeminiAgentProvider(home: home), ".gemini"),
      (CursorAgentProvider(home: home), ".cursor"),
      (CopilotAgentProvider(home: home), ".copilot"),
      (ClaudeFamilyAgentProvider(kind: .qoder, home: home), ".qoder"),
      (ClaudeFamilyAgentProvider(kind: .factory, home: home), ".factory"),
      (ClaudeFamilyAgentProvider(kind: .codeBuddy, home: home), ".codebuddy"),
      (KimiAgentProvider(home: home), ".kimi-code"),
      (GrokAgentProvider(home: home), ".grok"),
      (
        ClineAgentProvider(home: home),
        "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
      ),
      (PlainConfigOnlyAgentProvider(kind: .trae, home: home), ".trae"),
      (PlainConfigOnlyAgentProvider(kind: .traeCli, home: home), ".trae"),
      (PlainConfigOnlyAgentProvider(kind: .deepSeekHarness, home: home), ".dsh"),
    ]

    for entry in cases {
      #expect(entry.provider.paths() == nil, "\(entry.provider.kind.rawValue) 缺根时应为 nil")
    }
    for entry in cases {
      try makeDirectory(home.appendingPathComponent(entry.relativeRoot))
    }
    for entry in cases {
      #expect(entry.provider.paths() != nil, "\(entry.provider.kind.rawValue) 根存在时应给路径")
    }
  }

  @Test("根目录缺失时记录 API 不崩且返回空值")
  func missingRootsAreSafe() throws {
    let home = try tempHome()
    defer { remove(home) }

    for provider in newProviders(home: home) {
      let name = provider.kind.rawValue
      #expect(provider.paths() == nil, "\(name) 缺根时应为 nil")
      _ = provider.transcriptFile(sessionId: "sid", cwd: "/Users/tester/none")
      #expect(provider.isTranscriptFile("/tmp/whatever.jsonl") == false, "\(name) 误认任意路径")
      #expect(provider.sessionId(fromTranscriptFile: "/tmp/whatever.jsonl") == nil)
      #expect(try provider.cwd(fromTranscriptFile: "/tmp/whatever.jsonl") == nil)
      #expect(provider.subagentTranscriptFiles(sessionId: "sid", cwd: "/Users/tester/none").isEmpty)
      // 发现源必须基于**这个** provider（临时 home）。注册表里那份绑的是真实 home，
      // 用它扫的是真机目录，夹具根本不在视野里——那样写会得到一条永远为真也永远没用的用例。
      let source = provider as? any AgentSessionDiscoverySource
      #expect(source?.recentSessions(since: recentSince, limit: 5).isEmpty ?? true, "\(name) 缺根仍发现会话")
    }
  }

  // MARK: - Claude fork

  @Test("Qoder / Factory / CodeBuddy：项目目录编码与首行 cwd")
  func claudeFamilyLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/demo"
    let sessionId = "11111111-2222-3333-4444-555555555555"
    let record = #"{"type":"user","sessionId":"\#(sessionId)","cwd":"\#(cwd)"}"#

    let qoder = ClaudeFamilyAgentProvider(kind: .qoder, home: home)
    let factory = ClaudeFamilyAgentProvider(kind: .factory, home: home)
    let codeBuddy = ClaudeFamilyAgentProvider(kind: .codeBuddy, home: home)

    // Qoder：`projects/` + Claude 编码（保留前导短横线）
    try write(record, to: home.appendingPathComponent(".qoder/projects/-Users-tester-work-demo/\(sessionId).jsonl"))
    // Factory：`sessions/` + 同样的编码
    try write(record, to: home.appendingPathComponent(".factory/sessions/-Users-tester-work-demo/\(sessionId).jsonl"))
    // CodeBuddy：`projects/` + 少一个前导短横线的编码
    try write(record, to: home.appendingPathComponent(".codebuddy/projects/Users-tester-work-demo/\(sessionId).jsonl"))

    for provider in [qoder, factory, codeBuddy] as [any AgentProvider] {
      let name = provider.kind.rawValue
      let file = try #require(
        provider.transcriptFile(sessionId: sessionId, cwd: cwd), "\(name) 推不出记录路径")
      #expect(FileManager.default.fileExists(atPath: file.path), "\(name) 记录的落点不对")
      #expect(provider.isTranscriptFile(file.path))
      #expect(provider.sessionId(fromTranscriptFile: file.path) == sessionId)
      #expect(try provider.cwd(fromTranscriptFile: file.path) == cwd)
      #expect(provider.subagentTranscriptFiles(sessionId: sessionId, cwd: cwd).isEmpty)

      let source = try #require(
        provider as? any AgentSessionDiscoverySource, "\(name) 没有发现源实现")
      let found = sessions(source)
      #expect(found.map(\.sessionId) == [sessionId], "\(name) 发现不到会话")
      #expect(found.first?.cwd == cwd)
    }
  }

  // MARK: - Codex / Grok（含环境变量覆盖）

  @Test("Codex：日期目录 + 文件名 uuid + 首行 session_meta.cwd，$CODEX_HOME 生效")
  func codexLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let uuid = "019d0a9e-a27a-7651-bc6d-1c6f5f90e358"
    let cwd = "/Users/tester/work/codex"
    let file = try write(
      #"{"timestamp":"2026-09-22T10:11:12.000Z","type":"session_meta","payload":{"id":"\#(uuid)","cwd":"\#(cwd)"}}"#,
      to: home.appendingPathComponent(".codex/sessions/2026/09/22/rollout-2026-09-22T10-11-12-\(uuid).jsonl"))

    let provider = CodexAgentProvider(home: home)
    #expect(provider.isTranscriptFile(file.path))
    #expect(provider.sessionId(fromTranscriptFile: file.path) == uuid)
    #expect(try provider.cwd(fromTranscriptFile: file.path) == cwd)
    let found = sessions(provider)   // 直接驱动这个临时 home 的 provider，不走绑真实 home 的注册表实例
    #expect(found.map(\.sessionId) == [uuid])
    #expect(found.first?.cwd == cwd)
    #expect(found.first?.transcriptPath == file.path)

    // `$CODEX_HOME` 覆盖（含 `~/` 展开）
    let overridden = CodexAgentProvider(home: home, environment: ["CODEX_HOME": "~/custom-codex"])
    #expect(overridden.paths() == nil, "覆盖根不存在时不应给 paths()")
    try makeDirectory(home.appendingPathComponent("custom-codex/sessions"))
    #expect(overridden.paths()?.configDir.path == home.appendingPathComponent("custom-codex").path)
    #expect(overridden.isTranscriptFile(file.path) == false, "覆盖根之外的文件不属于它")
    #expect(overridden.transcriptFile(sessionId: uuid, cwd: cwd) == nil)

    // 空白值视作未设置
    let blank = CodexAgentProvider(home: home, environment: ["CODEX_HOME": "   "])
    #expect(blank.paths()?.configDir.path == home.appendingPathComponent(".codex").path)
  }

  @Test("Grok：百分号编码的项目目录 + summary.json，$GROK_HOME 生效")
  func grokLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/grok"
    let sessionId = "grok-session-1"
    let encoded = try #require(GrokAgentProvider.encodedCwd(cwd))
    #expect(encoded.contains("%2F"), "`/` 应被编码成 %2F")
    let directory = home.appendingPathComponent(".grok/sessions/\(encoded)/\(sessionId)")
    try write(#"{"type":1}"#, to: directory.appendingPathComponent("chat_history.jsonl"))
    try write(
      #"{"info":{"id":"\#(sessionId)","cwd":"\#(cwd)"}}"#,
      to: directory.appendingPathComponent("summary.json"))

    let provider = GrokAgentProvider(home: home)
    let file = try #require(provider.transcriptFile(sessionId: sessionId, cwd: cwd))
    #expect(provider.isTranscriptFile(file.path))
    #expect(provider.sessionId(fromTranscriptFile: file.path) == sessionId)
    #expect(try provider.cwd(fromTranscriptFile: file.path) == cwd)
    let found = sessions(provider)
    #expect(found.map(\.sessionId) == [sessionId])
    #expect(found.first?.cwd == cwd)

    // `$GROK_HOME` 覆盖（含 `~/` 展开）
    let overrideHome = GrokAgentProvider(home: home, environment: ["GROK_HOME": "~/grok-alt"])
    #expect(overrideHome.paths() == nil)
    try makeDirectory(home.appendingPathComponent("grok-alt/sessions"))
    #expect(overrideHome.paths()?.configDir.path == home.appendingPathComponent("grok-alt").path)
    #expect(overrideHome.isTranscriptFile(file.path) == false)

    // 绝对路径覆盖
    let absolute = GrokAgentProvider(home: home, environment: ["GROK_HOME": home.path])
    #expect(absolute.paths()?.configDir.path == home.path)
  }

  // MARK: - Gemini / Cursor / Copilot

  @Test("Gemini：projects.json 映射 + 首行 sessionId（文件名里的 id 是截断的）")
  func geminiLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    // 本机真实形状：文件名里的 id 被截断到 8 字符，且被截断的 id 自己就含短横线
    // （`session-2026-06-03T07-46-a2a-serv.jsonl` ↔ `"sessionId":"a2a-server"`）。
    let cwd = "/Users/tester/work/gemini"
    let sessionId = "a2a-server"
    try write(
      #"{"sessionId":"\#(sessionId)","projectHash":"abc123"}"#,
      to: home.appendingPathComponent(".gemini/tmp/abc123/chats/session-2026-06-03T07-46-a2a-serv.jsonl"))
    try write(#"{"projects":{"\#(cwd)":"abc123"}}"#, to: home.appendingPathComponent(".gemini/projects.json"))

    let provider = GeminiAgentProvider(home: home)
    let file = try #require(provider.transcriptFile(sessionId: sessionId, cwd: cwd))
    #expect(provider.isTranscriptFile(file.path))
    #expect(provider.sessionId(fromTranscriptFile: file.path) == sessionId, "会话 id 应取首行")
    #expect(try provider.cwd(fromTranscriptFile: file.path) == cwd)

    let source: any AgentSessionDiscoverySource = provider
    let found = sessions(source)
    #expect(found.map(\.sessionId) == [sessionId])
    #expect(found.first?.cwd == cwd)

    // 旧版 Gemini 的整文档 `.json` 不认（格式不同，宁可整个忽略）
    let legacyDocument = home.appendingPathComponent(
      ".gemini/tmp/abc123/chats/session-2026-05-01T00-00-9f3c1d20.json")
    try write(#"{"sessionId":"legacy-document"}"#, to: legacyDocument)
    #expect(provider.isTranscriptFile(legacyDocument.path) == false)
    #expect(provider.sessionId(fromTranscriptFile: legacyDocument.path) == nil)

    // 映射表缺失时用 `<项目目录>/.project_root`
    let markerCwd = "/Users/tester/work/gemini-marker"
    try write(
      #"{"sessionId":"marker-session"}"#,
      to: home.appendingPathComponent(".gemini/tmp/def456/chats/session-2026-09-22T11-00-marker.jsonl"))
    try write(markerCwd + "\n", to: home.appendingPathComponent(".gemini/tmp/def456/.project_root"))
    let withMarker = sessions(source)
    #expect(withMarker.count == 2)
    #expect(Set(withMarker.map(\.cwd)) == Set([cwd, markerCwd]))

    // 映射表过期（指向一个不存在的目录）时仍要能找回记录：先查映射目录、没命中才遍历
    let staleCwd = "/Users/tester/work/gemini-stale"
    let staleSessionId = "stale-session"
    try write(
      #"{"sessionId":"\#(staleSessionId)"}"#,
      to: home.appendingPathComponent(
        ".gemini/tmp/stale123/chats/session-2026-09-22T12-00-stale.jsonl"))
    try write(
      #"{"projects":{"\#(cwd)":"abc123","\#(staleCwd)":"gone-dir"}}"#,
      to: home.appendingPathComponent(".gemini/projects.json"))
    let staleFile = try #require(provider.transcriptFile(sessionId: staleSessionId, cwd: staleCwd))
    #expect(staleFile.path.contains("/stale123/"), "映射过期时应靠遍历兜底找回记录")
  }

  @Test("Cursor：无前导短横线的项目编码 + agent-transcripts 与 subagents")
  func cursorLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/cursor"
    let parentId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let childId = "ffffffff-0000-1111-2222-333333333333"
    let transcripts = home.appendingPathComponent(
      ".cursor/projects/Users-tester-work-cursor/agent-transcripts")
    let parentFile = try write(
      #"{"role":"user","message":{"content":"hi"}}"#,
      to: transcripts.appendingPathComponent("\(parentId)/\(parentId).jsonl"))
    let childFile = try write(
      #"{"role":"assistant","message":{"content":"hi"}}"#,
      to: transcripts.appendingPathComponent("\(parentId)/subagents/\(childId).jsonl"))

    let provider = CursorAgentProvider(home: home)
    #expect(provider.isTranscriptFile(parentFile.path))
    #expect(provider.sessionId(fromTranscriptFile: parentFile.path) == parentId)
    #expect(try provider.cwd(fromTranscriptFile: parentFile.path) == cwd)
    #expect(provider.transcriptFile(sessionId: parentId, cwd: cwd) == parentFile)
    #expect(provider.transcriptFile(sessionId: childId, cwd: cwd) == childFile, "子会话要能找回")
    #expect(provider.subagentTranscriptFiles(sessionId: parentId, cwd: cwd) == [childFile])

    // 只发现父会话：`subagents/` 下的是派生记录
    let found = sessions(provider)
    #expect(found.map(\.sessionId) == [parentId])
    #expect(found.first?.cwd == cwd)
  }

  @Test("Copilot：jb 分区记录（取最新一份、按会话去重）+ 旧布局 events.jsonl")
  func copilotLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/copilot"
    let sessionId = "3f0d1a5e-1111-2222-3333-444444444444"
    let now = Date()
    try write(
      #"{"type":"user.message","data":{"content":"hi"}}"#,
      to: home.appendingPathComponent(".copilot/jb/\(sessionId)/partition-1.jsonl"),
      modified: now.addingTimeInterval(-600))
    let newest = try write(
      #"{"type":"assistant.message","data":{"content":"hi"}}"#,
      to: home.appendingPathComponent(".copilot/jb/\(sessionId)/partition-2.jsonl"),
      modified: now)
    // 当前版本的 jb 分区里没有 cwd，工作目录写在 session-state 的 workspace.yaml
    try write(
      "id: \(sessionId)\ncwd: \(cwd)\n",
      to: home.appendingPathComponent(".copilot/session-state/\(sessionId)/workspace.yaml"))

    let provider = CopilotAgentProvider(home: home)
    #expect(provider.recordsRoots.count == 2)
    #expect(provider.transcriptFile(sessionId: sessionId, cwd: cwd) == newest, "应取最新分区")
    #expect(provider.sessionId(fromTranscriptFile: newest.path) == sessionId)
    #expect(try provider.cwd(fromTranscriptFile: newest.path) == cwd)

    let source: any AgentSessionDiscoverySource = provider
    let found = sessions(source)
    #expect(found.count == 1, "同一会话的两个分区应去重")
    #expect(found.first?.sessionId == sessionId)
    #expect(found.first?.cwd == cwd)
    #expect(found.first?.transcriptPath == newest.path)

    // 旧布局：`session-state/<会话 id>/events.jsonl` 的 session.start 事件
    let legacyCwd = "/Users/tester/work/copilot-legacy"
    let legacyId = "5a5a5a5a-6666-7777-8888-999999999999"
    try write(
      #"{"type":"session.start","data":{"context":{"cwd":"\#(legacyCwd)"}}}"#,
      to: home.appendingPathComponent(".copilot/session-state/\(legacyId)/events.jsonl"))
    let legacyFound = sessions(source)
    #expect(Set(legacyFound.map(\.cwd)) == Set([cwd, legacyCwd]))
    #expect(Set(legacyFound.map(\.sessionId)) == Set([sessionId, legacyId]))
  }

  // MARK: - Kimi / Cline

  @Test("Kimi：kimi-code 索引给出会话与 cwd；旧版 md5 目录只认会话 id")
  func kimiLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/kimi"
    let sessionId = "kimi-session-1"
    let sessionDir = home.appendingPathComponent(".kimi-code/sessions/\(sessionId)")
    try write(
      #"{"type":"turn.prompt","input":[{"type":"text","text":"hi"}]}"#,
      to: sessionDir.appendingPathComponent("agents/main/wire.jsonl"))
    try write(#"{"status":"running"}"#, to: sessionDir.appendingPathComponent("state.json"))
    try write(
      #"{"sessionId":"\#(sessionId)","sessionDir":"\#(sessionDir.path)","workDir":"\#(cwd)"}"#,
      to: home.appendingPathComponent(".kimi-code/session_index.jsonl"))

    let provider = KimiAgentProvider(home: home)
    let file = try #require(provider.transcriptFile(sessionId: sessionId, cwd: cwd))
    #expect(file.path.hasSuffix("agents/main/wire.jsonl"))
    #expect(provider.isTranscriptFile(file.path))
    #expect(provider.sessionId(fromTranscriptFile: file.path) == sessionId)
    #expect(try provider.cwd(fromTranscriptFile: file.path) == cwd)
    let found = sessions(provider)
    #expect(found.map(\.sessionId) == [sessionId])
    #expect(found.first?.cwd == cwd)

    // 旧版：`~/.kimi/sessions/<md5(cwd)>/<会话 id>/wire.jsonl`
    let legacy = try write(
      #"{"message":{"type":"TurnBegin","payload":{"user_input":[{"type":"text","text":"hi"}]}}}"#,
      to: home.appendingPathComponent(".kimi/sessions/\(KimiAgentProvider.workdirHash(for: cwd))/legacy-1/wire.jsonl"))
    #expect(provider.isTranscriptFile(legacy.path))
    #expect(provider.sessionId(fromTranscriptFile: legacy.path) == "legacy-1")
    #expect(try provider.cwd(fromTranscriptFile: legacy.path) == nil, "md5 目录无法反推 cwd")
  }

  @Test("Kimi：索引按文件指纹失效（追加会话后能被发现）")
  func kimiIndexCacheInvalidation() throws {
    let home = try tempHome()
    defer { remove(home) }

    let firstCwd = "/Users/tester/work/kimi-a"
    let firstDir = home.appendingPathComponent(".kimi-code/sessions/sid-a")
    try write("{}\n", to: firstDir.appendingPathComponent("agents/main/wire.jsonl"))
    let indexFile = home.appendingPathComponent(".kimi-code/session_index.jsonl")
    let firstLine =
      #"{"sessionId":"sid-a","sessionDir":"\#(firstDir.path)","workDir":"\#(firstCwd)"}"#
    try write(firstLine + "\n", to: indexFile)

    let provider = KimiAgentProvider(home: home)
    #expect(sessions(provider).map(\.sessionId) == ["sid-a"])
    #expect(
      try provider.cwd(fromTranscriptFile: firstDir.appendingPathComponent("agents/main/wire.jsonl").path)
        == firstCwd, "索引命中时 cwd 应解析出来（缓存不能把首次结果吃掉）")

    // 追加一条会话：索引变了，缓存必须失效，否则新会话永远发现不到
    let secondCwd = "/Users/tester/work/kimi-b"
    let secondDir = home.appendingPathComponent(".kimi-code/sessions/sid-b")
    try write("{}\n", to: secondDir.appendingPathComponent("agents/main/wire.jsonl"))
    let secondLine =
      #"{"sessionId":"sid-b","sessionDir":"\#(secondDir.path)","workDir":"\#(secondCwd)"}"#
    try write(firstLine + "\n" + secondLine + "\n", to: indexFile)

    #expect(Set(sessions(provider).map(\.sessionId)) == Set(["sid-a", "sid-b"]))
  }

  @Test("Kimi：只有旧版根时也能解析")
  func kimiLegacyRootOnly() throws {
    let home = try tempHome()
    defer { remove(home) }

    try makeDirectory(home.appendingPathComponent(".kimi/sessions"))
    let provider = KimiAgentProvider(home: home)
    #expect(provider.paths()?.configDir.path == home.appendingPathComponent(".kimi").path)
    #expect(provider.paths()?.sessionsDir?.path == home.appendingPathComponent(".kimi/sessions").path)
  }

  @Test("Cline：taskHistory 索引 + tasks/<任务 id> 对话文件")
  func clineLayout() throws {
    let home = try tempHome()
    defer { remove(home) }

    let root = home.appendingPathComponent(
      "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev")
    let taskId = "1758000000000"
    let cwd = "/Users/tester/work/cline"
    let conversation = try write(
      #"[{"role":"user","content":"hi"}]"#,
      to: root.appendingPathComponent("tasks/\(taskId)/api_conversation_history.json"))
    try write(
      #"[{"id":"\#(taskId)","ts":1758000000000,"cwdOnTaskInitialization":"\#(cwd)","modelId":"gpt"}]"#,
      to: root.appendingPathComponent("state/taskHistory.json"))

    let provider = ClineAgentProvider(home: home)
    #expect(provider.transcriptFile(sessionId: taskId, cwd: cwd) == conversation)
    #expect(provider.isTranscriptFile(conversation.path))
    #expect(provider.sessionId(fromTranscriptFile: conversation.path) == taskId)
    #expect(try provider.cwd(fromTranscriptFile: conversation.path) == cwd)
    let found = sessions(provider)
    #expect(found.map(\.sessionId) == [taskId])
    #expect(found.first?.cwd == cwd)
  }

  // MARK: - 隔离与无记录 Agent

  @Test("各 Agent 只认自己的记录；Trae / Trae CLI / DSH 没有记录发现源")
  func crossAgentIsolation() throws {
    let home = try tempHome()
    defer { remove(home) }

    let uuid = "019d0a9e-a27a-7651-bc6d-1c6f5f90e358"
    let cases: [(provider: any AgentProvider, ownPath: String)] = [
      (
        CodexAgentProvider(home: home),
        home.appendingPathComponent(".codex/sessions/2026/09/22/rollout-2026-09-22T10-11-12-\(uuid).jsonl").path
      ),
      (
        GeminiAgentProvider(home: home),
        home.appendingPathComponent(".gemini/tmp/abc123/chats/session-2026-09-22T10-11-9f3c1d20.jsonl").path
      ),
      (
        CursorAgentProvider(home: home),
        home.appendingPathComponent(".cursor/projects/Users-tester-work-cursor/agent-transcripts/\(uuid)/\(uuid).jsonl").path
      ),
      (
        CopilotAgentProvider(home: home),
        home.appendingPathComponent(".copilot/jb/\(uuid)/partition-1.jsonl").path
      ),
      (
        ClaudeFamilyAgentProvider(kind: .qoder, home: home),
        home.appendingPathComponent(".qoder/projects/-Users-tester-work/s.jsonl").path
      ),
      (
        ClaudeFamilyAgentProvider(kind: .factory, home: home),
        home.appendingPathComponent(".factory/sessions/-Users-tester-work/s.jsonl").path
      ),
      (
        ClaudeFamilyAgentProvider(kind: .codeBuddy, home: home),
        home.appendingPathComponent(".codebuddy/projects/Users-tester-work/s.jsonl").path
      ),
      (
        KimiAgentProvider(home: home),
        home.appendingPathComponent(".kimi-code/sessions/sid/agents/main/wire.jsonl").path
      ),
      (
        ClineAgentProvider(home: home),
        home.appendingPathComponent(
          "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/1/api_conversation_history.json"
        ).path
      ),
      (
        GrokAgentProvider(home: home),
        home.appendingPathComponent(".grok/sessions/%2FUsers%2Ftester/sid/chat_history.jsonl").path
      ),
    ]

    for entry in cases {
      let own = entry.provider.kind.rawValue
      #expect(entry.provider.isTranscriptFile(entry.ownPath), "\(own) 应认得自己的记录")
      for other in cases where other.provider.kind != entry.provider.kind {
        #expect(
          !entry.provider.isTranscriptFile(other.ownPath),
          "\(own) 不应认 \(other.provider.kind.rawValue) 的记录")
      }
    }

    // 注册表的发现源映射：只有 Trae / Trae CLI / DSH 没有可解析记录，其余都必须有源。
    // 上面几个用例直接驱动临时 home 的 provider，这条负责把「注册表有没有登记」也钉住。
    let kindsWithoutRecords: Set<AgentKind> = [.trae, .traeCli, .deepSeekHarness]
    for kind in AgentKind.allCases {
      #expect(
        (AgentDiscoverySources.source(for: kind) != nil) == !kindsWithoutRecords.contains(kind),
        "\(kind.rawValue) 的发现源注册与实际记录能力不一致")
    }
    let plain = PlainConfigOnlyAgentProvider(kind: .trae, home: home)
    try makeDirectory(home.appendingPathComponent(".trae"))
    #expect(plain.paths()?.configDir.path == home.appendingPathComponent(".trae").path)
    #expect(plain.transcriptFile(sessionId: "sid", cwd: "/Users/tester/work") == nil)
    #expect(plain.isTranscriptFile(cases[0].ownPath) == false)
    #expect(plain.sessionId(fromTranscriptFile: cases[0].ownPath) == nil)
    #expect(try plain.cwd(fromTranscriptFile: cases[0].ownPath) == nil)
    #expect(plain.subagentTranscriptFiles(sessionId: "sid", cwd: "/Users/tester/work").isEmpty)
  }

  // MARK: - 用户指定目录（设置面板里的目录选择器）

  /// 注入「用户指定目录」——设置面板写的是同一个键（进程级偏好），用完必须复原。
  private func withRootOverride(_ kind: AgentKind, _ path: String, _ body: () throws -> Void)
    throws
  {
    let previous = AppSettings.agentRootOverride(kind)
    AppSettings.setAgentRootOverride(kind, path: path)
    defer { AppSettings.setAgentRootOverride(kind, path: previous) }
    try body()
  }

  @Test("指定目录：`~` 展开、绝对路径归一，空白视作未设置")
  func userOverridePathResolution() throws {
    let home = try tempHome()
    defer { remove(home) }

    let realHome = AgentProviderRoot.canonical(FileManager.default.homeDirectoryForCurrentUser)
    try withRootOverride(.gemini, "~/agent-island-override-check") {
      #expect(
        AgentRootOverride.userOverride(for: .gemini)?.path
          == realHome.appendingPathComponent("agent-island-override-check").path,
        "`~/…` 应展开到当前用户主目录")
    }
    // 空白/空串：视作没有指定（设置面板的「恢复自动检测」写的就是空串）
    try withRootOverride(.gemini, "   ") {
      #expect(AgentRootOverride.userOverride(for: .gemini) == nil)
    }
    try withRootOverride(.gemini, home.path) {
      #expect(AgentRootOverride.userOverride(for: .gemini)?.path == home.path)
    }
  }

  @Test("指定目录：claude 家族（qoder / factory）的配置根与记录都指向它")
  func rootOverrideMovesClaudeFamily() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/demo"
    let sessionId = "11111111-2222-3333-4444-555555555555"
    let record = #"{"type":"user","sessionId":"\#(sessionId)","cwd":"\#(cwd)"}"#

    for (kind, recordsDir) in [(AgentKind.qoder, "projects"), (.factory, "sessions")] {
      let override = home.appendingPathComponent("custom-\(kind.rawValue)")
      let file = try write(
        record,
        to: override.appendingPathComponent(
          "\(recordsDir)/-Users-tester-work-demo/\(sessionId).jsonl"))
      let provider = ClaudeFamilyAgentProvider(kind: kind, home: home)

      try withRootOverride(kind, override.path) {
        let name = kind.rawValue
        #expect(provider.paths()?.configDir.path == override.path, "\(name) 配置根未指向指定目录")
        #expect(
          provider.paths()?.sessionsDir?.path
            == override.appendingPathComponent(recordsDir).path)
        #expect(provider.transcriptFile(sessionId: sessionId, cwd: cwd) == file)
        #expect(provider.isTranscriptFile(file.path))
        let recordCwd = try provider.cwd(fromTranscriptFile: file.path)
        #expect(recordCwd == cwd)
        #expect(
          provider.isTranscriptFile(
            home.appendingPathComponent("elsewhere/\(sessionId).jsonl").path) == false,
          "\(name) 不应认指定目录之外的记录")

        #expect(sessions(provider).map(\.sessionId) == [sessionId], "\(name) 发现不到指定目录里的会话")
      }
    }
  }

  @Test("指定目录：codex 的记录根与发现都指向它")
  func rootOverrideMovesCodex() throws {
    let home = try tempHome()
    defer { remove(home) }

    let uuid = "019d0a9e-a27a-7651-bc6d-1c6f5f90e358"
    let cwd = "/Users/tester/work/codex"
    let override = home.appendingPathComponent("custom-codex")
    let file = try write(
      #"{"timestamp":"2026-09-22T10:11:12.000Z","type":"session_meta","payload":{"id":"\#(uuid)","cwd":"\#(cwd)"}}"#,
      to: override.appendingPathComponent(
        "sessions/2026/09/22/rollout-2026-09-22T10-11-12-\(uuid).jsonl"))

    let provider = CodexAgentProvider(home: home)
    try withRootOverride(.codex, override.path) {
      #expect(provider.paths()?.configDir.path == override.path)
      #expect(
        provider.paths()?.sessionsDir?.path
          == override.appendingPathComponent("sessions").path)
      #expect(provider.isTranscriptFile(file.path))
      #expect(provider.transcriptFile(sessionId: uuid, cwd: cwd) == file)
      let recordCwd = try provider.cwd(fromTranscriptFile: file.path)
      #expect(recordCwd == cwd)
      let found = sessions(provider)
      #expect(found.map(\.sessionId) == [uuid])
      #expect(found.first?.transcriptPath == file.path)
      #expect(
        provider.isTranscriptFile(
          home.appendingPathComponent(".codex/sessions/2026/09/22/rollout-x-\(uuid).jsonl").path)
          == false, "默认根下的记录不再属于它")
    }
  }

  @Test("指定目录：gemini 的配置根与记录都指向它")
  func rootOverrideMovesGemini() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/gemini"
    let sessionId = "a2a-server"
    let override = home.appendingPathComponent("custom-gemini")
    try write(
      #"{"sessionId":"\#(sessionId)","projectHash":"abc123"}"#,
      to: override.appendingPathComponent(
        "tmp/abc123/chats/session-2026-06-03T07-46-a2a-serv.jsonl"))
    try write(
      #"{"projects":{"\#(cwd)":"abc123"}}"#, to: override.appendingPathComponent("projects.json"))

    let provider = GeminiAgentProvider(home: home)
    try withRootOverride(.gemini, override.path) {
      #expect(provider.paths()?.configDir.path == override.path)
      #expect(provider.paths()?.sessionsDir?.path == override.appendingPathComponent("tmp").path)
      let file = try #require(provider.transcriptFile(sessionId: sessionId, cwd: cwd))
      #expect(file.path.hasPrefix(override.path + "/"))
      #expect(provider.isTranscriptFile(file.path))
      #expect(sessions(provider).map(\.sessionId) == [sessionId])
      #expect(
        provider.isTranscriptFile(
          home.appendingPathComponent(".gemini/tmp/abc123/chats/session-x.jsonl").path) == false)
    }
  }

  @Test("指定目录：cursor 的记录根与发现都指向它")
  func rootOverrideMovesCursor() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/cursor"
    let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let override = home.appendingPathComponent("custom-cursor")
    let file = try write(
      #"{"role":"user","message":{"content":"hi"}}"#,
      to: override.appendingPathComponent(
        "projects/Users-tester-work-cursor/agent-transcripts/\(sessionId)/\(sessionId).jsonl"))

    let provider = CursorAgentProvider(home: home)
    try withRootOverride(.cursor, override.path) {
      #expect(provider.paths()?.configDir.path == override.path)
      #expect(
        provider.paths()?.sessionsDir?.path
          == override.appendingPathComponent("projects").path)
      #expect(provider.transcriptFile(sessionId: sessionId, cwd: cwd) == file)
      #expect(provider.sessionId(fromTranscriptFile: file.path) == sessionId)
      let recordCwd = try provider.cwd(fromTranscriptFile: file.path)
      #expect(recordCwd == cwd)
      #expect(sessions(provider).map(\.sessionId) == [sessionId])
    }
  }

  @Test("指定目录：copilot 的两代记录根都指向它")
  func rootOverrideMovesCopilot() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/copilot"
    let sessionId = "3f0d1a5e-1111-2222-3333-444444444444"
    let override = home.appendingPathComponent("custom-copilot")
    let file = try write(
      #"{"type":"assistant.message","data":{"content":"hi"}}"#,
      to: override.appendingPathComponent("jb/\(sessionId)/partition-1.jsonl"))
    try write(
      "id: \(sessionId)\ncwd: \(cwd)\n",
      to: override.appendingPathComponent("session-state/\(sessionId)/workspace.yaml"))

    let provider = CopilotAgentProvider(home: home)
    try withRootOverride(.copilot, override.path) {
      #expect(provider.paths()?.configDir.path == override.path)
      #expect(provider.transcriptFile(sessionId: sessionId, cwd: cwd) == file)
      #expect(provider.isTranscriptFile(file.path))
      let recordCwd = try provider.cwd(fromTranscriptFile: file.path)
      #expect(recordCwd == cwd)
      #expect(sessions(provider).map(\.sessionId) == [sessionId])
    }
  }

  @Test("指定目录：grok 的记录根与发现都指向它")
  func rootOverrideMovesGrok() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/grok"
    let sessionId = "grok-session-1"
    let encoded = try #require(GrokAgentProvider.encodedCwd(cwd))
    let override = home.appendingPathComponent("custom-grok")
    let directory = override.appendingPathComponent("sessions/\(encoded)/\(sessionId)")
    try write(#"{"type":1}"#, to: directory.appendingPathComponent("chat_history.jsonl"))
    try write(
      #"{"info":{"id":"\#(sessionId)","cwd":"\#(cwd)"}}"#,
      to: directory.appendingPathComponent("summary.json"))

    let provider = GrokAgentProvider(home: home)
    try withRootOverride(.grok, override.path) {
      #expect(provider.paths()?.configDir.path == override.path)
      let file = try #require(provider.transcriptFile(sessionId: sessionId, cwd: cwd))
      #expect(provider.isTranscriptFile(file.path))
      #expect(provider.sessionId(fromTranscriptFile: file.path) == sessionId)
      let recordCwd = try provider.cwd(fromTranscriptFile: file.path)
      #expect(recordCwd == cwd)
      #expect(sessions(provider).map(\.sessionId) == [sessionId])
    }
  }

  @Test("指定目录：omp / pi 的 agent 目录与会话根都指向它")
  func rootOverrideMovesPiFamily() throws {
    let home = try tempHome()
    defer { remove(home) }

    let cwd = "/Users/tester/work/omp"
    let sessionId = "aaaaaaaa-1111-2222-3333-444444444444"

    for kind in [AgentKind.ohMyPi, .pi] {
      let override = home.appendingPathComponent("custom-\(kind.rawValue)/agent")
      // 随便放一个分桶目录：会话 id 唯一，兜底遍历也能找回记录
      let file = try write(
        #"{"type":"session","cwd":"\#(cwd)"}"#,
        to: override.appendingPathComponent(
          "sessions/misc/2026-09-22T10-11-12_\(sessionId).jsonl"))
      let provider = PiFamilyAgentProvider(kind: kind)

      try withRootOverride(kind, override.path) {
        #expect(provider.paths()?.configDir.path == override.path, "\(kind.rawValue) agent 目录不对")
        #expect(
          provider.paths()?.sessionsDir?.path
            == override.appendingPathComponent("sessions").path)
        #expect(provider.transcriptFile(sessionId: sessionId, cwd: cwd) == file)
        #expect(sessions(provider).map(\.sessionId) == [sessionId])
      }
    }
  }

  @Test("指定目录：opencode 的数据根指向它")
  func rootOverrideMovesOpenCode() throws {
    let home = try tempHome()
    defer { remove(home) }

    let override = home.appendingPathComponent("custom-opencode")
    try write("", to: override.appendingPathComponent("opencode.db"))

    let provider = OpenCodeAgentProvider()
    try withRootOverride(.opencode, override.path) {
      #expect(provider.paths()?.dataDir?.path == override.path)
      #expect(provider.databaseFile?.path == override.appendingPathComponent("opencode.db").path)
    }
  }

  @Test("指定目录：trae / traecli / dsh 只换配置根（没有可解析的记录）")
  func rootOverrideMovesPlainConfigOnly() throws {
    let home = try tempHome()
    defer { remove(home) }

    let providers: [any AgentProvider] = [
      PlainConfigOnlyAgentProvider(kind: .trae, home: home),
      PlainConfigOnlyAgentProvider(kind: .traeCli, home: home),
      PlainConfigOnlyAgentProvider(kind: .deepSeekHarness, home: home),
    ]

    for provider in providers {
      let override = home.appendingPathComponent("custom-\(provider.kind.rawValue)")
      try makeDirectory(override)
      try withRootOverride(provider.kind, override.path) {
        #expect(provider.paths()?.configDir.path == override.path)
        #expect(provider.transcriptFile(sessionId: "sid", cwd: "/Users/tester/work") == nil)
      }
    }
  }

  @Test("指定目录：Cline 是例外，记录仍在 VSCode 的 globalStorage 里")
  func rootOverrideLeavesClineRecordsAlone() throws {
    let home = try tempHome()
    defer { remove(home) }

    let root = home.appendingPathComponent(
      "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev")
    let taskId = "1758000000000"
    let cwd = "/Users/tester/work/cline"
    let conversation = try write(
      #"[{"role":"user","content":"hi"}]"#,
      to: root.appendingPathComponent("tasks/\(taskId)/api_conversation_history.json"))
    try write(
      #"[{"id":"\#(taskId)","ts":1758000000000,"cwdOnTaskInitialization":"\#(cwd)"}]"#,
      to: root.appendingPathComponent("state/taskHistory.json"))

    let override = home.appendingPathComponent("custom-cline")
    try makeDirectory(override)

    let provider = ClineAgentProvider(home: home)
    try withRootOverride(.cline, override.path) {
      // 指定目录是 Cline 自己的根（安装器写 hook 的落点），与记录路径无关
      #expect(provider.paths()?.configDir.path == root.path)
      #expect(provider.transcriptFile(sessionId: taskId, cwd: cwd) == conversation)
      #expect(provider.isTranscriptFile(conversation.path))
      let recordCwd = try provider.cwd(fromTranscriptFile: conversation.path)
      #expect(recordCwd == cwd)
      #expect(sessions(provider).map(\.sessionId) == [taskId])
    }
  }

  @Test("指定目录：kimi 钉死数据根（跳过现代 / 旧版择优）")
  func rootOverridePinsKimiRoot() throws {
    let home = try tempHome()
    defer { remove(home) }

    // 现代根（~/.kimi-code）与旧版根（~/.kimi）都在，且各有记录
    let modernCwd = "/Users/tester/work/kimi-modern"
    let modernDir = home.appendingPathComponent(".kimi-code/sessions/modern")
    try write("{}\n", to: modernDir.appendingPathComponent("agents/main/wire.jsonl"))
    try write(
      #"{"sessionId":"modern","sessionDir":"\#(modernDir.path)","workDir":"\#(modernCwd)"}"#,
      to: home.appendingPathComponent(".kimi-code/session_index.jsonl"))
    let legacyCwd = "/Users/tester/work/kimi-legacy"
    let legacyFile = home.appendingPathComponent(
      ".kimi/sessions/\(KimiAgentProvider.workdirHash(for: legacyCwd))/legacy/wire.jsonl")
    try write("{}\n", to: legacyFile)

    // 用户指定的数据根（索引与记录都在它下面）
    let override = home.appendingPathComponent("custom-kimi")
    let pinnedDir = override.appendingPathComponent("sessions/pinned")
    try write("{}\n", to: pinnedDir.appendingPathComponent("agents/main/wire.jsonl"))
    try write(
      #"{"sessionId":"pinned","sessionDir":"\#(pinnedDir.path)","workDir":"\#(override.path)"}"#,
      to: override.appendingPathComponent("session_index.jsonl"))

    let provider = KimiAgentProvider(home: home)
    // 没指定目录：现代根优先
    #expect(provider.paths()?.configDir.path == home.appendingPathComponent(".kimi-code").path)

    try withRootOverride(.kimi, override.path) {
      #expect(provider.paths()?.configDir.path == override.path, "指定目录应钉死数据根")
      #expect(
        provider.paths()?.sessionsDir?.path == override.appendingPathComponent("sessions").path)
      #expect(sessions(provider).map(\.sessionId) == ["pinned"], "指定目录下不该再看别的根")
      #expect(provider.isTranscriptFile(legacyFile.path) == false)
      #expect(
        provider.isTranscriptFile(
          home.appendingPathComponent(".kimi-code/sessions/modern/agents/main/wire.jsonl").path)
          == false)
    }
  }

  @Test("指定目录不存在：paths() 为 nil、记录 API 安全、安装器跳过")
  func missingRootOverrideIsSafe() throws {
    let home = try tempHome()
    defer { remove(home) }

    // `paths()` 带存在性闸门的 Provider：指定目录不存在 ⇒ nil（记录 API 也必须安全）。
    let gated: [(kind: AgentKind, provider: any AgentProvider)] = [
      (.codex, CodexAgentProvider(home: home)),
      (.gemini, GeminiAgentProvider(home: home)),
      (.cursor, CursorAgentProvider(home: home)),
      (.copilot, CopilotAgentProvider(home: home)),
      (.qoder, ClaudeFamilyAgentProvider(kind: .qoder, home: home)),
      (.kimi, KimiAgentProvider(home: home)),
      (.grok, GrokAgentProvider(home: home)),
      (.trae, PlainConfigOnlyAgentProvider(kind: .trae, home: home)),
      (.deepSeekHarness, PlainConfigOnlyAgentProvider(kind: .deepSeekHarness, home: home)),
      (.opencode, OpenCodeAgentProvider()),
    ]

    let missing = home.appendingPathComponent("nowhere")
    for entry in gated {
      try withRootOverride(entry.kind, missing.path) {
        let name = entry.kind.rawValue
        #expect(entry.provider.paths() == nil, "\(name) 指定目录不存在时应为 nil")
        _ = entry.provider.transcriptFile(sessionId: "sid", cwd: "/Users/tester/none")
        #expect(entry.provider.isTranscriptFile("/tmp/whatever.jsonl") == false)
        #expect(entry.provider.sessionId(fromTranscriptFile: "/tmp/whatever.jsonl") == nil)
        let recordCwd = try entry.provider.cwd(fromTranscriptFile: "/tmp/whatever.jsonl")
        #expect(recordCwd == nil)
        #expect(
          entry.provider.subagentTranscriptFiles(sessionId: "sid", cwd: "/Users/tester/none")
            .isEmpty)
        let source = entry.provider as? any AgentSessionDiscoverySource
        #expect(
          source?.recentSessions(since: recentSince, limit: 5).isEmpty ?? true,
          "\(name) 指定目录不存在仍发现会话")
      }
    }

    // omp / pi 与 Claude 同属「扩展型」集成：`paths()` 不设存在性闸门（扩展与脚本的目录由
    // 安装器按需创建），因此判据是「指向指定目录 + 记录安全返回空值」，而不是 nil。
    let ungated: [(kind: AgentKind, provider: any AgentProvider)] = [
      (.ohMyPi, PiFamilyAgentProvider(kind: .ohMyPi)),
      (.pi, PiFamilyAgentProvider(kind: .pi)),
    ]
    for entry in ungated {
      try withRootOverride(entry.kind, missing.path) {
        #expect(entry.provider.paths()?.configDir.path == missing.path)
        #expect(
          entry.provider.paths()?.sessionsDir?.path
            == missing.appendingPathComponent("sessions").path)
        #expect(entry.provider.transcriptFile(sessionId: "sid", cwd: "/Users/tester/none") == nil)
        #expect(
          entry.provider.subagentTranscriptFiles(sessionId: "sid", cwd: "/Users/tester/none")
            .isEmpty)
        let source = entry.provider as? any AgentSessionDiscoverySource
        #expect(source?.recentSessions(since: recentSince, limit: 5).isEmpty ?? true)
      }
    }

    // 安装器同一条判据：指定目录不存在 ⇒ 跳过（返回 true），一个字节都不写
    try withRootOverride(.gemini, missing.path) {
      #expect(AgentConfigInstaller.install(.gemini, home: home))
      #expect(!FileManager.default.fileExists(atPath: missing.path))
      #expect(AgentConfigInstaller.isInstalled(.gemini, home: home) == false)
    }
  }

  @Test("优先级：$CODEX_HOME 压过指定目录（环境变量是工具自己的配置方式）")
  func environmentWinsOverRootOverride() throws {
    let home = try tempHome()
    defer { remove(home) }

    let uuid = "019d0a9e-a27a-7651-bc6d-1c6f5f90e358"
    let cwd = "/Users/tester/work/codex"
    let record =
      #"{"type":"session_meta","payload":{"id":"\#(uuid)","cwd":"\#(cwd)"}}"#
    let envRoot = home.appendingPathComponent("env-codex")
    let envFile = try write(
      record,
      to: envRoot.appendingPathComponent(
        "sessions/2026/09/22/rollout-2026-09-22T10-11-12-\(uuid).jsonl"))
    let overrideRoot = home.appendingPathComponent("custom-codex")
    try write(
      record,
      to: overrideRoot.appendingPathComponent(
        "sessions/2026/09/22/rollout-2026-09-22T10-11-12-\(uuid).jsonl"))

    let provider = CodexAgentProvider(
      home: home, environment: ["CODEX_HOME": envRoot.path])
    try withRootOverride(.codex, overrideRoot.path) {
      #expect(provider.paths()?.configDir.path == envRoot.path, "环境变量应压过指定目录")
      let found = sessions(provider)
      #expect(found.count == 1)
      #expect(found.first?.transcriptPath == envFile.path)
    }
  }
}

// MARK: - 进程判据

/// `AgentProcessScanner.matches` 是「会话 ↔ 进程」关联的唯一判据：判错了要么会话拿不到
/// pid（永远不会因「进程退出」被回收，只能等空闲超时），要么把别的工具认成某个 Agent
/// （会话串台、互相踢掉）。这里直接喂真实形态的启动路径——`ps -Ao comm=` 给的就是完整
/// 路径，扫描器把它的最后一段当 `executable`——因此用例不依赖真机上跑着什么进程。
@Suite("Agent 进程判据")
struct AgentProcessMatchTests {
  /// 扫描器的喂法：`executable` 是 `comm` 的最后一段。
  private func hit(_ agent: AgentKind, _ command: String) -> Bool {
    AgentProcessScanner.matches(
      agent, executable: (command as NSString).lastPathComponent, command: command)
  }

  /// 扫描器的真实用法：按 `AgentKind.allCases` 顺序取第一个命中的 Agent。判据各自正确
  /// 但顺序错位时，会话照样会被算到别的 Agent 名下，因此这条要一起钉住。
  private func owner(of command: String) -> AgentKind? {
    AgentKind.allCases.first { hit($0, command) }
  }

  @Test("Trae 的 IDE 与 CLI 都命中")
  func traeMatchesIDEAndCLI() {
    let cases = [
      "/Applications/Trae.app/Contents/MacOS/Trae",  // 国际版 IDE 主二进制
      "/Applications/Trae CN.app/Contents/MacOS/Trae CN",  // 国内版的真实包名
      "/Applications/Trae-CN.app/Contents/MacOS/Trae",  // 上游另有这两种包名
      "/Applications/TraeCN.app/Contents/MacOS/Trae",
      "/Users/tester/.local/bin/coco",  // CLI（`binaryName`）
      "/applications/trae.app/contents/macos/trae",  // 判据是小写后比较
    ]
    for command in cases {
      #expect(hit(.trae, command), "\(command) 应命中 Trae")
    }
  }

  @Test("Hermes 只认 venv 里的控制台脚本，不认常驻 gateway / 看门狗")
  func hermesMatchesOnlyConsoleScript() {
    // 真实形态（本机实测）：启动器 `~/.local/bin/hermes` 只做 exec，活着的是解释器 +
    // `<hermesHome>/hermes-agent/venv/bin/hermes` 控制台脚本。
    let hits = [
      "/Users/tester/.hermes/hermes-agent/venv/bin/python3 /Users/tester/.hermes/hermes-agent/venv/bin/hermes --version",
      "/Users/tester/.hermes/hermes-agent/venv/bin/python3 /Users/tester/.hermes/hermes-agent/venv/bin/hermes chat",
      "/Users/tester/.local/bin/hermes",  // 直接执行控制台脚本时 comm 就是它（快路径）
    ]
    for command in hits {
      #expect(hit(.hermes, command), "\(command) 应命中 Hermes")
    }

    // 常驻进程一条都不许认：多一个命中就让「唯一进程」恒不成立，会话再也拿不到 pid。
    let misses = [
      // gateway 常驻守护（路径里含 /hermes-agent/，tokens[1] 是 `-m`）
      "/Users/tester/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run --replace",
      // MCP 看门狗子进程（tokens[1] 是 tools 下的 .py）
      "/Users/tester/.hermes/hermes-agent/venv/bin/python /Users/tester/.hermes/hermes-agent/tools/mcp_stdio_watchdog.py --ppid 89694",
      // 只是路径里恰好含 hermes 的其它进程
      "/usr/bin/python3 /Users/tester/.hermes/hermes-agent/run_agent.py",
    ]
    for command in misses {
      #expect(!hit(.hermes, command), "\(command) 不应命中 Hermes")
    }
  }

  @Test("Trae 不误命中别的 Agent 与辅助进程")
  func traeDoesNotOverreach() {
    let misses = [
      "/Users/tester/.local/bin/traecli",  // 是另一个 Agent（Trae CLI）
      "/Users/tester/.nvm/versions/node/v20.11.0/bin/claude",
      "/Applications/Cursor.app/Contents/MacOS/Cursor",
      // 辅助进程随窗口结束就退出，而发现器要「该 Agent 只有一个进程」才关联 pid：
      // 多认一个辅助进程只会让关联整个失效，所以只认 `Contents/MacOS/` 下的主二进制。
      "/Applications/Trae.app/Contents/Frameworks/Trae Helper (Renderer).app/Contents/MacOS/Trae Helper (Renderer)",
      "/Applications/Trae CN.app/Contents/Frameworks/Trae CN Helper.app/Contents/MacOS/Trae CN Helper",
    ]
    for command in misses {
      #expect(!hit(.trae, command), "\(command) 不应命中 Trae")
    }
    // traecli 归 Trae CLI，IDE 本体归 Trae：两边都别越界。
    #expect(hit(.traeCli, "/Users/tester/.local/bin/traecli"))
    #expect(!hit(.traeCli, "/Applications/Trae.app/Contents/MacOS/Trae"))
  }

  @Test("IDE 本体判给各自的 Agent")
  func ideBundlesResolveToOwnAgent() {
    let cases: [(command: String, owner: AgentKind, others: [AgentKind])] = [
      (
        "/Applications/Cursor.app/Contents/MacOS/Cursor", .cursor,
        [.trae, .traeCli, .qoder, .factory]
      ),
      (
        "/Applications/Factory.app/Contents/MacOS/Electron", .factory,
        [.cursor, .trae, .qoder, .claudeCode]
      ),
      // Qoder IDE 1.25.1 把包名与可执行名一起改了，两种组合都要认。
      (
        "/Applications/Qoder.app/Contents/MacOS/Electron", .qoder,
        [.cursor, .factory, .trae]
      ),
      (
        "/Applications/Qoder IDE.app/Contents/MacOS/Qoder", .qoder,
        [.cursor, .factory, .trae]
      ),
    ]
    for entry in cases {
      #expect(
        owner(of: entry.command) == entry.owner, "\(entry.command) 应判给 \(entry.owner.rawValue)")
      for other in entry.others {
        #expect(!hit(other, entry.command), "\(entry.command) 不应命中 \(other.rawValue)")
      }
    }
  }

  @Test("IDE 的辅助进程一律不命中")
  func ideHelpersDoNotMatch() {
    let cases: [(command: String, agent: AgentKind)] = [
      (
        "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)",
        .cursor
      ),
      (
        "/Applications/Factory.app/Contents/Frameworks/Factory Helper.app/Contents/MacOS/Factory Helper",
        .factory
      ),
      (
        "/Applications/Qoder.app/Contents/Frameworks/Qoder Helper.app/Contents/MacOS/Qoder Helper",
        .qoder
      ),
      (
        "/Applications/Qoder IDE.app/Contents/Frameworks/Qoder Helper.app/Contents/MacOS/Qoder Helper",
        .qoder
      ),
    ]
    for entry in cases {
      #expect(
        !hit(entry.agent, entry.command),
        "\(entry.command) 是辅助进程，不应命中 \(entry.agent.rawValue)")
    }
  }

  @Test("IDE 判据不挤掉原有的 CLI 判据")
  func cliFormsStillMatch() {
    let cases: [(command: String, agent: AgentKind)] = [
      ("/Users/tester/.local/bin/cursor-agent", .cursor),
      ("/Users/tester/.qoder/bin/qodercli", .qoder),
      ("/Users/tester/.local/bin/droid", .factory),
    ]
    for entry in cases {
      #expect(hit(entry.agent, entry.command), "\(entry.command) 应命中 \(entry.agent.rawValue)")
    }
  }
}
