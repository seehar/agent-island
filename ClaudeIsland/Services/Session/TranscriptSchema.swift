//
//  TranscriptSchema.swift
//  ClaudeIsland
//
//  所有 Agent 的会话记录都走同一条读取路径。JSONL 日志（Claude Code、pi、
//  Oh My Pi）共用下面的增量按行循环；结构化存储的 Agent（OpenCode）整读后
//  按消息 id 做差集。
//

import Foundation
import os.log

/// 从任意 Agent 记录中解析出的工具结果。
nonisolated struct ToolResultPayload: Equatable, Sendable {
  let content: String?
  let stdout: String?
  let stderr: String?
  let isError: Bool
  let isInterrupted: Bool

  init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
    self.content = content
    self.stdout = stdout
    self.stderr = stderr
    self.isError = isError
    // 识别「被中断」与「用户拒绝」的各种写法，用于区分失败的语义。
    self.isInterrupted =
      isError
      && (content?.contains("Interrupted by user") == true
        || content?.contains("interrupted by user") == true
        || content?.contains("user doesn't want to proceed") == true)
  }
}

/// 会话中发生的、值得上报的事件。实时集成（Claude hooks、pi 扩展）产生的
/// 事件形状与此一致，因此两条来源可以汇入同一条链路。
nonisolated enum AgentActivityEvent: Equatable, Sendable {
  /// 用户提交了提示词（或 Agent 基于该提示词继续工作）。
  case promptSubmitted(text: String?)
  /// 一次工具调用开始。
  case toolStarted(id: String, name: String, input: [String: String])
  /// 一次工具调用产生了结果。
  case toolFinished(id: String, name: String?, isError: Bool)
  /// Agent 结束本轮，等待用户输入。
  case turnFinished
  /// 会话被清空（`/clear`、reset boundary）。
  case sessionReset
}

/// 单个会话累积的解析状态。
nonisolated struct TranscriptParseState {
  /// 已经消费的字节偏移（JSONL 类 schema 使用）。
  var offset: UInt64 = 0
  /// 需要整读的 schema 使用的进度标记。
  var cursor: String?
  /// 按记录顺序累积的对话内容。
  var messages: [ChatMessage] = []
  /// 已经产出过的消息 id，供整读后做差集的 schema 使用。
  var emittedMessageIds: Set<String> = []
  var seenToolIds: Set<String> = []
  var toolIdToName: [String: String] = [:]
  /// 工具调用的入参（按 toolCallId 记录），供工具结果到达时推断结构化结果。
  var toolInputs: [String: [String: String]] = [:]
  var completedToolIds: Set<String> = []
  var toolResults: [String: ToolResultPayload] = [:]
  var structuredResults: [String: ToolResultData] = [:]

  // ConversationInfo 的累加量（填好后与 schema 无关）。
  var summary: String?
  var firstUserMessage: String?
  var lastMessage: String?
  var lastMessageRole: String?
  var lastToolName: String?
  var lastUserMessageDate: Date?
  var usage = UsageInfo()

  /// 增量读取期间观察到重置时置位。
  var resetPending = false

  /// 尚未被消费的活动事件。任何一次读取都会产生事件，但只有增量读取会取走
  /// 它们，因此先在这里暂存，避免「先整读、后增量读」时丢事件。
  var pendingActivity: [AgentActivityEvent] = []

  /// 累积到的会话元信息快照。
  var info: ConversationInfo {
    ConversationInfo(
      summary: summary,
      lastMessage: lastMessage,
      lastMessageRole: lastMessageRole,
      lastToolName: lastToolName,
      firstUserMessage: firstUserMessage,
      lastUserMessageDate: lastUserMessageDate,
      usage: usage
    )
  }

  /// 清空会话内容但保留读取位置（`/clear` 时使用）。
  mutating func resetConversation() {
    pendingActivity = []
    messages = []
    emittedMessageIds = []
    seenToolIds = []
    toolIdToName = [:]
    toolInputs = [:]
    completedToolIds = []
    toolResults = [:]
    structuredResults = [:]
    summary = nil
    firstUserMessage = nil
    lastMessage = nil
    lastMessageRole = nil
    lastToolName = nil
    lastUserMessageDate = nil
    usage = UsageInfo()
  }
}

/// 一次记录读取的结果。
nonisolated struct TranscriptReadResult {
  var newMessages: [ChatMessage] = []
  var activity: [AgentActivityEvent] = []
  var resetDetected = false
  /// 本次读取是否看到了新内容。
  var isNewContent = false

  static let empty = TranscriptReadResult()
}

