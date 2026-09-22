//
//  CursorTranscriptSchema.swift
//  AgentIsland
//
//  Cursor 的记录：`~/.cursor/projects/<编码工程>/agent-transcripts/<会话 id>/<会话 id>.jsonl`，
//  子 Agent 另存为同目录下的 `subagents/<子会话 id>.jsonl`。
//
//  记录行按**顶层 `role`** 区分（Claude 系用 `type`）：
//    {"role":"user","message":{"content":[{"type":"text","text":"…"}]}}
//  文本里包着 Cursor 自己加的包装（`<timestamp>…</timestamp>` 与 `<user_query>…</user_query>`），
//  渲染对话时要剥掉——与 CodeIsland `JSONLTailer.normalizedCursorChatText` 一致。
//
//  未能验证的部分：本机 `~/.cursor` 只有 `skills`（没有 projects/agent-transcripts），
//  因此工具块形状、时间戳字段均来自 CodeIsland 的实现（`JSONLTailer.applyCursorRoleLine`
//  按 `content[].type == "tool_use"` 取 `name`/`input`；`CursorSessionFolding` 给出
//  subagents 布局）。用量统计：记录里没有 token 字段（CodeIsland 也只读文本），
//  因此不产出用量。
//

import Foundation
import os.log

/// Cursor 的 JSONL 记录解析。
nonisolated final class CursorTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .cursor }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let role = json["role"] as? String, role == "user" || role == "assistant" else {
            return
        }
        let message = json["message"] as? [String: Any] ?? json

        var content: [MessageBlock] = []
        var toolCalls: [(id: String, name: String, input: [String: String])] = []
        var toolOutputs: [(id: String, isError: Bool)] = []

        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text", "input_text", "output_text":
                guard let text = Self.normalizedText(block["text"] as? String), !text.isEmpty else {
                    continue
                }
                content.append(.text(text))
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    content.append(.thinking(thinking))
                }
            case "tool_use":
                guard let id = block["id"] as? String,
                    let name = block["name"] as? String
                else { continue }
                let input = TranscriptParsing.stringifyInput(block["input"] as? [String: Any])
                content.append(.toolUse(ToolUseBlock(id: id, name: name, input: input)))
                toolCalls.append((id: id, name: name, input: input))
            case "tool_result":
                // 本机无样本、CodeIsland 也不读这种块：按 Claude 的字段名容忍处理，
                // 形状不符时自然产出为空。
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

        guard !content.isEmpty || !toolOutputs.isEmpty else { return }

        let timestamp = Self.timestamp(of: json, message: message)
        if !content.isEmpty {
            let isUser = role == "user"
            let chatMessage = ChatMessage(
                id: json["id"] as? String ?? message["id"] as? String
                    ?? StableHash.hash(rawLine[rawLine.startIndex...]),
                role: isUser ? .user : .assistant,
                timestamp: timestamp,
                content: content
            )
            state.messages.append(chatMessage)
            result.newMessages.append(chatMessage)

            let text = TranscriptParsing.firstText(in: content)
            if isUser, let text {
                if state.firstUserMessage == nil {
                    state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
                }
                state.lastUserMessageDate = timestamp
                result.activity.append(.promptSubmitted(text: text))
            }
            if let text {
                state.lastMessage = TranscriptParsing.truncate(text)
                state.lastMessageRole = isUser ? ChatRole.user.rawValue : ChatRole.assistant.rawValue
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

    /// 剥掉 Cursor 包装：先删所有 `<timestamp>…</timestamp>`，再取 `<user_query>…</user_query>`
    /// 的内部文本（与 `JSONLTailer.normalizedCursorChatText` 的处理顺序一致）。
    static func normalizedText(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        while let start = text.range(of: "<timestamp>"),
            let end = text.range(of: "</timestamp>", range: start.upperBound..<text.endIndex)
        {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let start = text.range(of: "<user_query>"),
            let end = text.range(of: "</user_query>", range: start.upperBound..<text.endIndex)
        {
            text = String(text[start.upperBound..<end.lowerBound])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 条目级时间戳；Cursor 记录里未观察到时间戳字段（CodeIsland 也不读），缺失时取当前时间。
    private static func timestamp(of json: [String: Any], message: [String: Any]) -> Date {
        for candidate in [json["timestamp"], message["timestamp"]] {
            if let iso = candidate as? String,
                let date = TranscriptParsing.isoFormatter.date(from: iso)
            {
                return date
            }
            if let milliseconds = candidate as? NSNumber, !(milliseconds is Bool) {
                return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
            }
        }
        return Date()
    }
}