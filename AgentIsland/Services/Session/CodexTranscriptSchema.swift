//
//  CodexTranscriptSchema.swift
//  AgentIsland
//
//  Codex 的 rollout 记录：`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<时间>-<uuid>.jsonl`
//  （缺省 `~/.codex/sessions/…`）。
//
//  每行都是 `{"timestamp":ISO8601,"type":…,"payload":{…}}`，`type` 取值与含义
//  （本机 2026-06-15 的真实记录实测）：
//    · `session_meta`  首行，`payload.cwd` / `payload.id` / `payload.model_provider`；
//    · `turn_context`  每轮一次，`payload.model` 是**模型名唯一出现的地方**；
//    · `event_msg`     用户/助手可见消息、token 计数、轮次终态；
//    · `response_item` 原始模型输入输出（消息、工具调用与结果）。
//
//  同一条消息会被写两遍（`response_item` 与 `event_msg` 各一份），因此这里按
//  「相邻重复」去重：只有与上一条同角色消息文本完全相同的行会被丢弃。
//

import Foundation
import os.log

/// Codex 的 JSONL 记录解析。
nonisolated final class CodexTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .codex }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let type = json["type"] as? String,
            let payload = json["payload"] as? [String: Any]
        else { return }

        switch type {
        case "event_msg":
            consumeEventMessage(
                payload, json: json, rawLine: rawLine, state: &state, result: &result)
        case "response_item":
            consumeResponseItem(
                payload, json: json, rawLine: rawLine, state: &state, result: &result)
        default:
            // `session_meta` / `turn_context` 只有元信息（cwd、模型、沙箱策略），
            // 没有用户可见内容；cwd 与模型由 Provider 另外读取。
            return
        }
    }

    // MARK: - event_msg

    /// `event_msg`：可见消息、token 计数与轮次终态。
    private func consumeEventMessage(
        _ payload: [String: Any],
        json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        switch payload["type"] as? String {
        case "user_message":
            guard let text = payload["message"] as? String, !text.isEmpty else { return }
            emitUserMessage(
                text, json: json, rawLine: rawLine, state: &state, result: &result)
        case "agent_message":
            guard let text = payload["message"] as? String, !text.isEmpty else { return }
            emitAssistantMessage(
                text, json: json, rawLine: rawLine, state: &state, result: &result)
        case "token_count":
            accumulateUsage(payload, into: &state)
        case "task_complete", "turn_aborted", "turn_failed":
            // 三种终态都表示「本轮结束、回到等待用户输入」。
            result.activity.append(.turnFinished)
        default:
            // `task_started` / `patch_apply_end` 等只描述过程，没有用户可见内容。
            return
        }
    }

    // MARK: - response_item

    /// `response_item`：模型输入输出（消息、工具调用与工具结果）。
    private func consumeResponseItem(
        _ payload: [String: Any],
        json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        switch payload["type"] as? String {
        case "message":
            consumeModelMessage(
                payload, json: json, rawLine: rawLine, state: &state, result: &result)
        case "function_call", "custom_tool_call":
            consumeToolCall(payload, state: &state, result: &result)
        case "function_call_output", "custom_tool_call_output":
            consumeToolOutput(payload, state: &state, result: &result)
        default:
            // `reasoning`（本机样本里只有加密载荷）与未知条目跳过。
            return
        }
    }

    /// 模型输入/输出消息。`input_text` 里混着权限说明、AGENTS.md 等注入内容，
    /// 因此注入文本一律丢弃。
    private func consumeModelMessage(
        _ payload: [String: Any],
        json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let role = payload["role"] as? String,
            role == "user" || role == "assistant"
        else { return }

        let text = Self.contentText(payload["content"])
        guard !text.isEmpty else { return }

        if role == "user" {
            if Self.isInjected(text) { return }
            emitUserMessage(text, json: json, rawLine: rawLine, state: &state, result: &result)
        } else {
            emitAssistantMessage(text, json: json, rawLine: rawLine, state: &state, result: &result)
        }
    }

    // MARK: - 消息产出

    /// 用户消息：产出气泡与「提交提示词」事件。
    ///
    /// 同一条消息在 `response_item` 与 `event_msg` 里各写一遍（本机实测两行相邻、
    /// 文本逐字相同），因此这里按相邻重复去重：与上一条用户消息文本相同时跳过。
    private func emitUserMessage(
        _ text: String,
        json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        if Self.isAdjacentDuplicate(text, role: .user, state: state) { return }

        let timestamp = Self.timestamp(of: json)
        let message = ChatMessage(
            id: StableHash.hash(rawLine[rawLine.startIndex...]),
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

    /// 助手消息：产出气泡，并维护「最后一条消息」。
    private func emitAssistantMessage(
        _ text: String,
        json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        if Self.isAdjacentDuplicate(text, role: .assistant, state: state) { return }

        let message = ChatMessage(
            id: StableHash.hash(rawLine[rawLine.startIndex...]),
            role: .assistant,
            timestamp: Self.timestamp(of: json),
            content: [.text(text)]
        )
        state.messages.append(message)
        result.newMessages.append(message)

        state.lastMessage = TranscriptParsing.truncate(text)
        state.lastMessageRole = ChatRole.assistant.rawValue
        state.lastToolName = nil
    }

    // MARK: - 工具

    /// 工具调用：`function_call.arguments` 是 JSON **字符串**，`custom_tool_call.input`
    /// 是原始文本（本机实测 `apply_patch` 的补丁正文）。
    private func consumeToolCall(
        _ payload: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let callId = payload["call_id"] as? String, !callId.isEmpty,
            let name = payload["name"] as? String, !name.isEmpty,
            !state.seenToolIds.contains(callId)
        else { return }

        var input: [String: String] = [:]
        if let arguments = payload["arguments"] as? String,
            let data = arguments.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            input = TranscriptParsing.stringifyInput(parsed)
        } else if let raw = payload["input"] as? String {
            input = ["input": raw]
        }

        state.seenToolIds.insert(callId)
        state.toolIdToName[callId] = name
        state.toolInputs[callId] = input
        result.activity.append(.toolStarted(id: callId, name: name, input: input))
    }

    /// 工具结果：登记结果与结构化结果，并上报「工具结束」。
    ///
    /// `custom_tool_call_output` 的正文以 `Exit code: N` 开头（本机实测），
    /// 非零即视为失败。
    private func consumeToolOutput(
        _ payload: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let callId = payload["call_id"] as? String, !callId.isEmpty else { return }

        let output = payload["output"] as? String
        let isError = Self.exitCodeFailure(in: output)
        let toolName = state.toolIdToName[callId]

        state.completedToolIds.insert(callId)
        state.toolResults[callId] = ToolResultPayload(
            content: output, stdout: nil, stderr: nil, isError: isError)
        state.structuredResults[callId] = GenericToolResultBuilder.build(
            toolName: toolName ?? "",
            input: state.toolInputs[callId] ?? [:],
            output: output,
            isError: isError
        )
        result.activity.append(.toolFinished(id: callId, name: toolName, isError: isError))
    }

    /// `Exit code: N` 形式的结果正文里 `N != 0` 即失败。
    private static func exitCodeFailure(in output: String?) -> Bool {
        guard let output, let range = output.range(of: "Exit code: ") else { return false }
        let digits = output[range.upperBound...].prefix { $0.isNumber }
        guard let code = Int(digits) else { return false }
        return code != 0
    }

    // MARK: - 用量

    /// token 计数：`payload.info.last_token_usage` 是**本次调用**的增量
    /// （`total_token_usage` 是整会话累计值，不能直接用）。
    ///
    /// 字段口径（本机实测 `last_token_usage`）：
    ///   · `input_tokens` 含 `cached_input_tokens`，相减后才是「非缓存输入」，
    ///     否则缓存读会被重复计入总量；
    ///   · `output_tokens` 即输出（`reasoning_output_tokens` 本机样本恒为 0，
    ///     无法判定它是否已含在 output 里，因此不单独叠加）；
    ///   · 没有缓存写字段，`cacheWrite` 恒为 0。
    private func accumulateUsage(_ payload: [String: Any], into state: inout TranscriptParseState) {
        guard let info = payload["info"] as? [String: Any],
            let last = info["last_token_usage"] as? [String: Any]
        else { return }

        let input = Self.intValue(last["input_tokens"])
        let cached = Self.intValue(last["cached_input_tokens"])
        state.usage.inputTokens += max(0, input - cached)
        state.usage.cacheReadTokens += cached
        state.usage.outputTokens += Self.intValue(last["output_tokens"])
    }

    // MARK: - 字段解析

    /// 条目级 ISO8601 时间戳。
    private static func timestamp(of json: [String: Any]) -> Date {
        if let iso = json["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        return Date()
    }

    /// 取 `content` 数组里的文本（Codex 的消息分成 `input_text` / `output_text` 两类块）。
    private static func contentText(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            guard let type = block["type"] as? String,
                type == "input_text" || type == "output_text" || type == "text",
                let text = block["text"] as? String, !text.isEmpty
            else { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    /// Codex 注入的伪用户消息（权限说明、AGENTS.md、环境上下文等）。
    private static func isInjected(_ text: String) -> Bool {
        let prefixes = [
            "<permissions instructions>", "<INSTRUCTIONS>", "<user_instructions>",
            "<environment_context>", "# AGENTS.md",
        ]
        return prefixes.contains { text.hasPrefix($0) }
    }

    /// 与上一条同角色消息文本完全相同时判为重复（同一条消息被写两遍）。
    private static func isAdjacentDuplicate(
        _ text: String, role: ChatRole, state: TranscriptParseState
    ) -> Bool {
        state.lastMessageRole == role.rawValue && state.lastMessage == TranscriptParsing.truncate(text)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber, !(number is Bool) { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }
}