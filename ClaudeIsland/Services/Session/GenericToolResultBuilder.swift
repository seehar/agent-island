//
//  GenericToolResultBuilder.swift
//  ClaudeIsland
//
//  把「工具名 + 入参 + 文本结果」映射成应用统一的结构化结果。Claude Code 有
//  自带的 `toolUseResult` 字段（见 `ClaudeToolResults`），而 pi/omp 与 OpenCode
//  只给文本结果，因此这里按工具名做一次形状推断，让聊天视图能用同一套渲染。
//

import Foundation

nonisolated enum GenericToolResultBuilder {
    /// 依据工具名与本机 Agent 的通用入参约定生成结构化结果。
    ///
    /// 不认识的工具回退到 `GenericResult`（原样展示文本），保证任何工具都有内容可看。
    static func build(
        toolName: String,
        input: [String: String],
        output: String?,
        isError: Bool
    ) -> ToolResultData {
        let name = normalizedName(toolName)
        let text = output ?? ""

        switch name {
        case "read", "cat", "notebook_read":
            let lineCount =
                text.isEmpty
                ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
            return .read(
                ReadResult(
                    filePath: firstValue(input, ["file_path", "path", "filePath", "file"]) ?? "",
                    content: text,
                    numLines: lineCount,
                    startLine: 1,
                    totalLines: lineCount
                ))

        case "bash", "shell", "run_command", "sh":
            return .bash(
                BashResult(
                    stdout: isError ? "" : text,
                    stderr: isError ? text : "",
                    interrupted: false,
                    isImage: false,
                    returnCodeInterpretation: nil,
                    backgroundTaskId: nil
                ))

        case "grep", "ripgrep", "search":
            let lineCount =
                text.isEmpty
                ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
            return .grep(
                GrepResult(
                    mode: .content,
                    filenames: [],
                    numFiles: 0,
                    content: text,
                    numLines: lineCount,
                    appliedLimit: nil
                ))

        case "glob", "find", "ls":
            let files = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return .glob(
                GlobResult(
                    filenames: files,
                    durationMs: 0,
                    numFiles: files.count,
                    truncated: false
                ))

        case "write", "create_file":
            return .write(
                WriteResult(
                    type: .create,
                    filePath: firstValue(input, ["file_path", "path", "filePath", "file"]) ?? "",
                    content: firstValue(input, ["content", "text", "data"]) ?? "",
                    structuredPatch: nil
                ))

        case "edit", "apply_patch", "multiedit", "str_replace":
            return .edit(
                EditResult(
                    filePath: firstValue(input, ["file_path", "path", "filePath", "file"]) ?? "",
                    oldString: firstValue(input, ["old_string", "oldString", "old", "find"]) ?? "",
                    newString: firstValue(input, ["new_string", "newString", "new", "replace"])
                        ?? "",
                    replaceAll: input["replace_all"] == "true",
                    userModified: false,
                    structuredPatch: nil
                ))

        case "web_fetch", "fetch":
            return .webFetch(
                WebFetchResult(
                    url: firstValue(input, ["url", "uri"]) ?? "",
                    code: isError ? 0 : 200,
                    codeText: isError ? "error" : "ok",
                    bytes: text.utf8.count,
                    durationMs: 0,
                    result: text
                ))

        case "web_search":
            return .webSearch(
                WebSearchResult(
                    query: firstValue(input, ["query", "q"]) ?? "",
                    durationSeconds: 0,
                    results: []
                ))

        default:
            return .generic(GenericResult(rawContent: text.isEmpty ? nil : text, rawData: [:]))
        }
    }

    /// 工具名归一：去掉大小写与 MCP/命名空间前缀的差异（`Read` / `read` / `mcp__fs_read`）。
    static func normalizedName(_ toolName: String) -> String {
        var name = toolName.lowercased()
        if let separator = name.range(of: "__", options: .backwards) {
            name = String(name[separator.upperBound...])
        }
        return name
    }

    /// 是否为「编辑类」工具（Claude 用 `Edit`，pi/omp 用 `edit`，OpenCode 用 `edit`/`write`）。
    static func isEditLike(_ toolName: String) -> Bool {
        let name = normalizedName(toolName)
        return name == "edit" || name == "apply_patch" || name == "multiedit"
            || name == "str_replace"
    }

    /// 按候选顺序取第一个非空入参。
    private static func firstValue(_ input: [String: String], _ keys: [String]) -> String? {
        for key in keys {
            if let value = input[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
