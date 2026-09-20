//
//  ToolResultData.swift
//  AgentIsland
//
//  Structured models for all Claude Code tool results
//

import Foundation

// MARK: - Tool Result Wrapper

/// Structured tool result data - parsed from JSONL tool_result blocks
nonisolated enum ToolResultData: Equatable, Sendable {
    case read(ReadResult)
    case edit(EditResult)
    case write(WriteResult)
    case bash(BashResult)
    case grep(GrepResult)
    case glob(GlobResult)
    case todoWrite(TodoWriteResult)
    case task(TaskResult)
    case webFetch(WebFetchResult)
    case webSearch(WebSearchResult)
    case askUserQuestion(AskUserQuestionResult)
    case bashOutput(BashOutputResult)
    case killShell(KillShellResult)
    case exitPlanMode(ExitPlanModeResult)
    case mcp(MCPResult)
    case generic(GenericResult)
}

// MARK: - Read Tool Result

nonisolated struct ReadResult: Equatable, Sendable {
    let filePath: String
    let content: String
    let numLines: Int
    let startLine: Int
    let totalLines: Int

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - Edit Tool Result

nonisolated struct EditResult: Equatable, Sendable {
    let filePath: String
    let oldString: String
    let newString: String
    let replaceAll: Bool
    let userModified: Bool
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

nonisolated struct PatchHunk: Equatable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

// MARK: - Write Tool Result

nonisolated struct WriteResult: Equatable, Sendable {
    enum WriteType: String, Equatable, Sendable {
        case create
        case overwrite
    }

    let type: WriteType
    let filePath: String
    let content: String
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - Bash Tool Result

nonisolated struct BashResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let interrupted: Bool
    let isImage: Bool
    let returnCodeInterpretation: String?
    let backgroundTaskId: String?

    var hasOutput: Bool {
        !stdout.isEmpty || !stderr.isEmpty
    }

    var displayOutput: String {
        if !stdout.isEmpty {
            return stdout
        }
        if !stderr.isEmpty {
            return stderr
        }
        return LocalizationManager.t("(No content)")
    }
}

// MARK: - Grep Tool Result

nonisolated struct GrepResult: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case filesWithMatches = "files_with_matches"
        case content
        case count
    }

    let mode: Mode
    let filenames: [String]
    let numFiles: Int
    let content: String?
    let numLines: Int?
    let appliedLimit: Int?
}

// MARK: - Glob Tool Result

nonisolated struct GlobResult: Equatable, Sendable {
    let filenames: [String]
    let durationMs: Int
    let numFiles: Int
    let truncated: Bool
}

// MARK: - TodoWrite Tool Result

nonisolated struct TodoWriteResult: Equatable, Sendable {
    let oldTodos: [TodoItem]
    let newTodos: [TodoItem]
}

nonisolated struct TodoItem: Equatable, Sendable {
    let content: String
    let status: String // "pending", "in_progress", "completed"
    let activeForm: String?
}

// MARK: - Task (Agent) Tool Result

nonisolated struct TaskResult: Equatable, Sendable {
    let agentId: String
    let status: String
    let content: String
    let prompt: String?
    let totalDurationMs: Int?
    let totalTokens: Int?
    let totalToolUseCount: Int?
}

// MARK: - WebFetch Tool Result

nonisolated struct WebFetchResult: Equatable, Sendable {
    let url: String
    let code: Int
    let codeText: String
    let bytes: Int
    let durationMs: Int
    let result: String
}

// MARK: - WebSearch Tool Result

nonisolated struct WebSearchResult: Equatable, Sendable {
    let query: String
    let durationSeconds: Double
    let results: [SearchResultItem]
}

nonisolated struct SearchResultItem: Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

// MARK: - AskUserQuestion Tool Result

nonisolated struct AskUserQuestionResult: Equatable, Sendable {
    let questions: [QuestionItem]
    let answers: [String: String]
}

