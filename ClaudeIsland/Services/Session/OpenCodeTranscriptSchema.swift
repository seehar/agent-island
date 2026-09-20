//
//  OpenCodeTranscriptSchema.swift
//  ClaudeIsland
//
//  OpenCode 的历史存在 SQLite 里而不是「一个会话一个文件」，因此这里不走
//  JSONL 的字节记账循环：每次读取按游标取新消息，消息 id 即去重键。
//

import Foundation

/// OpenCode 会话记录的解析器。
final class OpenCodeTranscriptSchema: AgentTranscriptSchema {
    var agent: AgentKind { .opencode }

    /// 一次读取最多处理的消息条数。OpenCode 的会话可能非常长，先取一段，
    /// 剩下的交给下一次读取（游标持续推进）。
    private static let messageBatchSize = 500

    /// OpenCode 的历史在数据库里，没有会话记录文件。
    func transcriptFile(sessionId: String, cwd: String) -> URL? { nil }

    // MARK: - 读取

    func read(sessionId: String, cwd: String, state: inout TranscriptParseState)
        -> TranscriptReadResult
    {
        var result = TranscriptReadResult()
        var progress = OpenCodeProgress(state.cursor)

        // `sinceCreated` 是包含式的下界（按毫秒），因此游标所在的那条消息
        // 每次都会被取回。
        let window = OpenCodeSessionStore.messages(
            sessionId: sessionId,
            sinceCreated: progress.createdAt,
            limit: Self.messageBatchSize
        )

        // 游标所在的消息已经产出过气泡，但它的分片可能刚追加了工具结果，
        // 因此要连同新消息一起重扫。
        var scanned: [OpenCodeMessageRecord] = []
        if let cursorId = progress.messageId,
            let boundary = window.first(where: { $0.id == cursorId })
        {
            scanned.append(boundary)
        }

        // 游标之后、且尚未产出过的消息才是新内容。
        let fresh = window.filter {
            !state.emittedMessageIds.contains($0.id) && progress.isAfter($0.id)
        }
        guard !fresh.isEmpty || !scanned.isEmpty else { return result }
        scanned.append(contentsOf: fresh)

        let parts = OpenCodeSessionStore.parts(messageIds: scanned.map(\.id))

        result.isNewContent = !fresh.isEmpty
        // 游标所在的消息已经产出过，重扫时原地替换（补齐后到的分片），
        // 只把没产出过的消息算作新消息，避免下一轮重复冒出同一个气泡。
        var conversation = state.messages
        var indexByMessageId: [String: Int] = [:]
        for (index, message) in conversation.enumerated() {
            indexByMessageId[message.id] = index
        }

        for message in scanned {
            if let chatMessage = consume(
                message, parts: parts[message.id] ?? [], state: &state, result: &result)
            {
                if let index = indexByMessageId[chatMessage.id] {
                    if conversation[index].content != chatMessage.content {
                        conversation[index] = chatMessage
                    }
                } else {
                    indexByMessageId[chatMessage.id] = conversation.count
                    conversation.append(chatMessage)
                    result.newMessages.append(chatMessage)
                }
            }
            // 生成中的消息先被读到、`finish` 稍后才写入，因此「本轮结束」
            // 按消息记在游标里去重，而不是只看首次产出。
            if message.role == "assistant", message.finish == "stop",
                !progress.hasReportedTurnFinish(message.id)
            {
                progress.markTurnFinished(message.id)
                result.activity.append(.turnFinished)
            }
            progress.advance(to: message)
        }
        state.messages = conversation
        state.cursor = progress.encoded
        return result
    }

    // MARK: - 消息翻译

