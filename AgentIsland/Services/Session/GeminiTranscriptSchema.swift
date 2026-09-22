//
//  GeminiTranscriptSchema.swift
//  AgentIsland
//
//  Gemini CLI 的会话记录：`~/.gemini/tmp/<工程哈希>/chats/session-<时间>-<id>.jsonl`。
//  首行是头部记录（没有 `type`）：
//    {"sessionId":"a2a-server","projectHash":"8a5edab…","startTime":"…",
//     "lastUpdated":"…","kind":"main"}
//  其后每行一条消息。消息行的角色取自 `type`：`user` 是用户，其余（`gemini` 等）
//  视为助手（与 CodeIsland `readRecentFromGeminiTranscript` 的判定一致：只有
//  `type == "user"` 走用户分支），`info` / `error` / `warning` 是 CLI 自己的提示，
//  不产出对话内容。
//
//  未能验证的部分（写代码时请勿当既定事实）：
//    · 本机没有任何带消息的样本（只有一行头部的空会话），因此消息行的字段
//      （`type` 的具体取值、`content` 块形状、时间戳字段名）来自上一条注释里的
//      CodeIsland 实现与 gemini 的 `Content` 协议形状；
//    · token 用量：gemini CLI 会在消息里记 token 计数，但本机无从核对字段名与
//      语义（是单次增量还是累计值），因此这里**不统计用量**，也不把猜测写进
//      `UsageInfo`（宁可没有数字，也不给出错数字）。
//

import Foundation
import os.log

/// Gemini CLI 的 JSONL 记录解析。
nonisolated final class GeminiTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .gemini }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        // 头部记录只有工程哈希等元信息。
        guard let type = json["type"] as? String else { return }

        let normalized = type.lowercased()
        switch normalized {
        case "info", "error", "warning":
            // CLI 的运行提示（重试、配额、报错），不是对话内容。
            return
        default:
            break
        }

        var content: [MessageBlock] = []
        var toolCalls: [(id: String, name: String, input: [String: String])] = []
        var toolOutputs: [(id: String, name: String?, output: String?, isError: Bool)] = []

        if let text = json["content"] as? String {
            if !text.isEmpty { content.append(.text(text)) }
        } else if let blocks = json["content"] as? [[String: Any]] {
            for (index, block) in blocks.enumerated() {
                if let text = block["text"] as? String, !text.isEmpty {
                    content.append(.text(text))
                    continue
                }
                // gemini 的工具调用/结果块（模型面协议形状）：`functionCall` / `functionResponse`。
                if let call = block["functionCall"] as? [String: Any] {
                    let name = call["name"] as? String ?? block["name"] as? String ?? "Tool"
                    let id = block["id"] as? String
                        ?? StableHash.hash("gemini-call|\(rawLine)|\(index)")
                    let input = TranscriptParsing.stringifyInput(call["args"] as? [String: Any])
                    let tool = ToolUseBlock(id: id, name: name, input: input)
                    content.append(.toolUse(tool))
                    toolCalls.append((id: id, name: name, input: input))
                    continue
                }
                if let response = block["functionResponse"] as? [String: Any] {
                    let name = response["name"] as? String ?? block["name"] as? String
                    let id = block["id"] as? String ?? Self.toolId(forName: name, state: state)
                    guard let id else { continue }
                    toolOutputs.append(
                        (id: id, name: name, output: Self.outputText(response), isError: false))
                }
            }
        }

        guard !content.isEmpty || !toolOutputs.isEmpty else { return }

        let timestamp = Self.timestamp(of: json)
        if !content.isEmpty {
            let isUser = normalized == "user"
            let message = ChatMessage(
                id: json["id"] as? String ?? StableHash.hash(rawLine[rawLine.startIndex...]),
                role: isUser ? .user : .assistant,
                timestamp: timestamp,
                content: content
            )
            state.messages.append(message)
            result.newMessages.append(message)

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
            result.activity.append(
                .toolStarted(id: call.id, name: call.name, input: call.input))
        }

        for output in toolOutputs {
            state.completedToolIds.insert(output.id)
            state.toolResults[output.id] = ToolResultPayload(
                content: output.output, stdout: nil, stderr: nil, isError: output.isError)
            let name = output.name ?? state.toolIdToName[output.id]
            state.structuredResults[output.id] = GenericToolResultBuilder.build(
                toolName: name ?? "",
                input: state.toolInputs[output.id] ?? [:],
                output: output.output,
                isError: output.isError
            )
            result.activity.append(
                .toolFinished(id: output.id, name: name, isError: output.isError))
        }
    }

    // MARK: - 字段解析

    /// 条目级 ISO8601 时间戳（gemini 头部记录的 `startTime` 形态即 `2026-06-03T07:46:25.124Z`）。
    private static func timestamp(of json: [String: Any]) -> Date {
        if let iso = json["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        return Date()
    }

    /// 没带 id 的工具结果：回落到「同名且尚未完成的最后一个工具调用」。
    ///
    /// 记录里若带 `id`（模型面协议里 `functionCall` / `functionResponse` 可以配对），
    /// 上面的分支会优先用它，这里只是裸字段时的兜底。
    private static func toolId(forName name: String?, state: TranscriptParseState) -> String? {
        guard let name else { return nil }
        return state.toolIdToName
            .filter { $0.value == name && !state.completedToolIds.contains($0.key) }
            .keys.sorted().last
    }

    /// 工具结果的文本：优先 `response.output`（字符串或 `{text}` 块），其次是 `response` 本身。
    private static func outputText(_ response: [String: Any]) -> String? {
        if let text = response["output"] as? String { return text }
        if let output = response["output"] as? [String: Any], let text = output["text"] as? String {
            return text
        }
        if let text = response["response"] as? String { return text }
        if let error = response["error"] as? String { return error }
        return nil
    }
}