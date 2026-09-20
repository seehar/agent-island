//
//  MCPToolFormatter.swift
//  ClaudeIsland
//
//  Utility for formatting MCP tool names and arguments
//

import Foundation

struct MCPToolFormatter {

    private static let l10n = LocalizationManager.shared

    /// 更友好的展示名。按工具 ID 分支而不是查表，避免每次渲染都构造字典。
    private static func toolAlias(for toolId: String) -> String? {
        switch toolId {
        case "AgentOutputTool": return l10n.t("Await Agent")
        case "AskUserQuestion": return l10n.t("Question")
        case "TodoWrite", "TodoRead": return l10n.t("Todo")
        case "WebFetch": return l10n.t("Fetch")
        case "WebSearch": return l10n.t("Search")
        case "NotebookEdit": return l10n.t("Notebook")
        case "BashOutput": return l10n.t("Bash")
        case "KillShell": return l10n.t("Shell")
        case "EnterPlanMode", "ExitPlanMode": return l10n.t("Plan")
        case "SlashCommand": return l10n.t("Command")
        default: return nil
        }
    }

    /// Checks if tool name is in MCP format (e.g., "mcp__deepwiki__ask_question")
    static func isMCPTool(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }

    /// Converts snake_case to Title Case
    /// e.g., "ask_question" → "Ask Question"
    static func toTitleCase(_ snakeCase: String) -> String {
        snakeCase
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// 把 MCP 工具 ID 转成可读名称
    /// 例如 "mcp__deepwiki__ask_question" → "Deepwiki - Ask Question"
    /// 有别名时返回别名，否则返回原名称
    static func formatToolName(_ toolId: String) -> String {
        // 优先使用别名
        if let alias = toolAlias(for: toolId) {
            return alias
        }

        guard isMCPTool(toolId) else { return toolId }

        // Remove "mcp__" prefix and split by "__"
        let withoutPrefix = String(toolId.dropFirst(5)) // Drop "mcp__"
        let parts = withoutPrefix.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)

        guard parts.count >= 1 else { return toolId }

        let serverName = toTitleCase(String(parts[0]))

        if parts.count >= 2 {
            // The second part starts with "_" which we need to drop
            let toolNameRaw = String(parts[1]).hasPrefix("_")
                ? String(String(parts[1]).dropFirst())
                : String(parts[1])
            let toolName = toTitleCase(toolNameRaw)
            return "\(serverName) - \(toolName)"
        }

        return serverName
    }

    /// Formats tool input dictionary for display
    /// e.g., ["repoName": "facebook/react", "question": "How does..."] → `repoName: "facebook/react", question: "How does..."`
    /// Truncates long values and limits number of args shown
    static func formatArgs(_ input: [String: String], maxValueLength: Int = 30, maxArgs: Int = 3) -> String {
        guard !input.isEmpty else { return "" }

        let sortedKeys = input.keys.sorted()
        var formattedParts: [String] = []

        for key in sortedKeys.prefix(maxArgs) {
            guard let value = input[key] else { continue }

            let truncatedValue: String
            if value.count > maxValueLength {
                truncatedValue = String(value.prefix(maxValueLength)) + "..."
            } else {
                truncatedValue = value
            }

            formattedParts.append("\(key): \"\(truncatedValue)\"")
        }

        var result = formattedParts.joined(separator: ", ")

        if sortedKeys.count > maxArgs {
            result += ", ..."
        }

        return result
    }

    /// Formats tool input from Any dictionary (handles both String and non-String values)
    static func formatArgs(_ input: [String: Any], maxValueLength: Int = 30, maxArgs: Int = 3) -> String {
        guard !input.isEmpty else { return "" }

        let sortedKeys = input.keys.sorted()
        var formattedParts: [String] = []

        for key in sortedKeys.prefix(maxArgs) {
            guard let value = input[key] else { continue }

            let stringValue: String
            if let str = value as? String {
                stringValue = str
            } else if let bool = value as? Bool {
                stringValue = bool ? "true" : "false"
            } else if let num = value as? NSNumber {
                stringValue = num.stringValue
            } else {
                stringValue = String(describing: value)
            }

            let truncatedValue: String
            if stringValue.count > maxValueLength {
                truncatedValue = String(stringValue.prefix(maxValueLength)) + "..."
            } else {
                truncatedValue = stringValue
            }

            formattedParts.append("\(key): \"\(truncatedValue)\"")
        }

        var result = formattedParts.joined(separator: ", ")

        if sortedKeys.count > maxArgs {
            result += ", ..."
        }

        return result
    }
}
