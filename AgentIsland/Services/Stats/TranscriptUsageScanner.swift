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
          describe(url: url, relativePath: Self.relativePath(of: url, under: rootComponents), agent: kind)
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
    case .claudeCode:
      // 子代理文件：`…/<会话 id>/subagents/agent-<id>.jsonl`，或旧版的扁平 `agent-<id>.jsonl`。
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
    let fm = FileManager.default
    let attributes = try? fm.attributesOfItem(atPath: source.path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

    var result = UsageReadResult(
      state: UsageSourceState(
        sizeBytes: size,
        readOffset: min(previous?.readOffset ?? 0, size),
        mtime: mtime,
        cursor: nil,
        updatedAt: Date().timeIntervalSince1970
      ))

    // 变小 = 被截断或整体重写；大小没变但修改时间变了 = 同长度重写。
    if let previous,
      size < previous.readOffset
        || (size == previous.readOffset && abs(mtime - previous.mtime) > 0.000_001)
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

    while true {
      guard let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
      pending.append(chunk)

      guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
      let complete = pending[..<lastNewline]
      consumed += UInt64(lastNewline + 1)
      pending = Data(pending[(lastNewline + 1)...])

      for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard containsMarker(line, markers) else { continue }
        Self.appendDeltas(
          from: line, source: source, fallbackDate: fallbackDate, calendar: calendar,
          into: &deltas)
      }
    }

    result.state.readOffset += consumed
    result.deltas = Array(deltas.values)
    return result
  }

  /// 只有含这些字节标记的行才值得做 JSON 解析（工具结果等大行因此被整体跳过）。
  private static func markers(for agent: AgentKind) -> [[UInt8]] {
    switch agent {
    case .claudeCode:
      return [Array("\"usage\"".utf8), Array("\"tool_use\"".utf8)]
    case .ohMyPi, .pi:
      return [Array("\"usage\"".utf8), Array("\"toolCall\"".utf8)]
    case .opencode:
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
    into deltas: inout [String: UsageBucketDelta]
  ) {
    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }

    let record = extract(json: json, agent: source.agent, fallbackDate: fallbackDate)
    guard let record else { return }

    let hourKey = UsageStatsKey.hour(for: record.date, calendar: calendar)
    let subagent = source.isSubagentFile || record.isSubagent

    var tokens = UsageBucketDelta(
      hourKey: hourKey, sessionId: source.sessionId, isSubagent: subagent, tool: "")
    tokens.records = 1
    tokens.input = record.input
    tokens.output = record.output
    tokens.cacheRead = record.cacheRead
    tokens.cacheWrite = record.cacheWrite
    merge(&deltas, key: tokens.hourKey + "|" + (subagent ? "1" : "0") + "|", delta: tokens)

    for name in record.tools {
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
    var isSubagent = false
  }

  private static func extract(
    json: [String: Any], agent: AgentKind, fallbackDate: Date
  ) -> RecordUsage? {
    switch agent {
    case .claudeCode:
      guard (json["type"] as? String) == "assistant",
        let message = json["message"] as? [String: Any]
      else { return nil }
      let date =
        (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
        ?? fallbackDate
      var record = RecordUsage(date: date)
      record.isSubagent = (json["isSidechain"] as? Bool) ?? false
      if let usage = message["usage"] as? [String: Any] {
        record.input = intValue(usage["input_tokens"])
        record.output = intValue(usage["output_tokens"])
        record.cacheRead = intValue(usage["cache_read_input_tokens"])
        record.cacheWrite = intValue(usage["cache_creation_input_tokens"])
      }
      record.tools = toolNames(in: message, blockType: "tool_use")
      return record

    case .ohMyPi, .pi:
      guard (json["type"] as? String) == "message",
        let message = json["message"] as? [String: Any],
        (message["role"] as? String) == "assistant"
      else { return nil }
      var record = RecordUsage(date: timestamp(json: json, message: message) ?? fallbackDate)
      if let usage = message["usage"] as? [String: Any] {
        record.input = intValue(usage["input"])
        record.output = intValue(usage["output"])
        record.cacheRead = intValue(usage["cacheRead"])
        record.cacheWrite = intValue(usage["cacheWrite"])
      }
      record.tools = toolNames(in: message, blockType: "toolCall")
      return record

    case .opencode:
      // OpenCode 的历史在 SQLite 里，不走这条路径。
      return nil
    }
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