/// 把某个 Agent 的记录读成统一的对话模型。
nonisolated protocol AgentTranscriptSchema: AnyObject {
  var agent: AgentKind { get }

  /// 会话对应的记录文件；结构化存储的 Agent 返回 nil。
  func transcriptFile(sessionId: String, cwd: String) -> URL?

  /// 增量读取上次调用之后新增的内容。
  func read(sessionId: String, cwd: String, state: inout TranscriptParseState)
    -> TranscriptReadResult

  /// 子 Agent 发起的工具调用（仅对单独保存子 Agent 记录的 Agent 有意义）。
  func subagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo]
}

nonisolated extension AgentTranscriptSchema {
  func subagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] { [] }
}

// MARK: - JSONL 类 schema

/// 追加式 JSONL 日志的共用读取器。
///
/// 子类只负责把「一条记录」翻译成消息与事件；字节记账、半行处理与重置语义
/// 都在这里，保证所有 JSONL Agent 的行为完全一致。
nonisolated class JSONLTranscriptSchema: AgentTranscriptSchema {
  var agent: AgentKind { .claudeCode }

  func transcriptFile(sessionId: String, cwd: String) -> URL? {
    AgentRegistry.provider(for: agent).transcriptFile(sessionId: sessionId, cwd: cwd)
  }

  /// 翻译一条 JSONL 记录。子类必须把产生的消息追加到 `result.newMessages`，
  /// 并上报活动事件。
  func consumeRecord(
    _ json: [String: Any],
    rawLine: String,
    state: inout TranscriptParseState,
    result: inout TranscriptReadResult
  ) {
    // 由子类覆盖。
  }

  final func read(sessionId: String, cwd: String, state: inout TranscriptParseState)
    -> TranscriptReadResult
  {
    var result = TranscriptReadResult()
    guard let url = transcriptFile(sessionId: sessionId, cwd: cwd),
      FileManager.default.fileExists(atPath: url.path),
      let handle = FileHandle(forReadingAtPath: url.path)
    else {
      return result
    }
    defer { try? handle.close() }

    let fileSize: UInt64
    do {
      fileSize = try handle.seekToEnd()
    } catch {
      return result
    }

    // 文件被截断或整体重写（迁移、重排）：从头重读。
    if fileSize < state.offset {
      state = TranscriptParseState()
    }
    if fileSize == state.offset {
      return result
    }

    do {
      try handle.seek(toOffset: state.offset)
    } catch {
      return result
    }
    guard let data = try? handle.readToEnd(), !data.isEmpty else {
      return result
    }

    let isIncrementalRead = state.offset > 0
    // 末尾未写完的行先不消费：只吃到最后一个换行符，这样分两次写入的
    // 记录只会被解析一次。
    let consumedCount: Int
    if let lastNewline = data.lastIndex(of: 0x0A) {
      consumedCount = data.distance(from: data.startIndex, to: lastNewline) + 1
    } else {
      consumedCount = 0
    }
    guard consumedCount > 0,
      let chunk = String(data: data.prefix(consumedCount), encoding: .utf8)
    else {
      return result
    }

    result.isNewContent = true
    for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
      let rawLine = String(line)
      guard let lineData = rawLine.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else {
        continue
      }
      consumeRecord(json, rawLine: rawLine, state: &state, result: &result)
    }

    state.offset += UInt64(consumedCount)

    if result.resetDetected {
      state.resetConversation()
      if isIncrementalRead {
        state.resetPending = true
      }
    }
    return result
  }
}

// MARK: - 共用解析工具

nonisolated enum TranscriptParsing {
  /// 各 schema 共用的 ISO8601 解析器（创建开销大，全局复用）。
  static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// 把任意工具入参拍平成 UI 使用的字符串字典。
  static func stringifyInput(_ input: [String: Any]?) -> [String: String] {
    guard let input else { return [:] }
    var flattened: [String: String] = [:]
    for (key, value) in input {
      switch value {
      case let string as String:
        flattened[key] = string
      case let number as Int:
        flattened[key] = String(number)
      case let number as Double:
        flattened[key] = String(number)
      case let flag as Bool:
        flattened[key] = flag ? "true" : "false"
      default:
        continue
      }
    }
    return flattened
  }

  /// 取消息中的第一段文本，用于标题与「最后一条消息」的兜底。
  static func firstText(in blocks: [MessageBlock]) -> String? {
    for block in blocks {
      if case .text(let text) = block, !text.isEmpty {
        return text
      }
    }
    return nil
  }

  /// 压缩消息文本，用于列表里的紧凑展示。
  static func truncate(_ message: String?, maxLength: Int = 80) -> String? {
    guard let message else { return nil }
    let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    if cleaned.count > maxLength {
      return String(cleaned.prefix(maxLength - 3)) + "..."
    }
    return cleaned
  }
}
