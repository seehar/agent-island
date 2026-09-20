//
//  ChatHistoryManager.swift
//  ClaudeIsland
//

import Combine
import Foundation

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()

    @Published private(set) var histories: [SessionKey: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [SessionKey: [String: String]] = [:]

    /// 本次运行中已经让 SessionStore 读过记录的会话。只由 `loadFromFile`
    /// 标记：实时事件只带来工具调用，没有完整的用户/助手文本对话。
    private var transcriptLoadedSessions: Set<SessionKey> = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func history(for key: SessionKey) -> [ChatHistoryItem] {
        histories[key] ?? []
    }

    /// 本次运行中是否已经读过该会话的记录。实时事件不会把它标记为已加载，
    /// 只有显式调用 `loadFromFile` 才会。
    func isLoaded(key: SessionKey) -> Bool {
        transcriptLoadedSessions.contains(key)
    }

    func loadFromFile(key: SessionKey, cwd: String) async {
        guard !transcriptLoadedSessions.contains(key) else { return }
        transcriptLoadedSessions.insert(key)
        await SessionStore.shared.process(.loadHistory(key: key, cwd: cwd))
    }

    func syncFromFile(key: SessionKey, cwd: String) async {
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: key.sessionId,
            agent: key.agent,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(sessionId: key.sessionId, agent: key.agent)
        let toolResults = await ConversationParser.shared.toolResults(sessionId: key.sessionId, agent: key.agent)
        let structuredResults = await ConversationParser.shared.structuredResults(sessionId: key.sessionId, agent: key.agent)

        let payload = FileUpdatePayload(
            key: key,
            cwd: cwd,
            messages: messages,
            isIncremental: false,  // 全量同步
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    func clearHistory(for key: SessionKey) {
        transcriptLoadedSessions.remove(key)
        histories.removeValue(forKey: key)
        Task {
            await SessionStore.shared.process(.sessionEnded(key: key))
        }
    }

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        var newHistories: [SessionKey: [ChatHistoryItem]] = [:]
        var newAgentDescriptions: [SessionKey: [String: String]] = [:]
        for session in sessions {
            let filteredItems = filterOutSubagentTools(session.chatItems)
            newHistories[session.sessionKey] = filteredItems
            newAgentDescriptions[session.sessionKey] = session.subagentState.agentDescriptions
        }
        histories = newHistories
        agentDescriptions = newAgentDescriptions
    }

    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIds = Set<String>()
        for item in items {
            if case .toolCall(let tool) = item.type, tool.isSubagentContainer {
                for subagentTool in tool.subagentTools {
                    subagentToolIds.insert(subagentTool.id)
                }
            }
        }

        return items.filter { !subagentToolIds.contains($0.id) }
    }
}

// MARK: - Models

nonisolated struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

nonisolated enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case image(ImageBlock)
    case interrupted
}

nonisolated struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Whether this tool is the subagent-container tool. "Task" is the
    /// legacy name; Claude Code now uses "Agent".
    var isSubagentContainer: Bool {
        Self.isSubagentContainerName(name)
    }

    /// Same check by raw tool-name string (used when we don't have a
    /// ToolCallItem — e.g. when matching against `HookEvent.tool`).
    static func isSubagentContainerName(_ name: String?) -> Bool {
        name == "Task" || name == "Agent"
    }

    /// 面向用户的文案统一走本地化入口；这里用非隔离的静态入口，
    /// 因为本结构体是 `nonisolated`（会在解析 actor 与后台扫描里被读取）。

    /// Preview text for the tool (input-based)
    var inputPreview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(60))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        if let query = input["query"] {
            return query
        }
        if let url = input["url"] {
            return url
        }
        if let agentId = input["agentId"] {
            let blocking = input["block"] == "true"
            return blocking
                ? LocalizationManager.t("Waiting...")
                : LocalizationManager.t("Checking %@...", String(agentId.prefix(8)))
        }
        return input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if status == .running {
            return ToolStatusDisplay.running(for: name, input: input)
        }
        if status == .waitingForApproval {
            return ToolStatusDisplay(
                text: LocalizationManager.t("Waiting for approval..."), isRunning: true)
        }
        if status == .interrupted {
            return ToolStatusDisplay(text: LocalizationManager.t("Interrupted"), isRunning: false)
        }
        return ToolStatusDisplay.completed(for: name, result: structuredResult)
    }

    // Custom Equatable implementation to handle structuredResult
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.input == rhs.input &&
        lhs.status == rhs.status &&
        lhs.result == rhs.result &&
        lhs.structuredResult == rhs.structuredResult &&
        lhs.subagentTools == rhs.subagentTools
    }
}

nonisolated enum ToolStatus: Sendable, Hashable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    nonisolated var description: String {
        switch self {
        case .running: return "running"
        case .waitingForApproval: return "waitingForApproval"
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }
}

// Explicit nonisolated Equatable conformance to avoid actor isolation issues
nonisolated extension ToolStatus: Equatable {
    nonisolated static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running): return true
        case (.waitingForApproval, .waitingForApproval): return true
        case (.success, .success): return true
        case (.error, .error): return true
        case (.interrupted, .interrupted): return true
        default: return false
        }
    }
}

// MARK: - Subagent Tool Call

/// Represents a tool call made by a subagent (Task tool)
nonisolated struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// 面向用户的文案统一走本地化入口；这里用非隔离的静态入口，
    /// 因为本结构体是 `nonisolated`（会在解析 actor 与后台扫描里被读取）。

    /// Short description for display
    var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return LocalizationManager.t("Reading...")
        case "Grep":
            if let pattern = input["pattern"] {
                return LocalizationManager.t("grep: %@", pattern)
            }
            return LocalizationManager.t("Searching...")
        case "Glob":
            if let pattern = input["pattern"] {
                return LocalizationManager.t("glob: %@", pattern)
            }
            return LocalizationManager.t("Finding files...")
        case "Bash":
            if let desc = input["description"] {
                return desc
            }
            if let cmd = input["command"] {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return String(firstLine.prefix(40))
            }
            return LocalizationManager.t("Running command...")
        case "Edit":
            if let path = input["file_path"] {
                return LocalizationManager.t(
                    "Edit: %@", URL(fileURLWithPath: path).lastPathComponent)
            }
            return LocalizationManager.t("Editing...")
        case "Write":
            if let path = input["file_path"] {
                return LocalizationManager.t(
                    "Write: %@", URL(fileURLWithPath: path).lastPathComponent)
            }
            return LocalizationManager.t("Writing...")
        case "WebFetch":
            if let url = input["url"] {
                return LocalizationManager.t("Fetching: %@...", String(url.prefix(30)))
            }
            return LocalizationManager.t("Fetching...")
        case "WebSearch":
            if let query = input["query"] {
                return LocalizationManager.t("Search: %@", String(query.prefix(30)))
            }
            return LocalizationManager.t("Searching web...")
        default:
            return name
        }
    }
}
