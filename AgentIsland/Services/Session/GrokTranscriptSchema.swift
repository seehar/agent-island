//
//  GrokTranscriptSchema.swift
//  AgentIsland
//
//  Grok CLI 的会话记录：
//  `$GROK_HOME/sessions/<百分号编码的 cwd>/<会话 id>/chat_history.jsonl`
//  （`GROK_HOME` 缺省 `~/.grok`；同一目录下还有 `summary.json`、`events.jsonl`、
//  `updates.jsonl`）。
//
//  行的可见文本形状与 CodeIsland 的增量读取器一致（`JSONLTailer.apply` +
//  `CodeIslandBridge/main.swift:308` 的注释「chat_history.jsonl uses the
//  user/assistant row shapes already understood by the incremental tailer」）：
//    · `type` 为 `user` / `USER_INPUT` → 用户消息
//    · `type` 为 `assistant` / `PLANNER_RESPONSE` → 助手消息
//      （没有文本时回落到 `message.thinking`）
//    · 正文取 `message.content`（字符串，或 `[{type:"text",text}]` 块数组）
//
//  未能验证的部分：本机没有 `~/.grok`（没有记录可读），因此工具块形状无从核对；
//  这里按 Anthropic 工具协议容忍解析 `tool_use` / `tool_result` 块，形状不符时
//  自然产出为空。用量统计：记录里未观察到 token 字段，不产出用量。
//

import Foundation
import os.log

/// Grok CLI 的 JSONL 记录解析。
nonisolated final class GrokTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .grok }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        let message = json["message"] as? [String: Any] ?? json
        guard let role = Self.role(json: json, message: message) else { return }

        var content: [MessageBlock] = []
        var toolCalls: [(id: String, name: String, input: [String: String])] = []
        var toolOutputs: [(id: String, isError: Bool)] = []

        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text", "input_text", "output_text":
                if let text = block["text"] as? String, !text.isEmpty {
                    content.append(.text(text))
                }
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    content.append(.thinking(thinking))
                }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else {
                    continue
                }
                let input = TranscriptParsing.stringifyInput(block["input"] as? [String: Any])
                content.append(.toolUse(ToolUseBlock(id: id, name: name, input: input)))
                toolCalls.append((id: id, name: name, input: input))
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                let isError = block["is_error"] as? Bool ?? false
                state.toolResults[id] = ToolResultPayload(
                    content: block["content"] as? String, stdout: nil, stderr: nil, isError: isError)
                state.completedToolIds.insert(id)
                toolOutputs.append((id: id, isError: isError))
            default:
                continue
            }
        }

        // 正文是字符串时（没有内容块数组）。
        if content.isEmpty, let text = Self.stringContent(message["content"]), !text.isEmpty {
            content.append(.text(text))
        }
        // 助手消息没有正文时回落到 `message.thinking`（与 CodeIsland 的读取一致）。
        if content.isEmpty, role == .assistant, let thinking = message["thinking"] as? String,
            !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            content.append(.thinking(thinking))
        }

        guard !content.isEmpty || !toolOutputs.isEmpty else { return }

        let timestamp = Self.timestamp(of: json)
        if !content.isEmpty {
            let chatMessage = ChatMessage(
                id: json["id"] as? String ?? message["id"] as? String
                    ?? StableHash.hash(rawLine[rawLine.startIndex...]),
                role: role,
                timestamp: timestamp,
                content: content
            )
            state.messages.append(chatMessage)
            result.newMessages.append(chatMessage)

            let text = TranscriptParsing.firstText(in: content)
            if role == .user, let text {
                if state.firstUserMessage == nil {
                    state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
                }
                state.lastUserMessageDate = timestamp
                result.activity.append(.promptSubmitted(text: text))
            }
            if let text {
                state.lastMessage = TranscriptParsing.truncate(text)
                state.lastMessageRole = role.rawValue
                state.lastToolName = nil
            }
        }

        for call in toolCalls {
            guard !state.seenToolIds.contains(call.id) else { continue }
            state.seenToolIds.insert(call.id)
            state.toolIdToName[call.id] = call.name
            state.toolInputs[call.id] = call.input
            result.activity.append(.toolStarted(id: call.id, name: call.name, input: call.input))
        }

        for output in toolOutputs {
            let name = state.toolIdToName[output.id]
            state.structuredResults[output.id] = GenericToolResultBuilder.build(
                toolName: name ?? "",
                input: state.toolInputs[output.id] ?? [:],
                output: state.toolResults[output.id]?.content,
                isError: output.isError
            )
            result.activity.append(.toolFinished(id: output.id, name: name, isError: output.isError))
        }
    }

    // MARK: - 字段解析

    /// 角色：`type`（增量读取器用的字段）或 `role`（记录里另一处可能出现的位置）。
    private static func role(json: [String: Any], message: [String: Any]) -> ChatRole? {
        let raw = (json["type"] as? String) ?? (json["role"] as? String)
            ?? (message["role"] as? String)
        switch raw?.lowercased() {
        case "user", "user_input": return .user
        case "assistant", "planner_response": return .assistant
        default: return nil
        }
    }

    /// 字符串形态的正文（`message.content` 是字符串时）。
    private static func stringContent(_ content: Any?) -> String? {
        guard let text = content as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 条目级时间戳；缺失时取当前时间。
    private static func timestamp(of json: [String: Any]) -> Date {
        if let iso = json["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        if let milliseconds = json["timestamp"] as? NSNumber, !(milliseconds is Bool) {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        return Date()
    }
}