nonisolated struct QuestionItem: Equatable, Sendable {
    let question: String
    let header: String?
    let options: [QuestionOption]
}

nonisolated struct QuestionOption: Equatable, Sendable {
    let label: String
    let description: String?
}

// MARK: - BashOutput Tool Result

nonisolated struct BashOutputResult: Equatable, Sendable {
    let shellId: String
    let status: String
    let stdout: String
    let stderr: String
    let stdoutLines: Int
    let stderrLines: Int
    let exitCode: Int?
    let command: String?
    let timestamp: String?
}

// MARK: - KillShell Tool Result

nonisolated struct KillShellResult: Equatable, Sendable {
    let shellId: String
    let message: String
}

// MARK: - ExitPlanMode Tool Result

nonisolated struct ExitPlanModeResult: Equatable, Sendable {
    let filePath: String?
    let plan: String?
    let isAgent: Bool
}

// MARK: - MCP Tool Result (Generic)

nonisolated struct MCPResult: Equatable, @unchecked Sendable {
    let serverName: String
    let toolName: String
    let rawResult: [String: Any]

    static func == (lhs: MCPResult, rhs: MCPResult) -> Bool {
        lhs.serverName == rhs.serverName &&
        lhs.toolName == rhs.toolName &&
        NSDictionary(dictionary: lhs.rawResult).isEqual(to: rhs.rawResult)
    }
}

// MARK: - Generic Tool Result (Fallback)

nonisolated struct GenericResult: Equatable, @unchecked Sendable {
    let rawContent: String?
    let rawData: [String: Any]?

    static func == (lhs: GenericResult, rhs: GenericResult) -> Bool {
        guard lhs.rawContent == rhs.rawContent else { return false }
        // Compare rawData dictionaries if both present
        if let lhsData = lhs.rawData, let rhsData = rhs.rawData {
            return NSDictionary(dictionary: lhsData).isEqual(to: rhsData)
        }
        return lhs.rawData == nil && rhs.rawData == nil
    }
}

// MARK: - Tool Status Display

