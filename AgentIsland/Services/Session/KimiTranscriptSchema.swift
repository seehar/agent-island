//
//  KimiTranscriptSchema.swift
//  AgentIsland
//
//  Kimi Code CLI 的会话记录（`~/.kimi-code/**`，旧版在 `~/.kimi`）。记录是 JSONL，
//  且同时存在两代协议（字段来自 CodeIsland `readRecentFromKimiTranscript`）：
//
//    · 旧版外壳：`{"message":{"type":"TurnBegin"|"ContentPart"|"TurnEnd","payload":{…}}}`
//        - TurnBegin.payload.user_input 是用户输入
//        - ContentPart.payload.type == "text" 时 payload.text 是助手内容
//        - TurnEnd 收尾
//    · 新版 wire 协议（v1.4+，实测顺序：turn.prompt → 可选 context.append_message
//      → content.part 若干）：
//        - `{"type":"turn.prompt","input":[{type:"text",text}]}` 开一轮
//        - `{"type":"context.append_message","message":{"role":"user","content":[…]}}`
//        - `{"type":"context.append_loop_event","event":{"type":"content.part",
//           "part":{"type":"text","text":…}}}`
//
//  一轮对话由若干行拼成（不像 Claude 那样一行一条消息），因此这里把「正在累积的
//  一轮」放在解析状态里（`TranscriptParseState.cursor`，解析器实例是跨会话共用的，
//  不能把回合缓冲挂在实例上）：用户文本在开轮时就产出气泡，助手文本累积到轮次收尾
//  时才产出。收尾判据：旧版 `TurnEnd`、开下一轮的 `turn.prompt`、以及任何名字形如
//  `turn.<非开始>` 的行（新版协议的收尾事件名本机无法验证，这类行按收尾处理；
//  内容级事件（`content.*`）不算收尾，避免把一轮助手回复拆成多条）。
//
//  未能验证的部分：本机没有安装 kimi（`~/.kimi-code` / `~/.kimi` 都不存在），
//  因此新版协议的收尾事件名与工具调用形状无从核对——这里不解析工具调用、
//  也不产出用量（记录里没有 token 字段），只有文本对话。
//

import Foundation
import os.log

