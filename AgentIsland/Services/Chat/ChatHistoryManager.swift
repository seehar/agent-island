//
//  ChatHistoryManager.swift
//  AgentIsland
//

import Foundation

/// 「这个会话的记录读过没有」+ 触发读取。
///
/// 它曾经还是聊天条目的**第二份状态**（`histories` / `agentDescriptions` 两个
/// `@Published` 字典，每轮会话发布会整表重建一遍）。那份镜像没有存在的必要：
/// 条目本来就在 `SessionState.chatItems` 里，视图订阅 `sessionMonitor.$instances`
/// 就能拿到最新值，投影规则也已经在 `ChatHistoryProjection`（纯函数、有单测）。
/// 留着它只会多一条发布通道、多一处可能与真源不一致的副本。
@MainActor
final class ChatHistoryManager {
    static let shared = ChatHistoryManager()

    /// 本次运行中已经让 SessionStore 读过记录的会话。只由 `loadFromFile`
    /// 标记：实时事件只带来工具调用，没有完整的用户/助手文本对话。
    private var transcriptLoadedSessions: Set<SessionKey> = []

    private init() {}

    // MARK: - Public API

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

    /// 派生出来的子 Agent（omp 的 task 派发单元）。
    /// Claude 走 `subagentTools`（内部工具明细），omp 走这里（子 Agent 身份与状态）。
    var subagentRuns: [SubagentRun]

    /// Whether this tool is the subagent-container tool. "Task" is the
    /// legacy name; Claude Code now uses "Agent".
    var isSubagentContainer: Bool {
        Self.isSubagentContainerName(name)
    }

    /// 是否按「子 Agent 容器」呈现：只有真的收到子 Agent 内容时才折叠成容器。
    /// Claude 给的是子 Agent 内部的工具明细，omp/pi 给的是子 Agent 实例本身，
    /// 两者任一非空都按容器呈现；都没有则与普通工具行一致，结果照常可展开。
    var presentsAsSubagentContainer: Bool {
        isSubagentContainer && (!subagentTools.isEmpty || !subagentRuns.isEmpty)
    }

    /// Same check by raw tool-name string (used when we don't have a
    /// ToolCallItem — e.g. when matching against `HookEvent.tool`).
    /// 各 Agent 的派生工具名收敛在 `AgentKind.subagentToolNames`。
    static func isSubagentContainerName(_ name: String?) -> Bool {
        guard let name else { return false }
        return AgentKind.allSubagentToolNames.contains(name)
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
        lhs.subagentTools == rhs.subagentTools &&
        lhs.subagentRuns == rhs.subagentRuns
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
