//
//  ClaudeTranscriptSchema.swift
//  AgentIsland
//
//  Claude Code 的 JSONL 记录格式：`~/.claude/projects/<编码cwd>/<session>.jsonl`。
//  旧实现散落在 `ConversationParser` 里，这里集中成一份 schema，使其它 Agent
//  能以同样方式接入。
//

import Foundation
import os.log

/// Claude Code 记录解析。
nonisolated final class ClaudeTranscriptSchema: JSONLTranscriptSchema {
    override var agent: AgentKind { .claudeCode }

    // MARK: - 记录解析

    /// 把一条 Claude 记录翻译成统一的对话模型。
    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        // `/clear`：清空会话内容但保留会话本身
        if rawLine.contains("<command-name>/clear</command-name>") {
            result.resetDetected = true
            result.activity.append(.sessionReset)
            return
        }

        // 摘要记录（旧版 Claude Code 会追加 summary 行）
        if json["type"] as? String == "summary", let summary = json["summary"] as? String, !summary.isEmpty {
            state.summary = summary
        }

        // 工具结果行
        if rawLine.contains("\"tool_result\"") {
            consumeToolResults(json, state: &state, result: &result)
            return
        }

        guard let type = json["type"] as? String, type == "user" || type == "assistant" else { return }
        guard json["isMeta"] as? Bool != true else { return }

        updateConversationInfo(json: json, state: &state, result: &result)

        guard let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) else { return }
        state.messages.append(message)
        result.newMessages.append(message)

        // 新出现的工具调用上报为「工具开始」
        for block in message.content {
            if case .toolUse(let tool) = block {
                result.activity.append(.toolStarted(id: tool.id, name: tool.name, input: tool.input))
            }
        }
    }

    // MARK: - 工具结果

    /// 解析一条含 `tool_result` 的记录：登记完成状态、结果内容与结构化结果。
    private func consumeToolResults(
        _ json: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let messageDict = json["message"] as? [String: Any],
              let contentArray = messageDict["content"] as? [[String: Any]] else {
            return
        }

        let toolUseResult = json["toolUseResult"] as? [String: Any]
        let topLevelToolName = json["toolName"] as? String
        let stdout = toolUseResult?["stdout"] as? String
        let stderr = toolUseResult?["stderr"] as? String

        for block in contentArray {
            guard block["type"] as? String == "tool_result",
                  let toolUseId = block["tool_use_id"] as? String else { continue }

            state.completedToolIds.insert(toolUseId)
            let content = block["content"] as? String
            let isError = block["is_error"] as? Bool ?? false
            state.toolResults[toolUseId] = ToolResultPayload(
                content: content,
                stdout: stdout,
                stderr: stderr,
                isError: isError
            )

            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]
            if let toolUseResult, let name = toolName {
                state.structuredResults[toolUseId] = ClaudeToolResults.parseStructuredResult(
                    toolName: name,
                    toolUseResult: toolUseResult,
                    isError: isError
                )
            }

            result.activity.append(.toolFinished(id: toolUseId, name: toolName, isError: isError))
        }
    }

    // MARK: - 会话元信息

    /// 维护 `lastMessage`/`firstUserMessage`/用量等元信息，语义与原
    /// `ConversationParser.parseContent` 保持一致。
    private func updateConversationInfo(
        json: [String: Any],
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        guard let type = json["type"] as? String,
              let messageDict = json["message"] as? [String: Any] else { return }

        let timestamp = (json["timestamp"] as? String).flatMap { TranscriptParsing.isoFormatter.date(from: $0) } ?? Date()

        if type == "assistant", let usage = messageDict["usage"] as? [String: Any] {
            state.usage.inputTokens += usage["input_tokens"] as? Int ?? 0
            state.usage.outputTokens += usage["output_tokens"] as? Int ?? 0
            state.usage.cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
            state.usage.cacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
        }

        if let rawContent = messageDict["content"] as? String {
            guard !Self.isInjected(rawContent) else { return }
            if type == "user" {
                if state.firstUserMessage == nil {
                    state.firstUserMessage = TranscriptParsing.truncate(rawContent, maxLength: 50)
                }
                // 与旧实现一致：只有字符串形态的 content 才更新时间戳
                state.lastUserMessageDate = timestamp
                result.activity.append(.promptSubmitted(text: rawContent))
            }
            if !rawContent.hasPrefix("[Request interrupted by user") {
                state.lastMessage = TranscriptParsing.truncate(rawContent, maxLength: 80)
                state.lastMessageRole = type
                state.lastToolName = nil
            }
            return
        }

        guard let contentArray = messageDict["content"] as? [[String: Any]] else { return }

        if type == "user",
           let first = contentArray.first(where: { $0["type"] as? String == "text" }),
           let text = first["text"] as? String,
           !Self.isInjected(text) {
            if state.firstUserMessage == nil {
                state.firstUserMessage = TranscriptParsing.truncate(text, maxLength: 50)
            }
            result.activity.append(.promptSubmitted(text: text))
        }

        // 最后一条消息取消息内最后一个 tool_use / text 块（与原实现相同）
        for block in contentArray.reversed() {
            let blockType = block["type"] as? String
            if blockType == "tool_use" {
                let toolName = block["name"] as? String ?? "Tool"
                state.lastMessage = TranscriptParsing.truncate(
                    Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName),
                    maxLength: 80
                )
                state.lastMessageRole = "tool"
                state.lastToolName = toolName
                break
            } else if blockType == "text", let text = block["text"] as? String {
                if !text.hasPrefix("[Request interrupted by user") {
                    state.lastMessage = TranscriptParsing.truncate(text, maxLength: 80)
                    state.lastMessageRole = type
                    state.lastToolName = nil
                }
                break
            }
        }
    }

    /// Claude Code 注入的伪用户消息（斜杠命令、系统提示）不应参与标题与摘要。
    private static func isInjected(_ text: String) -> Bool {
        text.hasPrefix("<command-name>") || text.hasPrefix("<local-command") || text.hasPrefix("Caveat:")
    }

    // MARK: - 消息与工具


    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            timestamp = TranscriptParsing.isoFormatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    case "image":
                        // Claude Code stores inline images as base64 with media_type.
                        if let source = block["source"] as? [String: Any],
                           let mediaType = source["media_type"] as? String,
                           let data = source["data"] as? String {
                            blocks.append(.image(ImageBlock(mediaType: mediaType, base64Data: data)))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task", "Agent":
            // "Task" is the legacy name; Claude Code now uses "Agent"
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    // MARK: - 子 Agent 记录

    nonisolated static func subagentFilePath(sessionId: String, agentId: String, projectDir: String) -> String {
        let base = ClaudePaths.projectsDir.path + "/" + projectDir
        let nested = base + "/" + sessionId + "/subagents/agent-" + agentId + ".jsonl"
        let flat = base + "/agent-" + agentId + ".jsonl"

        let fm = FileManager.default
        if fm.fileExists(atPath: nested) { return nested }
        if fm.fileExists(atPath: flat) { return flat }
        return nested
    }

    func subagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = Self.subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

// MARK: - 工具结果结构化解析

/// Claude Code 各内置工具的结果解析（字段来自记录里的 `toolUseResult`）。
nonisolated enum ClaudeToolResults {
    /// Parse tool result JSON into structured ToolResultData
    static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = String(toolName.dropFirst(5)).components(separatedBy: "__")
            let serverName = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let mcpToolName = parts.dropFirst().joined(separator: "__")
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName.isEmpty ? toolName : mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task", "Agent":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }
}
