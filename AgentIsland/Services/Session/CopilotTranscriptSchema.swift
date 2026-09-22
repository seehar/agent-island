//
//  CopilotTranscriptSchema.swift
//  AgentIsland
//
//  GitHub Copilot CLI 的事件记录。每一行是事件信封
//  `{"type":"…","data":{…},"id":"…","timestamp":"ISO8601","parentId":…}`
//  （与 CodeIsland `readRecentFromCopilotTranscript` 读的信封一致）。
//
//  本机实测（`~/.copilot/jb/<会话 id>/partition-1.jsonl`，9 个文件）出现的事件：
//    · `user.message`             `data.content` 是用户真正输入的内容 → 用户气泡
//    · `user.message_rendered`    `data.renderedMessage` 是**渲染后**的提示词
//                                 （带 `<context>` / `<reminderInstructions>` 包装），
//                                 不是用户输入，忽略它以免与上一条重复
//    · `assistant.message`        `data.content` / `data.text`（另有加密的 `data.thinking`，不解析）
//    · `tool.execution_start`     `data.toolCallId` / `data.toolName` / `data.arguments`
//    · `tool.execution_complete`  `data.toolCallId` / `data.success` / `data.result.result[].value`
//    · `assistant.turn_end`       `data.status` / `data.turnStatus`（实测为 `success`）
//
//  注意：CodeIsland 读的是 `~/.copilot/session-state/<会话 id>/events.jsonl`，
//  而本机的实际布局是 `~/.copilot/jb/<会话 id>/partition-1.jsonl`（session-state 目录
//  只有 workspace.yaml 与 checkpoints）——文件位置由 Provider 决定，与这里无关。
//
//  用量统计：本机 9 个事件文件里没有任何 token 字段（`data` 的键实测为
//  toolCallId/status/success/result/toolName/arguments/content/messageId/text/…），
//  因此不产出用量。
//

import Foundation
import os.log

/// Copilot CLI 的 JSONL 事件解析。
nonisolated final class CopilotTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .copilot }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let type = json["type"] as? String,
            let data = json["data"] as? [String: Any]
        else { return }

        switch type {
        case "user.message":
            guard let text = data["content"] as? String, !text.isEmpty else { return }
            emitUserMessage(text, json: json, rawLine: rawLine, state: &state, result: &result)

        case "assistant.message":
            guard let text = Self.assistantText(data), !text.isEmpty else { return }
            let message = ChatMessage(
                id: json["id"] as? String ?? StableHash.hash(rawLine[rawLine.startIndex...]),
                role: .assistant,
                timestamp: Self.timestamp(of: json),
                content: [.text(text)]
            )
            state.messages.append(message)
            result.newMessages.append(message)
            state.lastMessage = TranscriptParsing.truncate(text)
            state.lastMessageRole = ChatRole.assistant.rawValue
            state.lastToolName = nil

        case "tool.execution_start":
            consumeToolStart(data, state: &state, result: &result)

        case "tool.execution_complete":
            consumeToolEnd(data, state: &state, result: &result)

        case "assistant.turn_end":
            // 一轮助手输出结束（实测 `data.turnStatus == "success"`），语义与
            // Claude 的 Stop 一致：Agent 收手，回到等待用户输入。
            result.activity.append(.turnFinished)

        default:
            // `partition.created` / `assistant.turn_start` / `session.start`（cwd 元信息）
            // 等条目没有用户可见内容。
            return
        }
    }

    // MARK: - 消息

    private func emitUserMessage(
        _ text: String,
        json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        let timestamp = Self.timestamp(of: json)
        let message = ChatMessage(
            id: json["id"] as? String ?? StableHash.hash(rawLine[rawLine.startIndex...]),
            role: .user,
            timestamp: timestamp,
            content: [.text(text)]
        )
        state.messages.append(message)
        result.newMessages.append(message)

        if state.firstUserMessage == nil {
            state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
        }
        state.lastUserMessageDate = timestamp
        state.lastMessage = TranscriptParsing.truncate(text)
        state.lastMessageRole = ChatRole.user.rawValue
        state.lastToolName = nil
        result.activity.append(.promptSubmitted(text: text))
    }

    // MARK: - 工具

    private func consumeToolStart(
        _ data: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let toolCallId = data["toolCallId"] as? String, !toolCallId.isEmpty,
            let name = data["toolName"] as? String, !name.isEmpty,
            !state.seenToolIds.contains(toolCallId)
        else { return }

        let input = TranscriptParsing.stringifyInput(data["arguments"] as? [String: Any])
        state.seenToolIds.insert(toolCallId)
        state.toolIdToName[toolCallId] = name
        state.toolInputs[toolCallId] = input
        result.activity.append(.toolStarted(id: toolCallId, name: name, input: input))
    }

    private func consumeToolEnd(
        _ data: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let toolCallId = data["toolCallId"] as? String, !toolCallId.isEmpty else { return }

        let isError = (data["success"] as? Bool) == false
        let output = Self.resultText(data["result"])
        let toolName = state.toolIdToName[toolCallId]

        state.completedToolIds.insert(toolCallId)
        state.toolResults[toolCallId] = ToolResultPayload(
            content: output, stdout: nil, stderr: nil, isError: isError)
        state.structuredResults[toolCallId] = GenericToolResultBuilder.build(
            toolName: toolName ?? "",
            input: state.toolInputs[toolCallId] ?? [:],
            output: output,
            isError: isError
        )
        result.activity.append(.toolFinished(id: toolCallId, name: toolName, isError: isError))
    }

    // MARK: - 字段解析

    /// 助手正文：实测 `data.content` 与 `data.text` 同时存在（工具调用类的消息两者都为空）。
    private static func assistantText(_ data: [String: Any]) -> String? {
        for key in ["content", "text"] {
            if let text = data[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// 工具结果正文：`data.result.result[]` 里的文本块（实测形状
    /// `{"result":[{"type":"text","value":"…"}]}`）。
    private static func resultText(_ result: Any?) -> String? {
        guard let result = result as? [String: Any],
            let items = result["result"] as? [[String: Any]]
        else { return nil }
        let parts = items.compactMap { $0["value"] as? String }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 条目级 ISO8601 时间戳。
    private static func timestamp(of json: [String: Any]) -> Date {
        if let iso = json["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        return Date()
    }
}