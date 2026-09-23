//
//  ClaudeFamilyTranscriptSchema.swift
//  AgentIsland
//
//  Claude Code 系（Qoder / Factory / CodeBuddy）的记录解析。
//
//  Qoder 与 Factory 的记录格式与 Claude 完全一致（同一份 hook 契约派生），因此
//  这里不抄第二份解析逻辑：把 `ClaudeTranscriptSchema` 的记录翻译以组合方式复用，
//  只把「记录文件在哪」按各自 Agent 交给 Provider。
//
//  CodeBuddy 的记录外壳不同（`type: "message"` + 顶层 `role` + `input_text` 内容块），
//  复用 Claude 的翻译会一行都读不出来，因此单独实现一份翻译。
//

import Foundation
import os.log

/// Qoder / Factory 的记录解析：翻译逻辑复用 Claude，记录位置按 Agent 解析。
nonisolated final class ClaudeFamilyTranscriptSchema: JSONLTranscriptSchema {
    /// 本 schema 服务的 Agent（`.qoder` 或 `.factory`）。
    let kind: AgentKind

    /// Claude 的记录翻译器。翻译只依赖传入的解析状态，没有实例级可变状态，
    /// 因此几个 Agent 共用一份实例即可。
    private let translator = ClaudeTranscriptSchema()

    init(kind: AgentKind) {
        self.kind = kind
        super.init()
    }

    override var agent: AgentKind { kind }

    /// 记录行与 Claude 一致（`uuid` / `type` / `message.content` 等），直接交给
    /// Claude 的翻译逻辑；`/clear`、`isMeta`、注入文本、工具结果等语义随之保持一致。
    ///
    /// 子 Agent 记录（`subagentTools`）不接管：Claude 的子 Agent 文件布局
    /// （`<会话 id>/subagents/agent-<id>.jsonl`）是 Claude Code 专有的，fork 是否
    /// 沿用未经验证，宁可不认（协议默认返回空）。
    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        translator.consumeRecord(json, rawLine: rawLine, state: &state, result: &result)
    }
}

