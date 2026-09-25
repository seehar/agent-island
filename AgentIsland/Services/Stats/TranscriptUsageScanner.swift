//
//  TranscriptUsageScanner.swift
//  AgentIsland
//
//  从各 Agent 的 JSONL 记录里抽取「用量贡献」：每条记录的时间（落到本地小时桶）、
//  token 四元组、以及工具调用名。与 `ConversationParser` 的解析器不同，这里
//  只关心统计需要的字段，并且是**按字节增量**读取的（读取位置由调用方保存在
//  统计库里），因此可以反复扫全盘而不重复计数。
//
//  两条与仓库既有实现保持一致的不变量：
//    · 只消费到最后一个换行符为止（半行不消费），所以「先写半条、后补完」不会重复计数；
//    · 文件变小（被截断 / 整体重写）由调用方改为整源重放。
//

import Foundation

/// 一个待索引的记录文件。
nonisolated struct UsageSourceFile: Equatable {
  var path: String
  var agent: AgentKind
  var sessionId: String
  /// 记录文件本身就属于子代理（omp/pi 的嵌套目录）。Claude 侧另有行级的 `isSidechain`。
  var isSubagentFile = false
}

/// 一次增量读取的结果。
nonisolated struct UsageReadResult: Equatable {
  var state: UsageSourceState
  var deltas: [UsageBucketDelta] = []
  /// 文件被截断 / 整体重写：调用方必须先清掉这个源的历史桶再写入。
  var needsReplace = false
}

