//
//  HermesTranscriptSchema.swift
//  AgentIsland
//
//  Hermes 的历史存在 SQLite（`state.db`）里而不是「一个会话一个文件」，因此这里不走
//  JSONL 的字节记账循环：每次读取按行 id 游标取新消息，消息行 id 即去重键。
//
//  与 OpenCode 同一条注意：行是**先落、后补**的——正文、`tool_calls`、`finish_reason`
//  都可能在首读之后才写进同一行（本机实测 26602 条助手消息里 93 条没有 `finish_reason`，
//  那批正是正在写入的活跃行）。因此游标那条行每轮都要重扫一次并**原地更新**气泡，
//  否则活跃会话的最后一条气泡会停在半截且不会自愈。
//

import Foundation

/// Hermes 会话记录的解析器。
nonisolated final class HermesTranscriptSchema: AgentTranscriptSchema {
    var agent: AgentKind { .hermes }

    /// 显式指定的库文件；nil（生产）时由 `HermesSessionStore` 问 Provider 解析。
    private let databaseURL: URL?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    /// 一次读取最多处理的消息条数。会话可能非常长（本机最长的一万多条），先取一段，
    /// 剩下的交给下一次读取（游标持续推进）。
    private static let messageBatchSize = 500

    /// Hermes 的历史在数据库里，没有会话记录文件。
    func transcriptFile(sessionId: String, cwd: String) -> URL? { nil }

    // MARK: - 读取

    /// 取「游标那条行 + 它之后的新消息」。
    ///
    /// 查询下界是**包含式**的（从游标那条行起，即 `id > 游标行 id - 1`）：游标那条行每轮
    /// 都会被取回、重新翻译一遍；只有它之后且没产出过的行才算新内容。代价是每次多取一行。
    ///
    /// 与 OpenCode 一致，这里不做重置检测：结构化存储没有「文件被截断 / 重写」这回事
    /// （行 id 单调递增），重置只可能来自实时事件。
    func read(sessionId: String, cwd: String, state: inout TranscriptParseState)
        -> TranscriptReadResult
    {
        var result = TranscriptReadResult()
        var progress = HermesProgress(state.cursor)

        let window = HermesSessionStore.messages(
            sessionId: sessionId,
            sinceRowId: max(0, progress.lastRowId - 1),
            limit: Self.messageBatchSize,
            databaseURL: databaseURL
        )
        // 游标那条行：重扫（正文可能刚补齐），不算新内容。
        var scanned: [HermesMessageRecord] = []
        if let boundary = window.first(where: { $0.id == progress.lastRowId }) {
            scanned.append(boundary)
        }
        // 游标之后、且尚未产出过的行才是新内容。
        let fresh = window.filter {
            $0.id > progress.lastRowId && !state.emittedMessageIds.contains(Self.messageKey($0.id))
        }
        guard !fresh.isEmpty || !scanned.isEmpty else { return result }
        scanned.append(contentsOf: fresh)

        result.isNewContent = !fresh.isEmpty
        var conversation = state.messages
        var indexByMessageId: [String: Int] = [:]
        for (index, message) in conversation.enumerated() {
            indexByMessageId[message.id] = index
        }

        for record in scanned {
            let isFirstEmission = state.emittedMessageIds
                .insert(Self.messageKey(record.id)).inserted
            if let chatMessage = translate(
                record, isFirstEmission: isFirstEmission, state: &state, result: &result)
            {
                if let index = indexByMessageId[chatMessage.id] {
                    // 重扫：内容变了就原地换掉（补齐后到的正文），不算新气泡。
                    if conversation[index].content != chatMessage.content {
                        conversation[index] = chatMessage
                    }
                } else {
                    indexByMessageId[chatMessage.id] = conversation.count
                    conversation.append(chatMessage)
                    result.newMessages.append(chatMessage)
                }
            }
            // 「本轮结束」可能晚到（`stop` 在首读之后才写进行里）：按行去重，重扫也算数，
            // 但只报一次。
            if record.role == "assistant", record.finishReason == "stop",
                state.emittedMessageIds.insert(Self.turnKey(record.id)).inserted
            {
                result.activity.append(.turnFinished)
            }
            // 行 id 单调递增，`advance` 只前进，重扫游标行不会把游标推回去。
            progress.advance(to: record.id)
        }

        state.messages = conversation
        state.cursor = progress.encoded
        return result
    }

    // MARK: - 消息翻译

    /// 把一行翻译成气泡，并登记副作用（工具结果、活动事件、会话元信息）。
    ///
    /// `isFirstEmission` 为假表示这是「重扫游标那条行」：只重建气泡内容与幂等的登记，
    /// 不重复上报 `.promptSubmitted`。
    private func translate(
        _ record: HermesMessageRecord,
        isFirstEmission: Bool,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> ChatMessage? {
        switch record.role {
        case "user":
            return translateUser(
                record, isFirstEmission: isFirstEmission, state: &state, result: &result)
        case "assistant":
            return translateAssistant(record, state: &state, result: &result)
        case "tool":
            translateToolResult(record, state: &state, result: &result)
            return nil
        default:
            // system 与 session_meta 等角色没有用户可见内容。
            return nil
        }
    }

    /// 用户消息：产出用户气泡，并上报一次提示词提交事件。
    private func translateUser(
        _ record: HermesMessageRecord,
        isFirstEmission: Bool,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> ChatMessage? {
        guard let text = record.text else { return nil }

        state.lastUserMessageDate = record.timestamp
        state.lastMessage = TranscriptParsing.truncate(text)
        state.lastMessageRole = ChatRole.user.rawValue
        if state.firstUserMessage == nil {
            state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
        }
        if isFirstEmission {
            result.activity.append(.promptSubmitted(text: text))
        }
        return ChatMessage(
            id: Self.messageKey(record.id),
            role: .user,
            timestamp: record.timestamp,
            content: [.text(text)]
        )
    }

    /// 助手消息：思考 / 正文 / 工具调用各产出一块。
    private func translateAssistant(
        _ record: HermesMessageRecord,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> ChatMessage? {
        var blocks: [MessageBlock] = []
        if let reasoning = record.reasoning {
            blocks.append(.thinking(reasoning))
        }
        if let text = record.text {
            blocks.append(.text(text))
        }
        for call in record.toolCalls {
            let input = Self.toolInput(call.arguments)
            blocks.append(.toolUse(ToolUseBlock(id: call.id, name: call.name, input: input)))
            // 工具结果到达时要靠这些登记推断结构化结果，因此解析出调用时就记下。
            state.toolInputs[call.id] = input
            state.toolIdToName[call.id] = call.name
            state.seenToolIds.insert(call.id)
        }
        // token：`token_count` 是单列，分不出输入与输出，**因此这里不产出任何数字**
        // （宁可没有，也不能猜）。Hermes 的每会话 token 明细在 `sessions` 表的
        // `input_tokens` / `output_tokens` 等列里，由统计路径取。
        guard !blocks.isEmpty else { return nil }
        return ChatMessage(
            id: Self.messageKey(record.id),
            role: .assistant,
            timestamp: record.timestamp,
            content: blocks
        )
    }

    /// 工具结果：按 `tool_call_id` 登记结果与结构化结果，并上报一次工具结束事件。
    private func translateToolResult(
        _ record: HermesMessageRecord,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let callId = record.toolCallId else { return }
        let name = record.toolName ?? state.toolIdToName[callId]

        let payload = ToolResultPayload(
            content: record.text, stdout: nil, stderr: nil, isError: false)
        state.toolResults[callId] = payload
        state.structuredResults[callId] = GenericToolResultBuilder.build(
            toolName: name ?? "",
            input: state.toolInputs[callId] ?? [:],
            output: record.text,
            isError: payload.isError
        )
        if state.completedToolIds.insert(callId).inserted {
            // 结束事件之后不该再出现同一调用的开始事件。
            state.seenToolIds.insert(callId)
            state.toolIdToName[callId] = name ?? ""
            result.activity.append(
                .toolFinished(id: callId, name: name, isError: payload.isError))
        }
    }

    // MARK: - 解析辅助

    /// 一行消息的键：气泡 id（行 id 唯一）；同一把钥匙也用来判「这一行是否已消费过」。
    private static func messageKey(_ rowId: Int64) -> String {
        "hermes-message-\(rowId)"
    }

    /// 「本轮结束」已上报过的行键：与气泡键分开命名空间，因为两者是不同的去重维度
    /// （气泡只在首次产出时追加，本轮结束允许在重扫时才第一次出现）。
    private static func turnKey(_ rowId: Int64) -> String {
        "hermes-turn-\(rowId)"
    }

    /// 工具入参：`arguments` 是 OpenAI 风格的 JSON 字符串；解析不出对象就原样带上，
    /// 至少让用户看到 Agent 到底传了什么。
    private static func toolInput(_ arguments: String) -> [String: String] {
        if let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let flattened = TranscriptParsing.stringifyInput(object)
            if !flattened.isEmpty { return flattened }
        }
        return arguments.isEmpty ? [:] : ["arguments": arguments]
    }
}

// MARK: - 读取游标

/// Hermes 的读取进度：已消费到的最后一条消息行 id。
///
/// 编码成 `v1|<行 id>`。`messages.id` 是自增主键、单调递增，因此它本身就是天然的增量
/// 游标（下界取它即包含那一行）；`v1` 前缀留给日后换口径。
nonisolated private struct HermesProgress {
    var lastRowId: Int64 = 0

    init(_ encoded: String?) {
        guard let encoded, encoded.hasPrefix("v1|") else { return }
        lastRowId = Int64(encoded.dropFirst(3)) ?? 0
    }

    var encoded: String { "v1|\(lastRowId)" }

    /// 推进游标（只前进，不后退：批次内行 id 已按序，重扫的游标行是同一行）。
    mutating func advance(to rowId: Int64) {
        lastRowId = max(lastRowId, rowId)
    }
}