    /// 翻译一条消息：返回要追加到对话里的气泡；没有用户可见内容时返回 nil。
    private func consume(
        _ message: OpenCodeMessageRecord,
        parts: [OpenCodePartRecord],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> ChatMessage? {
        switch message.role {
        case "user":
            return consumeUser(message, parts: parts, state: &state, result: &result)
        case "assistant":
            return consumeAssistant(message, parts: parts, state: &state, result: &result)
        default:
            // system 等角色没有用户可见内容。
            return nil
        }
    }

    /// 用户消息：产出用户气泡，并上报一次提示词提交事件。
    private func consumeUser(
        _ message: OpenCodeMessageRecord,
        parts: [OpenCodePartRecord],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> ChatMessage? {
        let texts = parts.compactMap { $0.type == "text" ? $0.text : nil }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }

        let text = texts.joined(separator: "\n")
        // 重扫（消息已被消费过）不再重复上报提交事件。
        let isFirstEmission = !state.emittedMessageIds.contains(message.id)
        state.emittedMessageIds.insert(message.id)
        state.lastUserMessageDate = message.createdAt
        state.lastMessage = TranscriptParsing.truncate(text)
        state.lastMessageRole = ChatRole.user.rawValue
        if state.firstUserMessage == nil {
            state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
        }
        if isFirstEmission {
            result.activity.append(.promptSubmitted(text: text))
        }

        return ChatMessage(
            id: message.id,
            role: .user,
            timestamp: message.createdAt,
            content: texts.map(MessageBlock.text)
        )
    }

    /// 助手消息：推理/文本产出气泡，工具分片同时产出气泡与活动事件。
    private func consumeAssistant(
        _ message: OpenCodeMessageRecord,
        parts: [OpenCodePartRecord],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> ChatMessage? {
        var blocks: [MessageBlock] = []
        for part in parts {
            switch part.type {
            case "text":
                if let text = part.text, !text.isEmpty {
                    blocks.append(.text(text))
                }
            case "reasoning":
                if let text = part.text, !text.isEmpty {
                    blocks.append(.thinking(text))
                }
            case "tool":
                guard let callId = part.callId, let name = part.toolName, !callId.isEmpty else {
                    continue
                }
                let input = TranscriptParsing.stringifyInput(part.toolInput)
                blocks.append(.toolUse(ToolUseBlock(id: callId, name: name, input: input)))
                consumeTool(part, callId: callId, name: name, input: input, state: &state, result: &result)
            default:
                // compaction（上下文压缩）、patch、file、step-start、step-finish
                // 都没有用户可见内容。
                continue
            }
        }

        // 只有 step-* 分片的中间消息不产出气泡；token 与末条消息也随之跳过，
        // 避免每次重扫重复累加。
        guard !blocks.isEmpty else { return nil }
        // 重扫（消息已被消费过）不再累加 token、不再重复上报本轮结束。
        let isFirstEmission = !state.emittedMessageIds.contains(message.id)
        state.emittedMessageIds.insert(message.id)

        for block in blocks.reversed() {
            if case .toolUse(let tool) = block {
                state.lastMessage = TranscriptParsing.truncate(tool.preview)
                state.lastMessageRole = "tool"
                state.lastToolName = tool.name
                break
            }
            if case .text(let text) = block {
                state.lastMessage = TranscriptParsing.truncate(text)
                state.lastMessageRole = ChatRole.assistant.rawValue
                break
            }
        }

        if isFirstEmission, let tokens = message.tokens {
            Self.accumulateUsage(tokens, into: &state)
        }

        return ChatMessage(
            id: message.id,
            role: .assistant,
            timestamp: message.createdAt,
            content: blocks
        )
    }

    /// 工具分片：进行中只上报一次开始事件，结束后登记结果并上报一次结束事件。
    private func consumeTool(
        _ part: OpenCodePartRecord,
        callId: String,
        name: String,
        input: [String: String],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        switch part.toolStatus {
        case "completed", "error":
            let isError = part.toolStatus == "error"
            // 结果只登记一次；重扫时只补「本次新看到的完成状态」。
            if state.toolResults[callId] == nil {
                state.toolResults[callId] = ToolResultPayload(
                    content: part.toolOutput ?? part.toolError,
                    stdout: nil,
                    stderr: nil,
                    isError: isError
                )
            }
            if state.completedToolIds.insert(callId).inserted {
                // 完成事件之后不该再出现同一调用的开始事件。
                state.seenToolIds.insert(callId)
                state.toolIdToName[callId] = name
                result.activity.append(.toolFinished(id: callId, name: name, isError: isError))
            }
        case "pending", "running":
            // 进行中的调用只上报一次开始事件。
            if state.seenToolIds.insert(callId).inserted {
                state.toolIdToName[callId] = name
                result.activity.append(.toolStarted(id: callId, name: name, input: input))
            }
        default:
            // 未知状态只保留工具气泡，不产出事件。
            break
        }
    }

    /// 累加 token 用量（`cache.write` 对应统一的 `cacheCreationTokens`）。
    private static func accumulateUsage(
        _ tokens: [String: Any], into state: inout TranscriptParseState
    ) {
        state.usage.inputTokens += (tokens["input"] as? NSNumber)?.intValue ?? 0
        state.usage.outputTokens += (tokens["output"] as? NSNumber)?.intValue ?? 0
        if let cache = tokens["cache"] as? [String: Any] {
            state.usage.cacheReadTokens += (cache["read"] as? NSNumber)?.intValue ?? 0
            state.usage.cacheCreationTokens += (cache["write"] as? NSNumber)?.intValue ?? 0
        }
    }
}

// MARK: - 读取游标

/// OpenCode 的读取进度：已消费到的最后一条消息，以及最近上报过「本轮结束」
/// 的消息。
///
/// 编码成 `v1|<毫秒>|<消息 id>|<本轮结束消息 id>`：毫秒是查询下界（走索引），
/// 消息 id 用来做 id 差集；`finish` 是消息写完后才补上的，所以「本轮结束」
/// 需要独立去重，否则每次重扫都会重复上报。OpenCode 的消息 id 前缀就是创建
/// 时间，因此同格式下字典序与创建顺序一致。
private struct OpenCodeProgress {
    var createdAt: Date?
    var messageId: String?
    var finishedTurnId: String?

    init(_ encoded: String?) {
        guard let encoded, encoded.hasPrefix("v1|") else { return }
        let fields = encoded.dropFirst(3).components(separatedBy: "|")
        guard fields.count == 3 else { return }
        if let milliseconds = Double(fields[0]), milliseconds > 0 {
            self.createdAt = Date(timeIntervalSince1970: milliseconds / 1000)
        }
        self.messageId = fields[1].isEmpty ? nil : fields[1]
        self.finishedTurnId = fields[2].isEmpty ? nil : fields[2]
    }

    /// 给定消息是否排在游标之后（没有游标时全部算新）。
    func isAfter(_ candidateId: String) -> Bool {
        guard let messageId else { return true }
        return candidateId > messageId
    }

    /// 这条消息的「本轮结束」是否已经上报过。
    func hasReportedTurnFinish(_ candidateId: String) -> Bool {
        finishedTurnId == candidateId
    }

    mutating func markTurnFinished(_ candidateId: String) {
        finishedTurnId = candidateId
    }

    /// 把游标推进到一条已消费的消息。
    mutating func advance(to message: OpenCodeMessageRecord) {
        if createdAt.map({ message.createdAt > $0 }) ?? true {
            createdAt = message.createdAt
        }
        if messageId.map({ message.id > $0 }) ?? true {
            messageId = message.id
        }
    }

    var encoded: String {
        let milliseconds = createdAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return "v1|\(milliseconds)|\(messageId ?? "")|\(finishedTurnId ?? "")"
    }
}