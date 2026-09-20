//
//  PiTranscriptSchema.swift
//  ClaudeIsland
//
//  pi 系 CLI（Oh My Pi 与 Pi）的会话记录解析。两个 Agent 的记录同源
//  （version 3，逐行追加），因此共用同一份实现，只由 `kind` 决定记录文件位置。
//

import Foundation

/// pi / omp 的 JSONL 会话记录解析器。
///
/// 记录里的工具调用写在 assistant 消息的 content 中，工具结果是与 assistant
/// 平级的 `toolResult` 消息，因此这里不需要 Claude 那种「整条记录里挖
/// tool_result 块」的旁路。
final class PiTranscriptSchema: JSONLTranscriptSchema {
    /// 本 schema 服务的 Agent（`.ohMyPi` 或 `.pi`）。
    let kind: AgentKind

    nonisolated init(kind: AgentKind) {
        self.kind = kind
    }

    override var agent: AgentKind { kind }

    // MARK: - 实例缓存

    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedSchemas: [AgentKind: PiTranscriptSchema] = [:]

    /// 取某个 pi 系 Agent 的解析器。解析过程没有实例级可变状态，因此两个
    /// Agent 各缓存一个实例复用即可。
    nonisolated static func schema(for kind: AgentKind) -> PiTranscriptSchema {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedSchemas[kind] {
            return cached
        }
        let schema = PiTranscriptSchema(kind: kind)
        cachedSchemas[kind] = schema
        return schema
    }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        switch json["type"] as? String {
        case "session":
            // 头部记录：cwd 等元信息由 Provider 另行读取，这里不产出内容。
            return
        case "title", "title_change":
            // omp 的定宽 title 槽与 pi 的 title_change 语义一致：取最后一次标题。
            if let title = json["title"] as? String, !title.isEmpty {
                state.summary = title
            }
            return
        case "reset_boundary":
            result.resetDetected = true
            result.activity.append(.sessionReset)
            return
        case "message":
            guard let message = json["message"] as? [String: Any],
                let role = message["role"] as? String
            else { return }
            switch role {
            case "user":
                consumeUserMessage(json, rawLine: rawLine, message: message, state: &state, result: &result)
            case "assistant":
                consumeAssistantMessage(json, rawLine: rawLine, message: message, state: &state, result: &result)
            case "toolResult":
                consumeToolResult(message: message, state: &state, result: &result)
            case "bashExecution", "pythonExecution":
                consumeExecutionMessage(
                    json, rawLine: rawLine, message: message, state: &state, result: &result)
            default:
                return
            }
        default:
            // compaction / branch_summary / model_change / session_init / custom /
            // hookMessage 等条目没有用户可见内容。
            return
        }
    }

    // MARK: - 各类消息

    /// 用户消息：产出用户气泡，并维护标题、末条消息与「用户提交提示词」事件。
    private func consumeUserMessage(
        _ json: [String: Any],
        rawLine: String,
        message: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        var blocks: [MessageBlock] = []
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    blocks.append(.text(text))
                }
            case "image":
                if let image = Self.imageBlock(from: block) {
                    blocks.append(.image(image))
                }
            default:
                continue
            }
        }

        let text = TranscriptParsing.firstText(in: blocks)
        let date = Self.timestamp(of: json, message: message)

        // 首条用户消息作为标题兜底，注入类文本（命令回显、系统提示）不算。
        if state.firstUserMessage == nil, let text, !Self.isInjectedText(text) {
            state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
        }
        if let text {
            state.lastMessage = TranscriptParsing.truncate(text)
            state.lastMessageRole = ChatRole.user.rawValue
        }
        state.lastUserMessageDate = date

        if !blocks.isEmpty {
            let chatMessage = ChatMessage(
                id: Self.messageId(json, rawLine: rawLine),
                role: .user,
                timestamp: date,
                content: blocks
            )
            result.newMessages.append(chatMessage)
            state.messages.append(chatMessage)
        }

        // `attribution` 为 `"agent"` 表示这条消息是 Agent 自己续写的提示词，
        // 不是用户提交（扩展上报的实时事件同理，因此不产生该事件）。
        if message["attribution"] as? String != "agent" {
            result.activity.append(.promptSubmitted(text: text))
        }
    }

    /// assistant 消息：产出助手气泡，工具调用额外产生 started 事件。
    private func consumeAssistantMessage(
        _ json: [String: Any],
        rawLine: String,
        message: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        var blocks: [MessageBlock] = []
        var toolCalls: [ToolUseBlock] = []
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    blocks.append(.thinking(thinking))
                }
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    blocks.append(.text(text))
                }
            case "toolCall":
                guard let id = block["id"] as? String, let name = block["name"] as? String else {
                    continue
                }
                let input = TranscriptParsing.stringifyInput(block["arguments"] as? [String: Any])
                let tool = ToolUseBlock(id: id, name: name, input: input)
                blocks.append(.toolUse(tool))
                toolCalls.append(tool)
            default:
                continue
            }
        }

        if !blocks.isEmpty {
            let chatMessage = ChatMessage(
                id: Self.messageId(json, rawLine: rawLine),
                role: .assistant,
                timestamp: Self.timestamp(of: json, message: message),
                content: blocks
            )
            result.newMessages.append(chatMessage)
            state.messages.append(chatMessage)
        }

        // 每次工具调用只上报一次（增量读取会再次经过同一批记录）。
        for tool in toolCalls where !state.seenToolIds.contains(tool.id) {
            state.seenToolIds.insert(tool.id)
            state.toolIdToName[tool.id] = tool.name
            state.toolInputs[tool.id] = tool.input
            result.activity.append(.toolStarted(id: tool.id, name: tool.name, input: tool.input))
        }

        // 末条消息取消息内最后一段内容；含工具调用时按 Claude 的语义记成 tool。
        for block in blocks.reversed() {
            if case .toolUse(let tool) = block {
                state.lastMessage = TranscriptParsing.truncate(Self.toolSummary(for: tool))
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

        if let usage = message["usage"] as? [String: Any] {
            Self.accumulateUsage(usage, into: &state)
        }
    }

    /// 工具结果：与 Claude 一致，只登记结果，不产出聊天气泡。
    private func consumeToolResult(
        message: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let toolCallId = message["toolCallId"] as? String, !toolCallId.isEmpty else {
            return
        }
        let isError = message["isError"] as? Bool ?? false
        let toolName = message["toolName"] as? String ?? state.toolIdToName[toolCallId]

        let output = Self.joinedText(message["content"])
        state.toolResults[toolCallId] = ToolResultPayload(
            content: output,
            stdout: nil,
            stderr: nil,
            isError: isError
        )
        // pi/omp 只给文本结果，这里按工具名推断出统一的结构化结果，聊天视图即可复用 Claude 的渲染
        state.structuredResults[toolCallId] = GenericToolResultBuilder.build(
            toolName: toolName ?? state.toolIdToName[toolCallId] ?? "",
            input: state.toolInputs[toolCallId] ?? [:],
            output: output,
            isError: isError
        )
        state.completedToolIds.insert(toolCallId)
        result.activity.append(.toolFinished(id: toolCallId, name: toolName, isError: isError))
    }

    /// bash / python 执行记录：只有一条汇总文本，不产生工具事件。
    private func consumeExecutionMessage(
        _ json: [String: Any],
        rawLine: String,
        message: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        let command = message["command"] as? String
        let output =
            Self.firstString(in: message, keys: ["output", "stdout", "result"])
            ?? Self.joinedText(message["content"])
        let segments = [command, output].compactMap { $0 }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return }

        let summary = TranscriptParsing.truncate(segments.joined(separator: "\n"), maxLength: 400)
        let chatMessage = ChatMessage(
            id: Self.messageId(json, rawLine: rawLine),
            role: .assistant,
            timestamp: Self.timestamp(of: json, message: message),
            content: [.text(summary ?? "")]
        )
        result.newMessages.append(chatMessage)
        state.messages.append(chatMessage)
    }

    // MARK: - 字段解析

    /// 条目 id；理论上必定存在，缺失时用整行内容算一个稳定 id，避免空 id 进入列表。
    private static func messageId(_ json: [String: Any], rawLine: String) -> String {
        if let id = json["id"] as? String, !id.isEmpty {
            return id
        }
        return StableHash.hash(rawLine[rawLine.startIndex...])
    }

    /// 时间戳优先取消息内的毫秒 epoch，其次取条目的 ISO8601 字符串。
    private static func timestamp(of json: [String: Any], message: [String: Any]) -> Date {
        if let milliseconds = message["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        if let iso = json["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        return Date()
    }

    /// 图片块：兼容 Claude 的 `source` 嵌套与 pi 的平铺两种形状。
    private static func imageBlock(from block: [String: Any]) -> ImageBlock? {
        if let source = block["source"] as? [String: Any],
            let mediaType = source["media_type"] as? String,
            let data = source["data"] as? String
        {
            return ImageBlock(mediaType: mediaType, base64Data: data)
        }
        if let data = block["data"] as? String,
            let mediaType = block["mimeType"] as? String ?? block["media_type"] as? String
        {
            return ImageBlock(mediaType: mediaType, base64Data: data)
        }
        return nil
    }

    /// 把 `content` 字段（字符串或 text 块数组）拼成一段文本。
    private static func joinedText(_ content: Any?) -> String? {
        if let text = content as? String {
            return text.isEmpty ? nil : text
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// 按给定顺序取第一个非空字符串字段。
    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 工具调用在列表里的摘要文本：命令、文件、模式等最常用的入参优先。
    private static func toolSummary(for tool: ToolUseBlock) -> String {
        let preferred = ["command", "file_path", "path", "pattern", "i"]
        if let value = firstString(in: tool.input, keys: preferred) {
            return value
        }
        for key in tool.input.keys.sorted() {
            if let value = tool.input[key], !value.isEmpty {
                return value
            }
        }
        return ""
    }

    /// 累加 token 用量（`cacheWrite` 对应统一的 `cacheCreationTokens`）。
    private static func accumulateUsage(
        _ usage: [String: Any],
        into state: inout TranscriptParseState
    ) {
        state.usage.inputTokens += (usage["input"] as? NSNumber)?.intValue ?? 0
        state.usage.outputTokens += (usage["output"] as? NSNumber)?.intValue ?? 0
        state.usage.cacheReadTokens += (usage["cacheRead"] as? NSNumber)?.intValue ?? 0
        state.usage.cacheCreationTokens += (usage["cacheWrite"] as? NSNumber)?.intValue ?? 0
    }

    /// 命令回显、系统提示等注入文本，不参与标题兜底。
    private static func isInjectedText(_ text: String) -> Bool {
        text.hasPrefix("<command-name>") || text.hasPrefix("<local-command")
            || text.hasPrefix("Caveat:")
    }
}