/// CodeBuddy 的记录解析。
///
/// 记录外壳（本机实测 `~/.codebuddy/projects/<编码 cwd>/<会话 id>.jsonl`）：
/// ```
/// {"id":"c98224eb-…","timestamp":1782725749544,"type":"message","role":"user",
///  "content":[{"type":"input_text","text":"…"}],"providerData":{"skipRun":true},
///  "sessionId":"2ddf93e4-…","cwd":"/Users/…"}
/// ```
/// 与 Claude 的三处差异：`timestamp` 是**毫秒 epoch 整数**（Claude 是 ISO8601 字符串）、
/// 角色写在顶层 `role`（不在 `message` 里）、内容块类型是 `input_text`/`output_text`。
/// 另外还有 `file-history-snapshot` 这类没有对话内容的行，直接忽略。
nonisolated final class CodeBuddyTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .codeBuddy }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let type = json["type"] as? String else { return }

        // 顶层 `function_call` 行先处理：它没有 `message` 数据，落进下面会被静默忽略。
        if type == "function_call" {
            _ = consumeFunctionCall(json, state: &state, result: &result)
            return
        }

        guard type == "message",
            let role = json["role"] as? String,
            role == "user" || role == "assistant"
        else { return }

        let blocks = json["content"] as? [[String: Any]] ?? []

        // 工具结果行：只登记结果，不产出对话气泡（与 Claude 的语义一致）。
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            consumeToolResults(blocks, state: &state, result: &result)
            return
        }

        var content: [MessageBlock] = []
        for block in blocks {
            switch block["type"] as? String {
            case "input_text", "output_text", "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    content.append(.text(text))
                }
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    content.append(.thinking(thinking))
                }
            case "tool_use":
                if let tool = Self.toolUse(block) {
                    content.append(.toolUse(tool))
                }
            default:
                continue
            }
        }

        guard !content.isEmpty else { return }

        let text = TranscriptParsing.firstText(in: content)
        // 注入类文本（斜杠命令回显、命令输出、系统提醒）不算对话内容，整行跳过——
        // 与 Claude 的记录解析一致；本机的 CodeBuddy 样本里 4 行全是这类行。
        if role == "user", let text, Self.isInjected(text) { return }

        let timestamp = Self.timestamp(of: json)
        let chatMessage = ChatMessage(
            id: json["id"] as? String ?? StableHash.hash(rawLine[rawLine.startIndex...]),
            role: role == "user" ? .user : .assistant,
            timestamp: timestamp,
            content: content
        )
        state.messages.append(chatMessage)
        result.newMessages.append(chatMessage)

        if role == "user", let text {
            if state.firstUserMessage == nil {
                state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
            }
            state.lastUserMessageDate = timestamp
            result.activity.append(.promptSubmitted(text: text))
        }

        updateLastMessage(content: content, role: role, state: &state)

        for block in content {
            if case .toolUse(let tool) = block {
                state.seenToolIds.insert(tool.id)
                state.toolIdToName[tool.id] = tool.name
                state.toolInputs[tool.id] = tool.input
                result.activity.append(
                    .toolStarted(id: tool.id, name: tool.name, input: tool.input))
            }
        }

        // 用量：`message.usage`（**每次调用的增量**，与 `providerData.usage` 同源）。
        // `input_tokens` 含缓存命中，要减去 `cache_read_input_tokens` 才是非缓存输入
        // （与 Claude / Codex 的口径一致，见 TranscriptUsageScanner.applyCodeBuddyUsage）。
        if let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] {
            let cached = Self.intValue(usage["cache_read_input_tokens"])
            let prompt = Self.intValue(usage["input_tokens"])
            state.usage.inputTokens += max(0, prompt - cached)
            state.usage.outputTokens += Self.intValue(usage["output_tokens"])
            state.usage.cacheReadTokens += cached
            state.usage.cacheCreationTokens += Self.intValue(usage["cache_creation_input_tokens"])
        }
    }

    /// 顶层 `function_call` 行：一次工具调用（`name` / `callId` 在顶层），没有任何
    /// 对话文本，与 Claude 的 `tool_use` 块同义（返回假表示这行不是工具调用）。
    private func consumeFunctionCall(
        _ json: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) -> Bool {
        guard (json["type"] as? String) == "function_call",
            let name = json["name"] as? String, !name.isEmpty
        else { return false }

        // 调用 id 取 `callId`（`id` 与 `messageId` 同值，是那条消息的 id，不是调用 id）。
        guard let callId = json["callId"] as? String, !callId.isEmpty else { return false }
        let input = TranscriptParsing.stringifyInput(
            json["arguments"] as? [String: Any])
        state.seenToolIds.insert(callId)
        state.toolIdToName[callId] = name
        state.toolInputs[callId] = input
        result.activity.append(.toolStarted(id: callId, name: name, input: input))
        return true
    }

    /// 从字典里取整数（字段是字符串的数字也认）。
    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber, !(number is Bool) { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    // MARK: - 工具

    /// 解析一个工具调用块。
    ///
    /// 本机 2 个记录文件里都只有用户文本行（4 行），助手/工具行的具体形状无法验证；
    /// 这里按 Anthropic 工具协议（CodeBuddy 与 Claude Code 同源）容忍解析，
    /// 形状不符时自然产出为空，不会把别的内容误报成工具调用。
    private static func toolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String, let name = block["name"] as? String else {
            return nil
        }
        return ToolUseBlock(
            id: id, name: name,
            input: TranscriptParsing.stringifyInput(block["input"] as? [String: Any]))
    }

    /// 解析工具结果块：登记结果内容与结构化结果，并上报「工具结束」。
    private func consumeToolResults(
        _ blocks: [[String: Any]],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        for block in blocks {
            guard block["type"] as? String == "tool_result",
                let toolUseId = block["tool_use_id"] as? String
            else { continue }

            let isError = block["is_error"] as? Bool ?? false
            let content = block["content"] as? String
            state.completedToolIds.insert(toolUseId)
            state.toolResults[toolUseId] = ToolResultPayload(
                content: content, stdout: nil, stderr: nil, isError: isError)
            let toolName = state.toolIdToName[toolUseId]
            state.structuredResults[toolUseId] = GenericToolResultBuilder.build(
                toolName: toolName ?? "",
                input: state.toolInputs[toolUseId] ?? [:],
                output: content,
                isError: isError
            )
            result.activity.append(
                .toolFinished(id: toolUseId, name: toolName, isError: isError))
        }
    }

    // MARK: - 字段解析

    /// 毫秒 epoch 时间戳；缺失或形态不符时退化为当前时间（与 Claude 的兜底一致）。
    private static func timestamp(of json: [String: Any]) -> Date {
        if let milliseconds = json["timestamp"] as? NSNumber, !(milliseconds is Bool) {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        if let iso = json["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        return Date()
    }

    /// 注入的伪用户消息（斜杠命令、命令输出、系统提醒、提示词模板说明）。
    private static func isInjected(_ text: String) -> Bool {
        text.hasPrefix("<command-name>") || text.hasPrefix("<local-command")
            || text.hasPrefix("<system-reminder") || text.hasPrefix("Caveat:")
    }

    /// 维护「最后一条消息」：与 Claude 一致，取消息内最后一个工具调用或文本块。
    private func updateLastMessage(
        content: [MessageBlock],
        role: String,
        state: inout TranscriptParseState
    ) {
        for block in content.reversed() {
            switch block {
            case .toolUse(let tool):
                state.lastMessage = TranscriptParsing.truncate(
                    ClaudeTranscriptSchema.formatToolInput(
                        Self.rawInput(of: tool), toolName: tool.name))
                state.lastMessageRole = "tool"
                state.lastToolName = tool.name
                return
            case .text(let text):
                state.lastMessage = TranscriptParsing.truncate(text)
                state.lastMessageRole = role
                state.lastToolName = nil
                return
            default:
                continue
            }
        }
    }

    /// 把已经拍平成字符串的入参还原成 Claude 的工具入参形状。
    ///
    /// `ToolUseBlock.input` 是 `[String: String]`，而 Claude 的摘要函数按类型判定
    /// （`file_path` / `command` 等字符串字段），因此这里按 `Any` 传回即可。
    private static func rawInput(of tool: ToolUseBlock) -> [String: Any]? {
        tool.input.isEmpty ? nil : tool.input
    }
}