nonisolated struct ToolStatusDisplay {
    let text: String
    let isRunning: Bool

    /// Get running status text for a tool
    static func running(for toolName: String, input: [String: String]) -> ToolStatusDisplay {
        switch toolName {
        case "Read":
            return ToolStatusDisplay(text: LocalizationManager.t("Reading..."), isRunning: true)
        case "Edit":
            return ToolStatusDisplay(text: LocalizationManager.t("Editing..."), isRunning: true)
        case "Write":
            return ToolStatusDisplay(text: LocalizationManager.t("Writing..."), isRunning: true)
        case "Bash":
            if let desc = input["description"], !desc.isEmpty {
                return ToolStatusDisplay(text: desc, isRunning: true)
            }
            return ToolStatusDisplay(text: LocalizationManager.t("Running..."), isRunning: true)
        case "Grep", "Glob":
            if let pattern = input["pattern"] {
                return ToolStatusDisplay(text: LocalizationManager.t("Searching: %@", pattern), isRunning: true)
            }
            return ToolStatusDisplay(text: LocalizationManager.t("Searching..."), isRunning: true)
        case "WebSearch":
            if let query = input["query"] {
                return ToolStatusDisplay(text: LocalizationManager.t("Searching: %@", query), isRunning: true)
            }
            return ToolStatusDisplay(text: LocalizationManager.t("Searching..."), isRunning: true)
        case "WebFetch":
            return ToolStatusDisplay(text: LocalizationManager.t("Fetching..."), isRunning: true)
        case "Task", "Agent":
            if let desc = input["description"], !desc.isEmpty {
                return ToolStatusDisplay(text: desc, isRunning: true)
            }
            return ToolStatusDisplay(text: LocalizationManager.t("Running agent..."), isRunning: true)
        case "TodoWrite":
            return ToolStatusDisplay(text: LocalizationManager.t("Updating todos..."), isRunning: true)
        case "EnterPlanMode":
            return ToolStatusDisplay(text: LocalizationManager.t("Entering plan mode..."), isRunning: true)
        case "ExitPlanMode":
            return ToolStatusDisplay(text: LocalizationManager.t("Exiting plan mode..."), isRunning: true)
        default:
            return ToolStatusDisplay(text: LocalizationManager.t("Running..."), isRunning: true)
        }
    }

    /// Get completed status text for a tool result
    static func completed(for toolName: String, result: ToolResultData?) -> ToolStatusDisplay {
        guard let result = result else {
            return ToolStatusDisplay(text: LocalizationManager.t("Completed"), isRunning: false)
        }

        switch result {
        case .read(let r):
            let lineText = r.totalLines > r.numLines
                ? LocalizationManager.t("%lld+ lines", r.numLines)
                : LocalizationManager.t("%lld lines", r.numLines)
            return ToolStatusDisplay(text: LocalizationManager.t("Read %@ (%@)", r.filename, lineText), isRunning: false)

        case .edit(let r):
            return ToolStatusDisplay(text: LocalizationManager.t("Edited %@", r.filename), isRunning: false)

        case .write(let r):
            let action = r.type == .create ? LocalizationManager.t("Created %@", r.filename) : LocalizationManager.t("Wrote %@", r.filename)
            return ToolStatusDisplay(text: action, isRunning: false)

        case .bash(let r):
            if let bgId = r.backgroundTaskId {
                return ToolStatusDisplay(text: LocalizationManager.t("Running in background (%@)", bgId), isRunning: false)
            }
            if let interpretation = r.returnCodeInterpretation {
                return ToolStatusDisplay(text: interpretation, isRunning: false)
            }
            return ToolStatusDisplay(text: LocalizationManager.t("Completed"), isRunning: false)

        case .grep(let r):
            return ToolStatusDisplay(
                text: LocalizationManager.t("Found %lld files", r.numFiles), isRunning: false)

        case .glob(let r):
            if r.numFiles == 0 {
                return ToolStatusDisplay(text: LocalizationManager.t("No files found"), isRunning: false)
            }
            return ToolStatusDisplay(
                text: LocalizationManager.t("Found %lld files", r.numFiles), isRunning: false)

        case .todoWrite:
            return ToolStatusDisplay(text: LocalizationManager.t("Updated todos"), isRunning: false)

        case .task(let r):
            return ToolStatusDisplay(text: r.status.capitalized, isRunning: false)

        case .webFetch(let r):
            return ToolStatusDisplay(text: "\(r.code) \(r.codeText)", isRunning: false)

        case .webSearch(let r):
            let time = r.durationSeconds >= 1 ?
                LocalizationManager.t("%llds", Int(r.durationSeconds)) :
                LocalizationManager.t("%lldms", Int(r.durationSeconds * 1000))
            // 一次 WebSearch 调用；`results` 是命中条数，不是搜索次数
            return ToolStatusDisplay(text: LocalizationManager.t("Did 1 search in %@", time), isRunning: false)

        case .askUserQuestion:
            return ToolStatusDisplay(text: LocalizationManager.t("Answered"), isRunning: false)

        case .bashOutput(let r):
            return ToolStatusDisplay(text: LocalizationManager.t("Status: %@", r.status), isRunning: false)

        case .killShell:
            return ToolStatusDisplay(text: LocalizationManager.t("Terminated"), isRunning: false)

        case .exitPlanMode:
            return ToolStatusDisplay(text: LocalizationManager.t("Plan ready"), isRunning: false)

        case .mcp:
            return ToolStatusDisplay(text: LocalizationManager.t("Completed"), isRunning: false)

        case .generic:
            return ToolStatusDisplay(text: LocalizationManager.t("Completed"), isRunning: false)
        }
    }
}
