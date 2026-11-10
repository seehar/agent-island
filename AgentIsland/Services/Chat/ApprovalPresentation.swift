//
//  ApprovalPresentation.swift
//  AgentIsland
//
//  审批卡片要看的东西：一行摘要、完整摊开的输入、原始 JSON。
//
//  这些原先挂在 `Models/SessionPhase.swift` 的 `PermissionContext` 上——模型层里
//  混进了「Bash 只显示命令、Write 只显示文件名」这类展示口径，还硬编码了工具名。
//  展示策略改到 Services/Chat 这一层：模型只描述事实（哪个工具、什么入参）。
//

import Foundation

/// 审批展示要用到的工具名。
///
/// 只收这一层真正分支的工具（摘要/详情对它们有专门口径）；其余工具走通用取值优先级。
nonisolated enum ApprovalToolName {
    static let bash = "Bash"
    static let write = "Write"
    static let edit = "Edit"
    static let read = "Read"
}

nonisolated extension PermissionContext {
    /// Format tool input for display
    var formattedInput: String? {
        guard let input = toolInput else { return nil }

        // For Bash, prioritize showing the command
        if toolName == ApprovalToolName.bash, let command = input["command"]?.text {
            return command.count > 100 ? String(command.prefix(100)) + "..." : command
        }

        // For Write/Edit, show the file path
        if toolName == ApprovalToolName.write || toolName == ApprovalToolName.edit,
            let path = input["file_path"]?.text
        {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        // For Read, show the file path
        if toolName == ApprovalToolName.read, let path = input["file_path"]?.text {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        // Default: show first string value found (skip description)
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = input[key]?.value as? String {
                return value.count > 100 ? String(value.prefix(100)) + "..." : value
            }
        }

        // Fallback: first non-description string
        for (key, value) in input where key != "description" {
            if let str = value.text {
                return str.count > 100 ? String(str.prefix(100)) + "..." : str
            }
        }

        return nil
    }

    /// 审批详情：把要授权的输入**完整**摊开，供对话面的审批块使用。
    ///
    /// 与 `formattedInput` 分工不同：那个是列表行里的一行摘要（Write/Edit/Read 只给
    /// 文件名、Bash 截到 100 字），窄行放得下但看不出「到底要动哪个路径、跑哪条命令」。
    /// 审批是要用户**看懂再放行**的一步，因此这里给完整路径与整条命令，不截断
    /// （多行内容由审批块自己滚动，不由数据层裁剪）。
    var detailedInput: String? {
        guard let input = toolInput else { return nil }

        // Bash：整条命令（含多行脚本）
        if toolName == ApprovalToolName.bash, let command = input["command"]?.text {
            return command
        }

        // Write/Edit/Read：完整路径，而不是文件名
        if toolName == ApprovalToolName.write || toolName == ApprovalToolName.edit
            || toolName == ApprovalToolName.read,
            let path = input["file_path"]?.text
        {
            return path
        }

        // 其余工具按与摘要同一套取值优先级，只是不截断
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = input[key]?.value as? String {
                return value
            }
        }

        for (key, value) in input where key != "description" {
            if let str = value.text {
                return str
            }
        }

        return nil
    }

    /// 原始工具入参的 JSON（审批块的「详情」展开态显示）。
    ///
    /// 键排序 + 缩进：审批的最后一层是逐字核对，键顺序随机会让同一份入参每次看起来
    /// 都不一样。没有入参（旧集成不带）时返回 `nil`，视图据此不画详情开关。
    var rawInputJSON: String? {
        guard let input = toolInput, !input.isEmpty else { return nil }

        let encoder = JSONEncoder()
        // 不转义斜杠：这份 JSON 是直接给人逐字核对的，`\/tmp\/a.swift` 这种转义会让
        // 路径比原文更难比对，也更容易在复制出去时被二次转义。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
