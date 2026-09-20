//
//  SessionEvent.swift
//  ClaudeIsland
//
//  Unified event types for the session state machine.
//  All state changes flow through SessionStore.process(event).
//

import Foundation

/// All events that can affect session state
/// This is the single entry point for state mutations
enum SessionEvent: Sendable {
    // MARK: - Hook Events (from HookSocketServer)

    /// A hook event was received from Claude Code
    case hookReceived(HookEvent)

    // MARK: - Permission Events (user actions)

    /// User approved a permission request
    case permissionApproved(key: SessionKey, toolUseId: String)

    /// User denied a permission request
    case permissionDenied(key: SessionKey, toolUseId: String, reason: String?)

    /// Permission socket failed (connection died before response)
    case permissionSocketFailed(key: SessionKey, toolUseId: String)

    // MARK: - File Events (from ConversationParser)

    /// JSONL file was updated with new content
    case fileUpdated(FileUpdatePayload)

    // MARK: - Tool Completion Events (from JSONL parsing)

    /// A tool was detected as completed via JSONL result
    /// This is the authoritative signal that a tool has finished
    case toolCompleted(key: SessionKey, toolUseId: String, result: ToolCompletionResult)

    // MARK: - Interrupt Events (from JSONLInterruptWatcher)

    /// User interrupted Claude (detected via JSONL)
    case interruptDetected(key: SessionKey)

    // MARK: - Subagent Events (Task tool tracking)

    /// A Task (subagent) tool has started
    case subagentStarted(key: SessionKey, taskToolId: String)

    /// A tool was executed within an active subagent
    case subagentToolExecuted(key: SessionKey, tool: SubagentToolCall)

    /// A subagent tool completed (status update)
    case subagentToolCompleted(key: SessionKey, toolId: String, status: ToolStatus)

    /// A Task (subagent) tool has stopped
    case subagentStopped(key: SessionKey, taskToolId: String)

    /// Agent file was updated with new subagent tools (from AgentFileWatcher)
    case agentFileUpdated(key: SessionKey, taskToolId: String, tools: [SubagentToolInfo])

    // MARK: - Clear Events (from JSONL detection)

    /// User issued /clear command - reset UI state while keeping session alive
    case clearDetected(key: SessionKey)

    // MARK: - Session Lifecycle

    /// Session has ended
    case sessionEnded(key: SessionKey)

    /// Request to load initial history from file
    /// 加载会话历史（agent 用于定位该 Agent 的记录）
    case loadHistory(key: SessionKey, cwd: String)

    /// History load completed
    case historyLoaded(
        key: SessionKey, messages: [ChatMessage], completedTools: Set<String>,
        toolResults: [String: ToolResultPayload], structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo)
}

/// Payload for file update events
nonisolated struct FileUpdatePayload: Sendable {
    /// 会话键（Agent + 会话 id）。
    let key: SessionKey
    let cwd: String
    /// Messages to process - either only new messages (if isIncremental) or all messages
    let messages: [ChatMessage]
    /// When true, messages contains only NEW messages since last update
    /// When false, messages contains ALL messages (used for initial load or after /clear)
    let isIncremental: Bool
    let completedToolIds: Set<String>
    let toolResults: [String: ToolResultPayload]
    let structuredResults: [String: ToolResultData]
}

/// Result of a tool completion detected from JSONL
nonisolated struct ToolCompletionResult: Sendable {
    let status: ToolStatus
    let result: String?
    let structuredResult: ToolResultData?

    nonisolated static func from(
        parserResult: ToolResultPayload?, structuredResult: ToolResultData?
    ) -> ToolCompletionResult {
        let status: ToolStatus
        if parserResult?.isInterrupted == true {
            status = .interrupted
        } else if parserResult?.isError == true {
            status = .error
        } else {
            status = .success
        }

        var resultText: String? = nil
        if let r = parserResult {
            if !r.isInterrupted {
                if let stdout = r.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = r.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = r.content, !content.isEmpty {
                    resultText = content
                }
            }
        }

        return ToolCompletionResult(
            status: status, result: resultText, structuredResult: structuredResult)
    }
}

// MARK: - Hook Event Extensions

extension HookEvent {
    /// Determine the target session phase based on this hook event
    nonisolated func determinePhase() -> SessionPhase {
        // PreCompact takes priority
        if event == "PreCompact" {
            return .compacting
        }

        // Permission request creates waitingForApproval state
        if expectsResponse, let tool = tool {
            return .waitingForApproval(
                PermissionContext(
                    toolUseId: toolUseId ?? "",
                    toolName: tool,
                    toolInput: toolInput,
                    receivedAt: Date()
                ))
        }

        // 无法从 notch 答复的审批（pi/omp/opencode）：只展示「等待确认」状态
        if event == "ToolApproval" {
            return .waitingForApproval(
                PermissionContext(
                    toolUseId: toolUseId ?? "",
                    toolName: tool ?? "Tool",
                    toolInput: toolInput,
                    receivedAt: Date()
                ))
        }

        if event == "Notification" && notificationType == "idle_prompt" {
            return .idle
        }

        switch status {
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        default:
            return .idle
        }
    }

    /// Whether this is a tool-related event
    nonisolated var isToolEvent: Bool {
        event == "PreToolUse" || event == "PostToolUse" || event == "PermissionRequest" || event == "ToolApproval"
    }

    /// Whether this event should trigger a file sync
    nonisolated var shouldSyncFile: Bool {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "ToolApproval", "Stop":
            return true
        default:
            return false
        }
    }
}

// MARK: - Debug Description

extension SessionEvent: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .hookReceived(let event):
            return "hookReceived(\(event.event), session: \(event.sessionId.prefix(8)))"
        case .permissionApproved(let key, let toolUseId):
            return
                "permissionApproved(session: \(key.sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionDenied(let key, let toolUseId, _):
            return
                "permissionDenied(session: \(key.sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionSocketFailed(let key, let toolUseId):
            return
                "permissionSocketFailed(session: \(key.sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .fileUpdated(let payload):
            return
                "fileUpdated(\(payload.key.rawValue), messages: \(payload.messages.count))"
        case .interruptDetected(let key):
            return "interruptDetected(\(key.rawValue))"
        case .clearDetected(let key):
            return "clearDetected(\(key.rawValue))"
        case .sessionEnded(let key):
            return "sessionEnded(\(key.rawValue))"
        case .loadHistory(let key, _):
            return "loadHistory(\(key.rawValue))"
        case .historyLoaded(let key, let messages, _, _, _, _):
            return "historyLoaded(\(key.rawValue), messages: \(messages.count))"
        case .toolCompleted(let key, let toolUseId, let result):
            return
                "toolCompleted(session: \(key.sessionId.prefix(8)), tool: \(toolUseId.prefix(12)), status: \(result.status))"
        case .subagentStarted(let key, let taskToolId):
            return
                "subagentStarted(session: \(key.sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .subagentToolExecuted(let key, let tool):
            return "subagentToolExecuted(session: \(key.sessionId.prefix(8)), tool: \(tool.name))"
        case .subagentToolCompleted(let key, let toolId, let status):
            return
                "subagentToolCompleted(session: \(key.sessionId.prefix(8)), tool: \(toolId.prefix(12)), status: \(status))"
        case .subagentStopped(let key, let taskToolId):
            return
                "subagentStopped(session: \(key.sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .agentFileUpdated(let key, let taskToolId, let tools):
            return
                "agentFileUpdated(session: \(key.sessionId.prefix(8)), task: \(taskToolId.prefix(12)), tools: \(tools.count))"
        }
    }
}