/// Kimi Code CLI 的 JSONL 记录解析。
nonisolated final class KimiTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .kimi }

    // MARK: - 记录翻译

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        var turn = OpenTurn(state.cursor)

        // 旧版外壳
        if let message = json["message"] as? [String: Any], let type = message["type"] as? String {
            let payload = message["payload"] as? [String: Any]
            switch type {
            case "TurnBegin":
                flush(turn: &turn, rawLine: rawLine, state: &state, result: &result)
                open(
                    userText: Self.textParts(payload?["user_input"]), rawLine: rawLine,
                    state: &state, result: &result, turn: &turn)
            case "ContentPart":
                if payload?["type"] as? String == "text", let text = payload?["text"] as? String {
                    turn.assistantText += text
                }
            case "TurnEnd":
                flush(turn: &turn, rawLine: rawLine, state: &state, result: &result)
            default:
                break
            }
            state.cursor = turn.encoded
            return
        }

        // 新版 wire 协议
        let type = json["type"] as? String
        switch type {
        case "turn.prompt":
            let prompt = Self.textParts(json["input"])
            if turn.openedByAppend && turn.assistantText.isEmpty {
                // 同一轮里 append_message 先到：仍以 turn.prompt 的文本为准，
                // 但不重复产出用户气泡（已经产出过），也不清空 append 的文本。
                if !prompt.isEmpty, turn.userText != prompt {
                    turn.userText = prompt
                    emitUser(
                        text: prompt, rawLine: rawLine, state: &state, result: &result,
                        replacePrevious: true)
                }
            } else {
                flush(turn: &turn, rawLine: rawLine, state: &state, result: &result)
                open(
                    userText: prompt, rawLine: rawLine, state: &state, result: &result, turn: &turn)
            }
        case "context.append_message":
            if let message = json["message"] as? [String: Any],
                message["role"] as? String == "user"
            {
                let userText = Self.textParts(message["content"])
                if !userText.isEmpty, turn.userText == nil {
                    open(
                        userText: userText, rawLine: rawLine, state: &state, result: &result,
                        turn: &turn)
                    turn.openedByAppend = true
                }
            }
        case "context.append_loop_event":
            if let event = json["event"] as? [String: Any],
                event["type"] as? String == "content.part",
                let part = event["part"] as? [String: Any],
                part["type"] as? String == "text",
                let text = part["text"] as? String
            {
                turn.assistantText += text
            }
        default:
            if Self.isTurnBoundary(type) {
                flush(turn: &turn, rawLine: rawLine, state: &state, result: &result)
            }
        }

        state.cursor = turn.encoded
    }

    // MARK: - 回合

    /// 开一轮：产出用户气泡（用户消息是一个完整单元，不必等回合结束）。
    private func open(
        userText: String,
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult,
        turn: inout OpenTurn
    ) {
        guard !userText.isEmpty else { return }
        turn.userText = userText
        turn.openedByAppend = false
        emitUser(text: userText, rawLine: rawLine, state: &state, result: &result)
    }

    /// 收尾：助手文本累积到了内容就产出一条气泡。
    private func flush(
        turn: inout OpenTurn,
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        defer {
            turn.userText = nil
            turn.assistantText = ""
            turn.openedByAppend = false
        }
        guard turn.userText != nil, !turn.assistantText.isEmpty else { return }

        let text = turn.assistantText
        let key = "\(rawLine)|\(text)"
        let message = ChatMessage(
            id: StableHash.hash(key[...]),
            role: .assistant,
            // kimi 记录里没有时间戳字段：用读取时刻（会话排序另有文件 mtime 兜底）。
            timestamp: Date(),
            content: [.text(text)]
        )
        state.messages.append(message)
        result.newMessages.append(message)
        state.lastMessage = TranscriptParsing.truncate(text)
        state.lastMessageRole = ChatRole.assistant.rawValue
        state.lastToolName = nil
    }

    private func emitUser(
        text: String,
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult,
        replacePrevious: Bool = false
    ) {
        let timestamp = Date()
        let message = ChatMessage(
            id: StableHash.hash(rawLine[rawLine.startIndex...]),
            role: .user,
            timestamp: timestamp,
            content: [.text(text)]
        )
        // `turn.prompt` 与 `context.append_message` 可能各写一遍同一段用户文本：
        // 后者先到时已经产出过气泡，前者只更新文本，不再追加第二个气泡。
        if replacePrevious, let index = state.messages.lastIndex(where: { $0.role == .user }) {
            state.messages[index] = message
        } else {
            state.messages.append(message)
            result.newMessages.append(message)
        }

        if state.firstUserMessage == nil {
            state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
        }
        state.lastUserMessageDate = timestamp
        state.lastMessage = TranscriptParsing.truncate(text)
        state.lastMessageRole = ChatRole.user.rawValue
        state.lastToolName = nil
        result.activity.append(.promptSubmitted(text: text))
    }

    /// 名字形如「回合收尾」的行：`turn.` 开头且不是开轮/开始语义。
    private static func isTurnBoundary(_ type: String?) -> Bool {
        guard let type, type.hasPrefix("turn."), type != "turn.prompt" else { return false }
        let suffix = type.dropFirst("turn.".count)
        let openingMarkers = ["begin", "start", "prompt"]
        return !openingMarkers.contains { suffix.contains($0) }
    }

    // MARK: - 字段解析

    /// 从 `user_input` / `input` / `content` 里取文本内容（`type` 为 `text` 或缺省的块）。
    private static func textParts(_ value: Any?) -> String {
        let parts: [[String: Any]]
        if let typed = value as? [[String: Any]] {
            parts = typed
        } else if let anyParts = value as? [Any] {
            parts = anyParts.compactMap { $0 as? [String: Any] }
        } else {
            return ""
        }
        return parts.compactMap { part -> String? in
            if let type = part["type"] as? String, type != "text" { return nil }
            return part["text"] as? String
        }.joined()
    }

    /// 正在累积的一轮对话。
    ///
    /// 只存在于解析状态里（`TranscriptParseState.cursor`），因为 schema 实例是跨会话
    /// 共用的——挂在实例上会让两个 kimi 会话互相覆盖彼此的未完成回合。
    /// 编码用单元分隔符（`U+001F`）拼接：三种字段都不会包含它。
    private struct OpenTurn {
        var userText: String?
        var assistantText = ""
        /// 这一轮是 `context.append_message` 开的（后续 `turn.prompt` 应替换文本而不是再开一轮）。
        var openedByAppend = false

        init(_ encoded: String?) {
            guard let encoded, !encoded.isEmpty else { return }
            let fields = encoded.components(separatedBy: "\u{1F}")
            guard fields.count == 3 else { return }
            userText = fields[0].isEmpty ? nil : fields[0]
            assistantText = fields[1]
            openedByAppend = fields[2] == "1"
        }

        var encoded: String {
            [userText ?? "", assistantText, openedByAppend ? "1" : "0"]
                .joined(separator: "\u{1F}")
        }
    }
}