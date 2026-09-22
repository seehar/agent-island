//
//  ClineTranscriptSchema.swift
//  AgentIsland
//
//  Cline 是 VSCode 扩展（没有 CLI 进程），历史落在扩展的 globalStorage 里：
//    <Application Support>/Code/User/globalStorage/saoudrizwan.claude-dev/
//      state/taskHistory.json                 任务清单（id / ts / modelId / cwd…）
//      tasks/<任务 id>/api_conversation_history.json   该任务的对话（角色 + 内容）
//  （路径与字段来自 CodeIsland `clineStorageRoot` 与 `readRecentFromClineHistory`，
//  本机没有安装 Cline 扩展，无法用真实记录核对。）
//
//  这是**整文档 JSON**（不是追加式 JSONL），因此不能像 JSONL 那样按字节续读：
//  这里整读一次，用「文件字节数（`offset`）+ 已消费条数（`cursor`）」做增量——
//  条数增加即追加的内容，条数减少或文件变小即被重写，此时重置解析状态并重放。
//
//  用量统计：`api_conversation_history.json` 里没有 token 字段（CodeIsland 也不读），
//  而且用量扫描器只按 JSONL 做字节增量，所以这里与扫描器都不产出 Cline 的用量。
//

import Foundation
import os.log

/// Cline 的对话记录解析（整文档 JSON，按条数增量）。
nonisolated class ClineTranscriptSchema: AgentTranscriptSchema {
    var agent: AgentKind { .cline }

    /// 对话文件由 Provider 解析（任务 id → `tasks/<任务 id>/api_conversation_history.json`）。
    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        AgentRegistry.provider(for: .cline).transcriptFile(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - 读取

    func read(sessionId: String, cwd: String, state: inout TranscriptParseState)
        -> TranscriptReadResult
    {
        var result = TranscriptReadResult()
        guard let url = transcriptFile(sessionId: sessionId, cwd: cwd),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return result
        }

        let consumed = Int(state.cursor ?? "") ?? 0
        let size = UInt64(data.count)

        // 文件变小、或条数比已消费的还少：说明记录被重写（不是追加），重置后重放。
        if (state.offset > 0 && size < state.offset) || entries.count < consumed {
            state.resetConversation()
            result.resetDetected = true
            result.activity.append(.sessionReset)
        }

        let start = result.resetDetected ? 0 : min(consumed, entries.count)
        state.offset = size
        state.cursor = String(entries.count)
        guard start < entries.count else { return result }

        result.isNewContent = true
        for index in start..<entries.count {
            consume(entries[index], index: index, state: &state, result: &result)
        }
        return result
    }

    // MARK: - 条目翻译

    /// 一条对话条目：`{"role":"user"|"assistant","content":…}`。
    private func consume(
        _ entry: [String: Any],
        index: Int,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let role = entry["role"] as? String, role == "user" || role == "assistant" else {
            return
        }

        var content: [MessageBlock] = []
        var toolCalls: [(id: String, name: String, input: [String: String])] = []
        var toolOutputs: [(id: String, isError: Bool)] = []

        if let text = entry["content"] as? String {
            if !text.isEmpty { content.append(.text(text)) }
        } else {
            // 内容块的具体类型无法用真实记录核对（本机没有 Cline）；按 Anthropic
            // 工具协议容忍解析，形状不符时自然产出为空。
            for block in entry["content"] as? [[String: Any]] ?? [] {
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
                        content: block["content"] as? String, stdout: nil, stderr: nil,
                        isError: isError)
                    state.completedToolIds.insert(id)
                    toolOutputs.append((id: id, isError: isError))
                default:
                    continue
                }
            }
        }

        guard !content.isEmpty || !toolOutputs.isEmpty else { return }

        let timestamp = Self.timestamp(of: entry)
        let text = TranscriptParsing.firstText(in: content)
        if !content.isEmpty {
            let chatMessage = ChatMessage(
                id: StableHash.hash(Self.messageKey(index: index, role: role, text: text)),
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
            if let text {
                state.lastMessage = TranscriptParsing.truncate(text)
                state.lastMessageRole = role
                state.lastToolName = nil
            }
        }

        for call in toolCalls where !state.seenToolIds.contains(call.id) {
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

    /// 条目 id：带序号、角色与正文哈希。
    ///
    /// 序号保证同一次读取里互不重复，正文哈希让记录被重写后的新条目与旧条目区分开
    /// （重写时会先重置解析状态并上报 `clearDetected`，界面据此做一次清理）。
    private static func messageKey(index: Int, role: String, text: String?) -> Substring {
        let key = "cline|\(index)|\(role)|\(text ?? "")"
        return key[...]
    }

    /// 条目时间戳：`ts` 是毫秒 epoch（taskHistory 里就是这个口径），也接受 ISO8601 字符串。
    private static func timestamp(of entry: [String: Any]) -> Date {
        if let milliseconds = entry["ts"] as? NSNumber, !(milliseconds is Bool) {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        if let milliseconds = entry["timestamp"] as? NSNumber, !(milliseconds is Bool) {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        if let iso = entry["timestamp"] as? String,
            let date = TranscriptParsing.isoFormatter.date(from: iso)
        {
            return date
        }
        return Date()
    }
}