nonisolated enum TranscriptUsageScanner {
  /// 一次读盘的分块大小；大文件不会一次性分配巨量内存。
  private static let chunkBytes = 4 << 20

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  // MARK: - 源发现

  /// 枚举某个 Agent 记录根目录下的全部 JSONL 记录（含子代理目录）。
  static func sources(for kind: AgentKind, roots: [URL]) -> [UsageSourceFile] {
    var results: [UsageSourceFile] = []
    let fm = FileManager.default

    for root in roots {
      let rootComponents = Self.pathComponents(root.path)
      guard
        let enumerator = fm.enumerator(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else { continue }

      for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl", !url.lastPathComponent.hasPrefix(".") else {
          continue
        }
        results.append(
          describe(
            url: url, relativePath: Self.relativePath(of: url, under: rootComponents), agent: kind)
        )
      }
    }
    return results
  }

  /// 路径的组件序列；开头的 `/private` 视为等价前缀去掉。
  ///
  /// macOS 上 `/var` 是指向 `/private/var` 的软链接：枚举给定目录时 FileManager 可能
  /// 返回 `/private/var/...` 形式的路径，而调用方传进来的是 `/var/...`——直接比字符串
  /// 前缀会失败，子代理判定就会整体退化成「不是子代理」，omp 的子代理会话被当成普通
  /// 会话、会话数直接翻倍。这里按组件比较，并对 `/private` 做归一。
  private static func pathComponents(_ path: String) -> [String] {
    var components = path.split(separator: "/").map(String.init)
    if components.first == "private" { components.removeFirst() }
    return components
  }

  /// `url` 相对某个根目录的路径（去掉根目录组件后重新拼起来）。
  private static func relativePath(of url: URL, under rootComponents: [String]) -> String {
    let components = pathComponents(url.path)
    guard components.count > rootComponents.count,
      Array(components.prefix(rootComponents.count)) == rootComponents
    else {
      return url.lastPathComponent
    }
    return components.dropFirst(rootComponents.count).joined(separator: "/")
  }

  /// 把文件路径翻译成会话 id 与「是否子代理」。
  ///
  /// 布局：`<根>/<分桶>/<会话文件>.jsonl`（根会话）、`<根>/<分桶>/<会话文件去扩展名>/<子代理>.jsonl`
  /// （子代理，可再嵌套）；Claude 另有 `<根>/<分桶>/<会话 id>/subagents/agent-<id>.jsonl`。
  private static func describe(url: URL, relativePath: String, agent: AgentKind) -> UsageSourceFile
  {
    let components = relativePath.split(separator: "/").map(String.init)
    let file = url.lastPathComponent

    switch agent {
    case .claudeCode, .qoder, .factory, .codeBuddy:
      // Claude 系（含 Qoder / Factory / CodeBuddy 这类 fork）的布局一致：
      // 根会话是 `<根>/<分桶>/<会话 id>.jsonl`，子代理另存为
      // `…/<会话 id>/subagents/agent-<id>.jsonl`（或旧版扁平的 `agent-<id>.jsonl`）。
      // fork 是否也有子代理目录未经验证：只有真出现 `subagents` 组件时才会命中。
      if let index = components.firstIndex(of: "subagents"), index >= 1 {
        return UsageSourceFile(
          path: url.path, agent: agent, sessionId: components[index - 1], isSubagentFile: true)
      }
      if file.hasPrefix("agent-") {
        return UsageSourceFile(
          path: url.path, agent: agent,
          sessionId: url.deletingPathExtension().lastPathComponent, isSubagentFile: true)
      }
      return UsageSourceFile(
        path: url.path, agent: agent, sessionId: url.deletingPathExtension().lastPathComponent)

    case .ohMyPi, .pi, .opencode:
      // 根会话直接位于分桶目录下（两层）；更深一层的都是子代理（可再嵌套）。
      let isSubagent = components.count > 2
      let sessionId =
        PiFamilyAgentProvider.sessionIdForTranscript(url)
        ?? url.deletingPathExtension().lastPathComponent
      return UsageSourceFile(
        path: url.path, agent: agent, sessionId: sessionId, isSubagentFile: isSubagent)

    case .codex, .gemini, .cursor, .copilot, .kimi, .grok, .cline:
      // 这几家各有各的布局（codex 按 `YYYY/MM/DD` 分桶、copilot 是 `<会话 id>/events.jsonl`、
      // cursor 有 `subagents/` 目录……），会话 id 的命名规则也各不相同，因此交给各自的
      // Provider 解析（它同时管路径与会话 id）；取不到时退化为文件名。
      let sessionId =
        AgentRegistry.provider(for: agent).sessionId(fromTranscriptFile: url.path)
        ?? url.deletingPathExtension().lastPathComponent
      return UsageSourceFile(
        path: url.path, agent: agent, sessionId: sessionId,
        isSubagentFile: components.contains("subagents"))

    case .trae, .traeCli, .deepSeekHarness, .hermes:
      // 没有可解析的记录（不落盘 / zstd 压缩），不会出现在扫描源里；Hermes 的记录在 SQLite
      // 里（`~/.hermes/state.db`），它的用量走 `HermesUsageReader` 这条独立路径。
      // 这里只保证 switch 穷举，行为与「按文件名当会话 id」一致。
      return UsageSourceFile(
        path: url.path, agent: agent, sessionId: url.deletingPathExtension().lastPathComponent)
    }
  }

  // MARK: - 增量读取

  /// 从 `previous` 记录的位置继续读取，返回新的进度与用量贡献。
  ///
  /// - Parameter previous: 上次的进度；没有则为 `nil`（从头读）。记录里读不到
  ///   时间戳时按文件的修改时间归档（本机四种 Agent 的记录都带时间戳，
  ///   这条只是兜底）。
  static func read(
    source: UsageSourceFile,
    previous: UsageSourceState?,
    calendar: Calendar
  ) -> UsageReadResult {
    // 走 POSIX `stat` 而不是 `FileManager.attributesOfItem`：后者每次调用都要造一个
    // Dictionary（+ Date），本机 4945 个源一轮实测 ≈0.5 秒，`stat` 约 0.15 秒。
    let facts = Self.fileFacts(atPath: source.path)
    let size = facts?.size ?? 0
    let mtime = facts?.mtime ?? 0

    var result = UsageReadResult(
      state: UsageSourceState(
        sizeBytes: size,
        readOffset: min(previous?.readOffset ?? 0, size),
        mtime: mtime,
        cursor: nil,
        updatedAt: Date().timeIntervalSince1970
      ))

    // 变小 = 被截断或整体重写；大小没变但修改时间变了 = 同长度重写。
    // 解析规则变过、而进度行还是改前的（`cursor` 里没有版本）：也整源重放一次——
    // 增量路径只看文件尾巴，会把「已经追到 EOF、但那套规则读不出数据」的文件永远跳过。
    let parserVersion = Self.parserVersion(for: source.agent)
    let previousCursor = parserVersion.map { Self.splitParserCursor(previous?.cursor, version: $0) }
    let staleParser = parserVersion != nil && previousCursor?.matches != true
    if let previous,
      size < previous.readOffset
        || (size == previous.readOffset && abs(mtime - previous.mtime) > 0.000_001)
        || staleParser
    {
      result.needsReplace = true
      result.state.readOffset = 0
    }

    guard size > result.state.readOffset, let handle = FileHandle(forReadingAtPath: source.path)
    else { return result }
    defer { try? handle.close() }

    do {
      try handle.seek(toOffset: result.state.readOffset)
    } catch {
      return result
    }

    var consumed: UInt64 = 0
    var pending = Data()
    var deltas: [String: UsageBucketDelta] = [:]
    let markers = Self.markers(for: source.agent)
    let fallbackDate = Date(timeIntervalSince1970: mtime)
    // codex 的 token 行不带模型名（模型只写在同一个 `turn_context` 行里），因此按文件
    // 顺序记住最近一次看到的模型，并随进度标记（`cursor`）带到下一次读取：否则应用
    // 重启后新追加的 token 会落进空模型桶，模型榜就不等于全库总量了。
    var model = source.agent == .codex ? (previousCursor?.model ?? "") : ""

    while true {
      guard let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
      pending.append(chunk)

      guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
      let complete = pending[..<lastNewline]
      consumed += UInt64(lastNewline + 1)
      pending = Data(pending[(lastNewline + 1)...])

      for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard containsMarker(line, markers) else { continue }
        // codex：模型写在 `turn_context` 行上，先记下来再处理 token 行。
        if source.agent == .codex, let turnModel = Self.codexTurnModel(lineData: line) {
          model = turnModel
          continue
        }
        Self.appendDeltas(
          from: line, source: source, fallbackDate: fallbackDate, calendar: calendar,
          model: model, into: &deltas)
      }
    }

    result.state.readOffset += consumed
    // 解析规则变过的 Agent 用 `cursor` 带版本（见 `parserVersion(for:)`）；codex 的版本
    // 里再带上模型名（它的 token 行本身不带模型，模型在另一个文件位置的 `turn_context` 里）。
    if let parserVersion = Self.parserVersion(for: source.agent) {
      result.state.cursor = Self.parserCursor(parserVersion, model: model)
    }
    result.deltas = Array(deltas.values)
    return result
  }

  // MARK: - 解析器版本

  /// 记录解析规则的版本标记。只给「解析规则变过、旧进度会漏数据」的 Agent 发版本号。
  ///
  /// 进度行里的 `cursor` 一旦不是当前版本，那个源就整源重放一次（见 `read`）：没有这道
  /// 闸，增量路径会认为「已经追到文件末尾、没有变化」，新规则永远读不到老文件里的数据
  /// （CodeBuddy 的工具调用与 token 就是这么漏掉的——它们的行当时一条都没被解析）。
  private enum ParserVersion: String {
    case codeBuddy = "cb-v2"
    case codexModelAndTools = "cx-v2"
  }

  /// 该 Agent 当前要求的解析器版本；`nil` 表示不需要版本（进度行里的 `cursor` 另有用途）。
  ///
  /// codex 早期用 `cursor` 存模型名（见下面的读取逻辑），因此它的版本标记形如
  /// `cx-v2|<模型>`，旧行（只有模型名、或干脆没有）都会触发一次整源重放。
  private static func parserVersion(for agent: AgentKind) -> String? {
    switch agent {
    case .codeBuddy: return ParserVersion.codeBuddy.rawValue
    case .codex: return ParserVersion.codexModelAndTools.rawValue
    default: return nil
    }
  }

  /// 进度行里带的版本标记（含 codex 的模型后缀）。
  private static func parserCursor(_ version: String, model: String) -> String {
    version == ParserVersion.codexModelAndTools.rawValue ? "\(version)|\(model)" : version
  }

  /// 进度行里的 `cursor` 是否符合当前解析器；codex 额外取出其中记住的模型。
  private static func splitParserCursor(
    _ cursor: String?, version: String
  ) -> (matches: Bool, model: String) {
    guard let cursor, cursor.hasPrefix(version) else { return (false, "") }
    guard version == ParserVersion.codexModelAndTools.rawValue else { return (true, "") }
    let suffix = cursor.dropFirst(version.count)
    return (true, suffix.hasPrefix("|") ? String(suffix.dropFirst()) : "")
  }

  /// codex `turn_context` 行里的模型名（token 行本身不带模型）。
  private static func codexTurnModel(lineData: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
      (json["type"] as? String) == "turn_context",
      let payload = json["payload"] as? [String: Any],
      let model = payload["model"] as? String, !model.isEmpty
    else { return nil }
    return model
  }

  /// 文件的大小与修改时间（秒，含亚秒）。
  ///
  /// `FileManager.attributesOfItem` 每次调用都要构造 Dictionary 与 Date 对象；一轮要
  /// 对每个源做一次，本机 4945 个源实测 0.5 秒。`stat(2)` 直接填结构体，快 3 倍以上。
  private static func fileFacts(atPath path: String) -> (size: UInt64, mtime: Double)? {
    var info = stat()
    guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
    let mtime =
      Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    return (size: UInt64(max(0, info.st_size)), mtime: mtime)
  }

  /// 只有含这些字节标记的行才值得做 JSON 解析（工具结果等大行因此被整体跳过）。
  private static func markers(for agent: AgentKind) -> [[UInt8]] {
    switch agent {
    case .claudeCode, .qoder, .factory:
      // Claude 系：用量在 `message.usage`，工具调用在 `message.content[].tool_use`。
      return [Array("\"usage\"".utf8), Array("\"tool_use\"".utf8)]
    case .codeBuddy:
      // 工具调用与 token 都在 **顶层信封**上（本机实测）：一次调用是一行
      // `type:"function_call"`（`name` / `callId` 在顶层），token 挂在它的
      // `message.usage` 上（`input_tokens` / `output_tokens` / `cache_read_input_tokens`）。
      // `tool_use` 是不再产出的旧外壳，留着只为认历史文件；`"usage"` 是助手文本行
      // （只有 `message.usage`、没有工具块）的唯一特征，漏了它整行会被跳过。
      return [
        Array("\"function_call\"".utf8), Array("\"tool_use\"".utf8), Array("\"usage\"".utf8),
      ]
    case .ohMyPi, .pi:
      return [Array("\"usage\"".utf8), Array("\"toolCall\"".utf8)]
    case .codex:
      // `token_count` 是 token 行；`turn_context` 提供模型名（token 行不带模型）；
      // `function_call` 同时命中 `function_call_output`（由 extract 再筛）。
      // `web_search_call` / `tool_search_call` 是**独立于 function_call** 的调用类型
      // （本机实测：前者 180 行、后者 9 行，都没有对应的 function_call 行），漏了它们
      // 这些调用一条都统计不到。
      return [
        Array("\"token_count\"".utf8), Array("\"turn_context\"".utf8),
        Array("\"function_call\"".utf8), Array("\"custom_tool_call\"".utf8),
        Array("\"web_search_call\"".utf8), Array("\"tool_search_call\"".utf8),
      ]
    case .cursor:
      // 记录里没有 token 字段（CodeIsland 也只读文本），只统计工具调用。
      return [Array("\"tool_use\"".utf8)]
    case .copilot:
      // 本机 9 个事件文件里没有任何 token 字段（`data` 的键见 CopilotTranscriptSchema），
      // 只统计工具调用。
      return [Array("\"tool.execution_start\"".utf8)]
    case .opencode, .gemini, .kimi, .cline, .grok, .trae, .traeCli, .deepSeekHarness, .hermes:
      // 不产出用量：OpenCode 与 Hermes 的历史都走 SQLite 的另一条路径；gemini 的 token
      // 字段本机无法核对（既不知道字段名，也不知道它是单次增量还是累计值，猜错会把
      // 统计放大若干倍）；kimi / cline / grok 的记录里没有观察到 token 字段。
      return []
    }
  }

  private static func containsMarker(_ line: Data, _ markers: [[UInt8]]) -> Bool {
    line.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      for marker in markers where !marker.isEmpty {
        if memmem(base, raw.count, marker, marker.count) != nil { return true }
      }
      return false
    }
  }

  // MARK: - 单行抽取

  private static func appendDeltas(
    from line: Data,
    source: UsageSourceFile,
    fallbackDate: Date,
    calendar: Calendar,
    model: String,
    into deltas: inout [String: UsageBucketDelta]
  ) {
    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }

    let record = extract(
      json: json, agent: source.agent, fallbackDate: fallbackDate, model: model)
    guard let record else { return }

    let hourKey = UsageStatsKey.hour(for: record.date, calendar: calendar)
    let subagent = source.isSubagentFile || record.isSubagent

    // 只有 token 行才建 token 桶：工具行（含「记录里没有 token 字段」的 Agent）
    // 建出来的桶模型为空、token 全零，落库只会污染模型榜与按会话读数。
    if record.carriesTokens {
      var tokens = UsageBucketDelta(
        hourKey: hourKey, sessionId: source.sessionId, isSubagent: subagent, tool: "")
      tokens.records = 1
      tokens.input = record.input
      tokens.output = record.output
      tokens.cacheRead = record.cacheRead
      tokens.cacheWrite = record.cacheWrite
      tokens.model = record.model
      // 键必须带模型：同一个会话文件里换过模型时，两个模型的 token 不能合成一条桶。
      merge(
        &deltas,
        key: tokens.hourKey + "|" + (subagent ? "1" : "0") + "|" + tokens.model + "|",
        delta: tokens)
    }

    // 工具行**不设** `model`：工具榜不按模型拆，键因此维持原样。
    for name in record.tools where !name.isEmpty {
      var call = UsageBucketDelta(
        hourKey: hourKey, sessionId: source.sessionId, isSubagent: subagent,
        tool: GenericToolResultBuilder.normalizedName(name))
      call.calls = 1
      merge(
        &deltas, key: call.hourKey + "|" + (subagent ? "1" : "0") + "|" + call.tool, delta: call)
    }
  }

  private static func merge(
    _ deltas: inout [String: UsageBucketDelta], key: String, delta: UsageBucketDelta
  ) {
    if var existing = deltas[key] {
      existing.merge(delta)
      deltas[key] = existing
    } else {
      deltas[key] = delta
    }
  }

  /// 单条记录里与统计有关的字段。
  private struct RecordUsage {
    var date: Date
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var tools: [String] = []
    var model = ""
    var isSubagent = false

    /// 这条记录真的带 token 计数（用于「token 全零的行不值得落库」的判定）。
    var hasTokens: Bool {
      input != 0 || output != 0 || cacheRead != 0 || cacheWrite != 0
    }

    /// 这行**是否携带 token**：只有被解析成 token 行的记录才为真。
    ///
    /// 工具行一律为假——包括「记录里根本不存在 token 字段」的 Agent（codeBuddy /
    /// cursor / copilot）与 codex 的 `function_call` 行。判据必须在**行**这一级说清，
    /// 不能靠「合并时兜一下」：工具的 model 为空，兜出来的桶键与真正的 token 行不同，
    /// 于是每个会话每小时会多出一个「空模型 + 全零」的无意义桶，污染模型榜与
    /// 按会话的读数。
    var carriesTokens = false
  }

  /// 一行记录 → 一条用量（token + 工具调用）。
  ///
  /// - Parameter model: 由调用方按文件顺序记住的模型（只有 codex 需要：它的 token 行
  ///   不带模型名，模型写在同一个 `turn_context` 行里）。
  private static func extract(
    json: [String: Any], agent: AgentKind, fallbackDate: Date, model: String
  ) -> RecordUsage? {
    switch agent {
    case .claudeCode, .qoder, .factory:
      // Claude 系记录（Qoder / Factory 与 Claude 同格式）。
      guard (json["type"] as? String) == "assistant",
        let message = json["message"] as? [String: Any]
      else { return nil }
      let date =
        (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
        ?? fallbackDate
      var record = RecordUsage(date: date)
      // Claude 系把用量写在 assistant 行上：这条记录就是 token 行。
      record.carriesTokens = true
      record.isSubagent = (json["isSidechain"] as? Bool) ?? false
      record.model = (message["model"] as? String) ?? ""
      if let usage = message["usage"] as? [String: Any] {
        record.input = intValue(usage["input_tokens"])
        record.output = intValue(usage["output_tokens"])
        record.cacheRead = intValue(usage["cache_read_input_tokens"])
        record.cacheWrite = intValue(usage["cache_creation_input_tokens"])
      }
      record.tools = toolNames(in: message, blockType: "tool_use")
      return record

    case .codeBuddy:
      // 两类行（本机实测，毫秒 epoch 时间戳）：
      //   · `type == "function_call"`：一次工具调用（顶层 `name`），并且**同时是 token 行**
      //     —— `message.usage` 是这次调用的增量（`input_tokens` 含缓存命中，要减去
      //     `cache_read_input_tokens`，与 Codex / Claude 的口径一致）；
      //   · `type == "message"` + 顶层 `role == "assistant"`：助手文本行，同样带
      //     `message.usage`；旧外壳里工具块写在 `content[].tool_use`。
      guard let type = json["type"] as? String else { return nil }
      let model =
        (json["providerData"] as? [String: Any])?["model"] as? String ?? ""

      if type == "function_call" {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        var record = RecordUsage(
          date: millisecondsTimestamp(json["timestamp"]) ?? fallbackDate)
        record.tools = [name]
        record.model = model
        // 只有真的带 `message.usage` 才算 token 行：不带 usage 的调用（旧记录里常见）
        // 若也建 token 桶，会落一行「模型非空、token 全零」的空桶，把模型榜与会话读数搞脏。
        applyCodeBuddyUsage(json["message"], into: &record)
        return record
      }

      guard type == "message", (json["role"] as? String) == "assistant" else { return nil }
      var record = RecordUsage(
        date: millisecondsTimestamp(json["timestamp"]) ?? fallbackDate)
      record.tools = toolNames(in: json, blockType: "tool_use")
      applyCodeBuddyUsage(json["message"], into: &record)
      guard record.carriesTokens || !record.tools.isEmpty else { return nil }
      record.model = model
      return record

    case .ohMyPi, .pi:
      guard (json["type"] as? String) == "message",
        let message = json["message"] as? [String: Any],
        (message["role"] as? String) == "assistant"
      else { return nil }
      var record = RecordUsage(date: timestamp(json: json, message: message) ?? fallbackDate)
      // omp / pi 同样把用量写在 assistant 行上。
      record.carriesTokens = true
      if let usage = message["usage"] as? [String: Any] {
        record.input = intValue(usage["input"])
        record.output = intValue(usage["output"])
        record.cacheRead = intValue(usage["cacheRead"])
        record.cacheWrite = intValue(usage["cacheWrite"])
      }
      record.model = (message["model"] as? String) ?? ""
      record.tools = toolNames(in: message, blockType: "toolCall")
      return record

    case .codex:
      // 两类行各有各的用途（顶层 `type` 不同，必须分别匹配）：
      //   · `event_msg` / `token_count`：`payload.info.last_token_usage` 是**本次调用**的
      //     增量（`total_token_usage` 是整会话累计值，用它会把统计放大若干倍）；
      //   · `response_item` / `function_call`（含 `custom_tool_call`）：工具调用。
      guard let payload = json["payload"] as? [String: Any] else { return nil }
      var record = RecordUsage(
        date: isoDate(json["timestamp"]) ?? fallbackDate)
      switch (json["type"] as? String, payload["type"] as? String) {
      case ("event_msg", "token_count"):
        guard let info = payload["info"] as? [String: Any],
          let last = info["last_token_usage"] as? [String: Any]
        else { return nil }
        let cached = intValue(last["cached_input_tokens"])
        // `input_tokens` 含缓存读，相减才是非缓存输入（否则总量会重复计入缓存）。
        record.input = max(0, intValue(last["input_tokens"]) - cached)
        record.cacheRead = cached
        record.output = intValue(last["output_tokens"])
        // 模型只出现在 `turn_context` 行里，由调用方按文件顺序记住后传进来。
        record.model = model
        record.carriesTokens = true
      case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
        guard let name = payload["name"] as? String, !name.isEmpty else { return nil }
        record.tools = [name]
      case ("response_item", "web_search_call"):
        // 没有 `name`：按 `action.type` 分类（search / open_page / find_in_page；
        // 缺 type 的行按通用的 web_search 计）。与 `event_msg/web_search_end` 不是一回事
        // ——后者没有 call_id，无法与调用配对，绝不能当成第二个计数。
        record.tools = [Self.codexWebSearchTool(payload["action"])]
      case ("response_item", "tool_search_call"):
        // 按需检索工具目录（`arguments.query`），与真正的调用分开计。
        record.tools = ["tool_search"]
      default:
        return nil
      }
      guard record.hasTokens || !record.tools.isEmpty else { return nil }
      return record

    case .cursor:
      // 记录行按顶层 `role` 区分，工具调用在 `message.content[].type == "tool_use"`。
      // 没有 token 字段（CodeIsland 也只读文本）⇒ 这行只携带工具调用，不建 token 桶。
      let message = json["message"] as? [String: Any] ?? json
      var record = RecordUsage(date: fallbackDate)
      record.tools = toolNames(in: message, blockType: "tool_use")
      guard !record.tools.isEmpty else { return nil }
      return record

    case .copilot:
      // 事件信封：`{"type":…,"data":{…}}`；工具调用在 `tool.execution_start.data.toolName`。
      // 本机 9 个事件文件里没有任何 token 字段 ⇒ 这行只携带工具调用，不建 token 桶。
      guard (json["type"] as? String) == "tool.execution_start",
        let data = json["data"] as? [String: Any],
        let name = data["toolName"] as? String, !name.isEmpty
      else { return nil }
      var record = RecordUsage(date: isoDate(json["timestamp"]) ?? fallbackDate)
      record.tools = [name]
      return record

    case .opencode, .gemini, .kimi, .cline, .grok, .trae, .traeCli, .deepSeekHarness, .hermes:
      // 不产出用量，理由见 `markers(for:)`：OpenCode 与 Hermes 走 SQLite 路径，gemini 的
      // token 字段本机无法核对（字段名与语义都未知），kimi / cline / grok 的记录里没有
      // token 字段，Trae / Trae CLI / DSH 没有可解析的记录。
      return nil
    }
  }

  /// CodeBuddy 的用量块（挂在顶层 `message.usage` 上）。
  ///
  /// 口径（本机实测 450 行、`requests` 恒为 1）：`input_tokens` 是这次调用的提示词
  /// token **且含缓存命中**（`input_tokens - cache_read_input_tokens` 等于
  /// `providerData.rawUsage.prompt_cache_miss_tokens`），因此相减后才是「非缓存输入」；
  /// `cache_creation_input_tokens` 在本机样本里恒为 0，但语义与 Claude 一致，照收。
  private static func applyCodeBuddyUsage(_ message: Any?, into record: inout RecordUsage) {
    guard let message = message as? [String: Any],
      let usage = message["usage"] as? [String: Any]
    else { return }
    let cached = intValue(usage["cache_read_input_tokens"])
    record.input = max(0, intValue(usage["input_tokens"]) - cached)
    record.output = intValue(usage["output_tokens"])
    record.cacheRead = cached
    record.cacheWrite = intValue(usage["cache_creation_input_tokens"])
    record.carriesTokens = true
  }

  /// codex `web_search_call` 的工具名：按 `action.type` 分类（search / open_page /
  /// find_in_page），缺 action 或 type 时退化成 `web_search`。
  private static func codexWebSearchTool(_ action: Any?) -> String {
    guard let action = action as? [String: Any],
      let kind = action["type"] as? String, !kind.isEmpty
    else { return "web_search" }
    switch kind {
    case "search": return "web_search"
    case "open_page": return "web_open"
    case "find_in_page": return "web_find"
    default: return "web_search"
    }
  }

  /// 条目级毫秒 epoch 时间戳（CodeBuddy 的记录用这个口径）。
  private static func millisecondsTimestamp(_ value: Any?) -> Date? {
    guard let number = value as? NSNumber, !(number is Bool) else { return nil }
    return Date(timeIntervalSince1970: number.doubleValue / 1000)
  }

  /// 条目级 ISO8601 时间戳。
  private static func isoDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return isoFormatter.date(from: text)
  }

  /// 条目级毫秒时间戳优先，其次取条目上的 ISO8601 字符串（与 pi/omp 记录解析一致）。
  private static func timestamp(json: [String: Any], message: [String: Any]) -> Date? {
    if let milliseconds = message["timestamp"] as? NSNumber, !(milliseconds is Bool) {
      return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
    }
    if let text = json["timestamp"] as? String {
      return isoFormatter.date(from: text)
    }
    return nil
  }

  private static func toolNames(in message: [String: Any], blockType: String) -> [String] {
    guard let content = message["content"] as? [[String: Any]] else { return [] }
    var names: [String] = []
    for block in content {
      guard (block["type"] as? String) == blockType, let name = block["name"] as? String,
        !name.isEmpty
      else { continue }
      names.append(name)
    }
    return names
  }

  private static func intValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) ?? 0 }
    return 0
  }
}
