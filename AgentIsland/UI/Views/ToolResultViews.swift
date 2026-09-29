//
//  ToolResultViews.swift
//  AgentIsland
//
//  Individual views for rendering each tool's result with proper formatting
//

import SwiftUI

// MARK: - Tool Result Content Dispatcher

struct ToolResultContent: View {
    let tool: ToolCallItem

    var body: some View {
        if let structured = tool.structuredResult {
            switch structured {
            case .read(let r):
                ReadResultContent(result: r)
            case .edit(let r):
                EditResultContent(result: r, toolInput: tool.input)
            case .write(let r):
                WriteResultContent(result: r)
            case .bash(let r):
                BashResultContent(result: r)
            case .grep(let r):
                GrepResultContent(result: r)
            case .glob(let r):
                GlobResultContent(result: r)
            case .todoWrite(let r):
                TodoWriteResultContent(result: r)
            case .task(let r):
                TaskResultContent(result: r)
            case .webFetch(let r):
                WebFetchResultContent(result: r)
            case .webSearch(let r):
                WebSearchResultContent(result: r)
            case .askUserQuestion(let r):
                AskUserQuestionResultContent(result: r)
            case .bashOutput(let r):
                BashOutputResultContent(result: r)
            case .killShell(let r):
                KillShellResultContent(result: r)
            case .exitPlanMode(let r):
                ExitPlanModeResultContent(result: r)
            case .mcp(let r):
                MCPResultContent(result: r)
            case .generic(let r):
                GenericResultContent(result: r)
            }
        } else if GenericToolResultBuilder.isEditLike(tool.name) {
            // Special fallback for Edit - show diff from input params
            EditInputDiffView(input: tool.input)
        } else if let result = tool.result {
            // Fallback to raw text display
            GenericTextContent(text: result)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Edit Input Diff View (fallback when no structured result)

struct EditInputDiffView: View {
    let input: [String: String]

    private var filename: String {
        if let path = input["file_path"] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "file"
    }

    private var oldString: String {
        input["old_string"] ?? ""
    }

    private var newString: String {
        input["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show diff from input with integrated filename
            if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: filename)
            }
        }
    }
}

// MARK: - Read Result View

struct ReadResultContent: View {
    let result: ReadResult

    var body: some View {
        if !result.content.isEmpty {
            FileCodeView(
                filename: result.filename,
                content: result.content,
                startLine: result.startLine,
                totalLines: result.totalLines,
                maxLines: 10
            )
        }
    }
}

// MARK: - Edit Result View

struct EditResultContent: View {
    let result: EditResult
    var toolInput: [String: String] = [:]
    @ObservedObject private var l10n = LocalizationManager.shared

    /// Get old string - prefer result, fallback to input
    private var oldString: String {
        if !result.oldString.isEmpty {
            return result.oldString
        }
        return toolInput["old_string"] ?? ""
    }

    /// Get new string - prefer result, fallback to input
    private var newString: String {
        if !result.newString.isEmpty {
            return result.newString
        }
        return toolInput["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always use SimpleDiffView for consistent styling (no @@ headers)
            if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: result.filename)
            }

            if result.userModified {
                Text(l10n.t("(User modified)"))
                    .appFont(10)
                    .foregroundColor(AppPalette.warning)
            }
        }
    }
}

// MARK: - Write Result View

struct WriteResultContent: View {
    let result: WriteResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Action and filename
            HStack(spacing: 4) {
                Text(result.type == .create ? l10n.t("Created") : l10n.t("Wrote"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
                Text(result.filename)
                    .appFont(11, weight: .medium, design: .monospaced)
                    .foregroundColor(AppPalette.primaryText)
            }

            // Content preview for new files
            if result.type == .create && !result.content.isEmpty {
                CodePreview(content: result.content, maxLines: 8)
            } else if let patches = result.structuredPatch, !patches.isEmpty {
                DiffView(patches: patches)
            }
        }
    }
}

// MARK: - Bash Result View

struct BashResultContent: View {
    let result: BashResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background task indicator
            if let bgId = result.backgroundTaskId {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .appFont(10)
                    Text(l10n.t("Background task: %@", bgId))
                        .appFont(10, design: .monospaced)
                }
                .foregroundColor(.blue.opacity(0.7))
            }

            // Return code interpretation
            if let interpretation = result.returnCodeInterpretation {
                Text(interpretation)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
            }

            // Stdout
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 15)
            }

            // Stderr (shown in red)
            if !result.stderr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("stderr:"))
                        .appFont(10, weight: .medium)
                        .foregroundColor(AppPalette.danger)
                    // 与 stdout 同一条路径：stderr 才是编译报错/栈这类真正要看全、要拷走的长文本
                    // （改动前这里硬封 10 行，且没有展开与复制入口）。
                    GenericTextContent(text: result.stderr, color: AppPalette.danger)
                }
            }

            // Empty state
            if !result.hasOutput && result.backgroundTaskId == nil && result.returnCodeInterpretation == nil {
                Text(l10n.t("(No content)"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
            }
        }
    }
}

// MARK: - Grep Result View

struct GrepResultContent: View {
    let result: GrepResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.mode {
            case .filesWithMatches:
                // Show file list
                if result.filenames.isEmpty {
                    Text(l10n.t("No matches found"))
                        .appFont(11, design: .monospaced)
                        .foregroundColor(AppPalette.subtleText)
                } else {
                    FileListView(files: result.filenames, limit: 10)
                }

            case .content:
                // Show matching content
                if let content = result.content, !content.isEmpty {
                    CodePreview(content: content, maxLines: 15)
                } else {
                    Text(l10n.t("No matches found"))
                        .appFont(11, design: .monospaced)
                        .foregroundColor(AppPalette.subtleText)
                }

            case .count:
                Text(l10n.t("%lld files with matches", result.numFiles))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
            }
        }
    }
}

// MARK: - Glob Result View

struct GlobResultContent: View {
    let result: GlobResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.filenames.isEmpty {
                Text(l10n.t("No files found"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
            } else {
                FileListView(files: result.filenames, limit: 10)

                if result.truncated {
                    Text(l10n.t("... and more (truncated)"))
                        .appFont(10)
                        .foregroundColor(AppPalette.subtleText)
                }
            }
        }
    }
}

// MARK: - TodoWrite Result View

struct TodoWriteResultContent: View {
    let result: TodoWriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(result.newTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    // Status icon
                    Image(systemName: todoIcon(for: todo.status))
                        .appFont(10)
                        .foregroundColor(todoColor(for: todo.status))
                        .frame(width: 12)

                    Text(todo.content)
                        .appFont(11)
                        .foregroundColor(todo.status == "completed" ? AppPalette.tertiaryText : AppPalette.primaryText)
                        .strikethrough(todo.status == "completed")
                        .lineLimit(2)
                }
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": return AppPalette.success
        case "in_progress": return AppPalette.warning
        default: return AppPalette.tertiaryText
        }
    }
}

// MARK: - Task Result View

struct TaskResultContent: View {
    let result: TaskResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status and stats
            HStack(spacing: 8) {
                Text(result.status.capitalized)
                    .appFont(11, weight: .medium)
                    .foregroundColor(statusColor)

                if let duration = result.totalDurationMs {
                    Text("\(formatDuration(duration))")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.tertiaryText)
                }

                if let tools = result.totalToolUseCount {
                    Text(l10n.t("%lld tools", tools))
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.tertiaryText)
                }
            }

            // Content summary
            if !result.content.isEmpty {
                Text(result.content.prefix(200) + (result.content.count > 200 ? "..." : ""))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(5)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case "completed": return AppPalette.success
        case "in_progress": return AppPalette.warning
        case "failed", "error": return AppPalette.danger
        default: return AppPalette.secondaryText
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60000 {
            return l10n.t("%lldm %llds", ms / 60000, (ms % 60000) / 1000)
        } else if ms >= 1000 {
            return l10n.t("%llds", ms / 1000)
        }
        return l10n.t("%lldms", ms)
    }
}

// MARK: - WebFetch Result View

struct WebFetchResultContent: View {
    let result: WebFetchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // URL and status
            HStack(spacing: 6) {
                Text("\(result.code)")
                    .appFont(10, weight: .medium, design: .monospaced)
                    .foregroundColor(result.code < 400 ? AppPalette.success : AppPalette.danger)

                Text(truncateUrl(result.url))
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(1)
            }

            // Result summary
            if !result.result.isEmpty {
                Text(result.result.prefix(300) + (result.result.count > 300 ? "..." : ""))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(8)
            }
        }
    }

    private func truncateUrl(_ url: String) -> String {
        if url.count > 50 {
            return String(url.prefix(47)) + "..."
        }
        return url
    }
}

// MARK: - WebSearch Result View

struct WebSearchResultContent: View {
    let result: WebSearchResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.results.isEmpty {
                Text(l10n.t("No results found"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
            } else {
                ForEach(Array(result.results.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .appFont(11, weight: .medium)
                            .foregroundColor(.blue.opacity(0.8))
                            .lineLimit(1)

                        if !item.snippet.isEmpty {
                            Text(item.snippet)
                                .appFont(10)
                                .foregroundColor(AppPalette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }

                if result.results.count > 5 {
                    Text(l10n.t("... and %lld more results", result.results.count - 5))
                        .appFont(10)
                        .foregroundColor(AppPalette.subtleText)
                }
            }
        }
    }
}

// MARK: - AskUserQuestion Result View

struct AskUserQuestionResultContent: View {
    let result: AskUserQuestionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    // Question
                    Text(question.question)
                        .appFont(11)
                        .foregroundColor(AppPalette.secondaryText)

                    // Answer
                    if let answer = result.answers["\(index)"] {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .appFont(9)
                            Text(answer)
                                .appFont(11, weight: .medium)
                        }
                        .foregroundColor(AppPalette.success)
                    }
                }
            }
        }
    }
}

// MARK: - BashOutput Result View

struct BashOutputResultContent: View {
    let result: BashOutputResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack(spacing: 6) {
                Text(l10n.t("Status: %@", result.status))
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)

                if let exitCode = result.exitCode {
                    Text(l10n.t("Exit: %lld", exitCode))
                        .appFont(10, design: .monospaced)
                        .foregroundColor(exitCode == 0 ? AppPalette.success : AppPalette.danger)
                }
            }

            // Output
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 10)
            }

            if !result.stderr.isEmpty {
                GenericTextContent(text: result.stderr, color: AppPalette.danger)
            }
        }
    }
}

// MARK: - KillShell Result View

struct KillShellResultContent: View {
    let result: KillShellResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .appFont(11)
                .foregroundColor(AppPalette.danger)

            Text(result.message.isEmpty ? l10n.t("Shell %@ terminated", result.shellId) : result.message)
                .appFont(11, design: .monospaced)
                .foregroundColor(AppPalette.secondaryText)
        }
    }
}

// MARK: - ExitPlanMode Result View

struct ExitPlanModeResultContent: View {
    let result: ExitPlanModeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = result.filePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .appFont(10)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .appFont(11, design: .monospaced)
                }
                .foregroundColor(AppPalette.secondaryText)
            }

            if let plan = result.plan, !plan.isEmpty {
                Text(plan.prefix(200) + (plan.count > 200 ? "..." : ""))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(6)
            }
        }
    }
}

// MARK: - MCP Result View

struct MCPResultContent: View {
    let result: MCPResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Server and tool info (formatted as Title Case)
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece")
                    .appFont(10)
                Text("\(MCPToolFormatter.toTitleCase(result.serverName)) - \(MCPToolFormatter.toTitleCase(result.toolName))")
                    .appFont(10, design: .monospaced)
            }
            .foregroundColor(.purple.opacity(0.7))

            // Raw result (formatted as key-value pairs)
            ForEach(Array(result.rawResult.prefix(5)), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.tertiaryText)
                    Text("\(String(describing: value).prefix(100))")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.secondaryText)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Generic Result View

struct GenericResultContent: View {
    let result: GenericResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        if let content = result.rawContent, !content.isEmpty {
            GenericTextContent(text: content)
        } else {
            Text(l10n.t("Completed"))
                .appFont(11, design: .monospaced)
                .foregroundColor(AppPalette.subtleText)
        }
    }
}

// MARK: - 长输出的折叠窗口

/// 长输出（工具结果、文件内容）的折叠/展开算术。
///
/// 单独抽成 `nonisolated` 的纯函数放在视图外：「可见行数、仍被挡住的行数、
/// 要不要给展开入口、按钮用哪条文案」只由「总行数 / 折叠上限 / 是否展开」三个数
/// 决定，因此可以单测钉住，不必渲染 SwiftUI。
nonisolated enum ToolOutputWindow {
    /// 展开态的高度上限（pt）。
    ///
    /// 展开不能无限撑高：对话区总高 580pt（见 `NotchViewModel` 的
    /// `scaledPanelHeight(580)`），扣掉头部与底部输入条后消息列表可用高度约 440pt。
    /// 单块输出超过可用高度会让用户「看不完也滚不动」，所以取 240pt——约占可用
    /// 高度的一半，展开后仍看得见上下文。
    static let expandedMaxHeight: CGFloat = 240

    /// 折行估算用的每行字符数：对话面内容宽约 464pt（480pt 面板减两侧外边距），
    /// 11pt 等宽字每字符约 6.6pt → 一行约 70 个字符；取 64 留一点保守余量。
    static let estimatedCharactersPerLine = 64

    /// 折叠态可见行数；展开态可见全部行。
    static func visibleLineCount(total: Int, limit: Int, isExpanded: Bool) -> Int {
        guard total > 0 else { return 0 }
        guard !isExpanded else { return total }
        return min(total, max(0, limit))
    }

    /// 折叠态仍被挡住的行数（展开态为 0），用于「…（还有 N 行）」。
    /// 夹到 0 以上：负数会让文案变成「还有 -3 行」。
    static func hiddenLineCount(total: Int, limit: Int, isExpanded: Bool) -> Int {
        max(0, total - visibleLineCount(total: total, limit: limit, isExpanded: isExpanded))
    }

    /// 是否真被截断过——只有截断过的块才给「展开全部 / 收起」入口。
    static func isTruncated(total: Int, limit: Int) -> Bool {
        total > max(0, limit)
    }

    /// 会折行的文本（靠 `lineLimit` 按**视觉行**裁剪）的可见行数估算。
    ///
    /// 这类文本不能直接用换行符数行：整段 JSON 挤在一行时逻辑行数是 1，但它早就
    /// 被 `lineLimit` 裁掉了。取「逻辑行数」与「按宽度折出来的行数」的大者。
    static func estimatedWrappedLineCount(
        of text: String,
        charactersPerLine: Int = estimatedCharactersPerLine
    ) -> Int {
        let logicalLineCount = text.components(separatedBy: "\n").count
        let perLine = max(1, charactersPerLine)
        let wrappedLineCount = (text.count + perLine - 1) / perLine
        return max(logicalLineCount, wrappedLineCount)
    }

    /// 展开/收起按钮用哪条文案。真正的查表仍走 `l10n`，这里只决定用哪个键，
    /// 所以可以单测。
    enum ToggleLabel: Equatable {
        case collapse
        case showAll(lineCount: Int)
    }

    static func toggleLabel(total: Int, isExpanded: Bool) -> ToggleLabel {
        isExpanded ? .collapse : .showAll(lineCount: max(0, total))
    }
}

/// 「展开全部 / 收起」行内按钮：只切换行数窗口，不改变折叠上限之外的版面。
struct ToolOutputToggleButton: View {
    let total: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Button(action: onToggle) {
            Text(label)
                .appFont(10, weight: .medium)
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
    }

    private var label: String {
        switch ToolOutputWindow.toggleLabel(total: total, isExpanded: isExpanded) {
        case .collapse:
            return l10n.t("Collapse")
        case .showAll(let lineCount):
            return l10n.t("Show all %lld lines", lineCount)
        }
    }
}

struct GenericTextContent: View {
    let text: String
    /// 文本颜色：默认是常规正文色；stderr 这类要用红色传 `AppPalette.danger`。
    var color: Color = AppPalette.secondaryText

    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isExpanded = false

    /// 折叠态的行数上限：与改动前的 `.lineLimit(15)` 一致。
    private static let collapsedLineLimit = 15

    var body: some View {
        // 行数只估一次：`estimatedWrappedLineCount` 会对整串做一次切分，而工具输出没有长度
        // 上限（几万行的 stdout 整串塞在这里），流式期间每帧求值多次就是每帧多切几次。
        let lineCount = ToolOutputWindow.estimatedWrappedLineCount(of: text)
        let hiddenLineCount = ToolOutputWindow.hiddenLineCount(
            total: lineCount, limit: Self.collapsedLineLimit, isExpanded: isExpanded)
        let isTruncated = ToolOutputWindow.isTruncated(
            total: lineCount, limit: Self.collapsedLineLimit)

        VStack(alignment: .leading, spacing: 2) {
            if isExpanded {
                // 展开态限高 + 可滚动：看得到全部，又不把对话区撑成一条长瀑布。
                ScrollView(.vertical) {
                    Text(text)
                        .appFont(11, design: .monospaced)
                        .foregroundColor(color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ToolOutputWindow.expandedMaxHeight)
            } else {
                Text(text)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(color)
                    .lineLimit(Self.collapsedLineLimit)
            }

            // 控制行：折叠态的「还有 N 行」沿用原样，右侧是复制与展开入口。
            HStack(spacing: 8) {
                if hiddenLineCount > 0 {
                    Text(l10n.t("... (%lld more lines)", hiddenLineCount))
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.subtleText)
                }

                Spacer(minLength: 0)

                CopyButton(text: text)

                if isTruncated {
                    ToolOutputToggleButton(total: lineCount, isExpanded: isExpanded) {
                        isExpanded.toggle()
                    }
                }
            }
        }
    }
}

// MARK: - Helper Views

/// File code view with filename header and line numbers (matches Edit tool styling)
struct FileCodeView: View {
    let filename: String
    let content: String
    let startLine: Int
    let totalLines: Int
    @ObservedObject private var l10n = LocalizationManager.shared
    let maxLines: Int

    @State private var isExpanded = false

    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        Array(lines.prefix(visibleLineCount))
    }

    private var visibleLineCount: Int {
        ToolOutputWindow.visibleLineCount(total: lines.count, limit: maxLines, isExpanded: isExpanded)
    }

    private var hiddenLineCount: Int {
        ToolOutputWindow.hiddenLineCount(total: lines.count, limit: maxLines, isExpanded: isExpanded)
    }

    private var isTruncated: Bool {
        ToolOutputWindow.isTruncated(total: lines.count, limit: maxLines)
    }

    /// 是否画底部信息行（「还有 N 行」与收起入口共用这一行，不额外加高）。
    private var showsFooterRow: Bool {
        hiddenLineCount > 0 || isTruncated
    }

    private var hasLinesBefore: Bool {
        startLine > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .appFont(10)
                    .foregroundColor(AppPalette.tertiaryText)
                Text(filename)
                    .appFont(11, weight: .medium, design: .monospaced)
                    .foregroundColor(AppPalette.primaryText)

                Spacer(minLength: 8)

                // 复制的是整份内容（不是界面上折叠后的那几行）。
                CopyButton(text: content)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AppPalette.cardFill)
            .clipShape(RoundedCorner(radius: AppRadius.control, corners: [.topLeft, .topRight]))

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(AppPalette.cardFill)
            }

            // 代码行：展开态限高 + 懒加载滚动（几百行的文件一次性铺开会卡），
            // 折叠态沿用原来的「只铺前 maxLines 行」。
            if isExpanded {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        codeLineRows
                    }
                }
                .frame(maxHeight: ToolOutputWindow.expandedMaxHeight)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    codeLineRows
                }
            }

            // Bottom row：折叠时是「…（还有 N 行）」+ 展开入口，展开时只剩收起。
            if showsFooterRow {
                HStack(spacing: 8) {
                    if hiddenLineCount > 0 {
                        Text(l10n.t("... (%lld more lines)", hiddenLineCount))
                            .appFont(10, design: .monospaced)
                            .foregroundColor(AppPalette.subtleText)
                    }

                    Spacer(minLength: 0)

                    if isTruncated {
                        ToolOutputToggleButton(total: lines.count, isExpanded: isExpanded) {
                            isExpanded.toggle()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 46)
                .padding(.vertical, 3)
                .background(AppPalette.cardFill)
                .clipShape(RoundedCorner(radius: AppRadius.control, corners: [.bottomLeft, .bottomRight]))
            }
        }
    }

    /// 可见行（带行号）。最后一行只有在它下面不再跟信息行时才收底角。
    @ViewBuilder
    private var codeLineRows: some View {
        ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
            let lineNumber = startLine + index
            let isLast = index == displayLines.count - 1 && !showsFooterRow
            CodeLineView(
                line: line,
                lineNumber: lineNumber,
                isLast: isLast
            )
        }
    }

    private struct CodeLineView: View {
        let line: String
        let lineNumber: Int
        let isLast: Bool

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 8)

                // Line content
                Text(line.isEmpty ? " " : line)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(AppPalette.cardFill)
            .clipShape(RoundedCorner(radius: AppRadius.control, corners: isLast ? [.bottomLeft, .bottomRight] : []))
        }
    }
}

struct CodePreview: View {
    let content: String
    let maxLines: Int
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isExpanded = false

    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    private var visibleLineCount: Int {
        ToolOutputWindow.visibleLineCount(total: lines.count, limit: maxLines, isExpanded: isExpanded)
    }

    private var hiddenLineCount: Int {
        ToolOutputWindow.hiddenLineCount(total: lines.count, limit: maxLines, isExpanded: isExpanded)
    }

    private var isTruncated: Bool {
        ToolOutputWindow.isTruncated(total: lines.count, limit: maxLines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isExpanded {
                // 展开态限高 + 懒加载行：几百行的 `swift test` 输出铺成普通 VStack
                // 会一次建立所有行，滚动会卡。
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        lineRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ToolOutputWindow.expandedMaxHeight)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    lineRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 控制行：折叠态的「还有 N 行」沿用原样，右侧是复制与展开入口。
            // 只有一行文字那么高，不会把块撑高一截；占位宽度固定，所以点击复制
            // 前后行高与相邻元素位置都不动。
            HStack(spacing: 8) {
                if hiddenLineCount > 0 {
                    Text(l10n.t("... (%lld more lines)", hiddenLineCount))
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.subtleText)
                }

                Spacer(minLength: 0)

                // 复制的是整份输出（不是界面上折叠后的那几行）。
                CopyButton(text: content)

                if isTruncated {
                    ToolOutputToggleButton(total: lines.count, isExpanded: isExpanded) {
                        isExpanded.toggle()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lineRows: some View {
        ForEach(Array(lines.prefix(visibleLineCount).enumerated()), id: \.offset) { _, line in
            Text(line.isEmpty ? " " : line)
                .appFont(11, design: .monospaced)
                .foregroundColor(AppPalette.secondaryText)
        }
    }
}

struct FileListView: View {
    let files: [String]
    let limit: Int
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(files.prefix(limit).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .appFont(9)
                        .foregroundColor(AppPalette.subtleText)
                    Text(URL(fileURLWithPath: file).lastPathComponent)
                        .appFont(11, design: .monospaced)
                        .foregroundColor(AppPalette.secondaryText)
                        .lineLimit(1)
                }
            }

            if files.count > limit {
                Text(l10n.t("... and %lld more files", files.count - limit))
                    .appFont(10)
                    .foregroundColor(AppPalette.subtleText)
            }
        }
    }
}

struct DiffView: View {
    let patches: [PatchHunk]
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(patches.prefix(3).enumerated()), id: \.offset) { _, patch in
                VStack(alignment: .leading, spacing: 1) {
                    // Hunk header
                    Text("@@ -\(patch.oldStart),\(patch.oldLines) +\(patch.newStart),\(patch.newLines) @@")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(.cyan.opacity(0.7))

                    // Lines
                    ForEach(Array(patch.lines.prefix(10).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }

                    if patch.lines.count > 10 {
                        Text(l10n.t("... (%lld more lines)", patch.lines.count - 10))
                            .appFont(10, design: .monospaced)
                            .foregroundColor(AppPalette.subtleText)
                    }
                }
            }

            if patches.count > 3 {
                Text(l10n.t("... and %lld more hunks", patches.count - 3))
                    .appFont(10)
                    .foregroundColor(AppPalette.subtleText)
            }
        }
    }
}

struct DiffLineView: View {
    let line: String

    private var lineType: DiffLineType {
        if line.hasPrefix("+") {
            return .added
        } else if line.hasPrefix("-") {
            return .removed
        }
        return .context
    }

    var body: some View {
        Text(line)
            .appFont(11, design: .monospaced)
            .foregroundColor(lineType.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(lineType.backgroundColor)
    }
}

private enum DiffLineType {
    case added
    case removed
    case context

    var textColor: Color {
        switch self {
        case .added: return AppPalette.success
        case .removed: return AppPalette.danger
        case .context: return AppPalette.secondaryText
        }
    }

    var backgroundColor: Color {
        switch self {
        case .added: return AppPalette.success.opacity(0.15)
        case .removed: return AppPalette.danger.opacity(0.15)
        case .context: return .clear
        }
    }
}

struct SimpleDiffView: View {
    let oldString: String
    let newString: String
    var filename: String? = nil

    /// Compute diff using LCS algorithm
    private var diffLines: [DiffLine] {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")

        // Compute LCS to find matching lines
        let lcs = computeLCS(oldLines, newLines)

        var result: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            // Limit output
            if result.count >= 12 { break }

            let lcsLine = lcsIdx < lcs.count ? lcs[lcsIdx] : nil

            if oldIdx < oldLines.count && (lcsLine == nil || oldLines[oldIdx] != lcsLine) {
                // Line in old but not in LCS - removed
                result.append(DiffLine(text: oldLines[oldIdx], type: .removed, lineNumber: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < newLines.count && (lcsLine == nil || newLines[newIdx] != lcsLine) {
                // Line in new but not in LCS - added
                result.append(DiffLine(text: newLines[newIdx], type: .added, lineNumber: newIdx + 1))
                newIdx += 1
            } else {
                // Matching line in LCS - skip (context)
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            }
        }

        return result
    }

    /// Compute Longest Common Subsequence of two string arrays
    private func computeLCS(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count

        // DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var lcs: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs.reversed()
    }

    private var hasMoreChanges: Bool {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")
        let lcs = computeLCS(oldLines, newLines)
        let totalChanges = (oldLines.count - lcs.count) + (newLines.count - lcs.count)
        return totalChanges > 12
    }

    /// Whether there are lines before the first diff line
    private var hasLinesBefore: Bool {
        guard let firstLine = diffLines.first else { return false }
        return firstLine.lineNumber > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            if let name = filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .appFont(10)
                        .foregroundColor(AppPalette.tertiaryText)
                    Text(name)
                        .appFont(11, weight: .medium, design: .monospaced)
                        .foregroundColor(AppPalette.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppPalette.cardFill)
                .clipShape(RoundedCorner(radius: AppRadius.control, corners: [.topLeft, .topRight] as RoundedCorner.RectCorner))
            }

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(AppPalette.cardFill)
                    .clipShape(RoundedCorner(radius: AppRadius.control, corners: filename == nil ? [.topLeft, .topRight] as RoundedCorner.RectCorner : [] as RoundedCorner.RectCorner))
            }

            // Diff lines
            ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                let isFirst = index == 0 && filename == nil && !hasLinesBefore
                let isLast = index == diffLines.count - 1 && !hasMoreChanges
                DiffLineView(
                    line: line.text,
                    type: line.type,
                    lineNumber: line.lineNumber,
                    isFirst: isFirst,
                    isLast: isLast
                )
            }

            // Bottom overflow indicator
            if hasMoreChanges {
                Text("...")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(AppPalette.cardFill)
                    .clipShape(RoundedCorner(radius: AppRadius.control, corners: [.bottomLeft, .bottomRight] as RoundedCorner.RectCorner))
            }
        }
    }

    private struct DiffLine {
        let text: String
        let type: DiffLineType
        let lineNumber: Int
    }

    private struct DiffLineView: View {
        let line: String
        let type: DiffLineType
        let lineNumber: Int
        let isFirst: Bool
        let isLast: Bool

        private var corners: RoundedCorner.RectCorner {
            if isFirst && isLast {
                return .allCorners
            } else if isFirst {
                return [.topLeft, .topRight]
            } else if isLast {
                return [.bottomLeft, .bottomRight]
            }
            return []
        }

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(type.textColor.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 4)

                // +/- indicator
                Text(type == .added ? "+" : "-")
                    .appFont(11, weight: .medium, design: .monospaced)
                    .foregroundColor(type.textColor)
                    .frame(width: 14)

                // Line content
                Text(line.isEmpty ? " " : line)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(type.textColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(type.backgroundColor)
            .clipShape(RoundedCorner(radius: AppRadius.control, corners: corners))
        }
    }
}

// Helper for selective corner rounding (macOS compatible)
struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    struct RectCorner: OptionSet {
        let rawValue: Int
        static let topLeft = RectCorner(rawValue: 1 << 0)
        static let topRight = RectCorner(rawValue: 1 << 1)
        static let bottomLeft = RectCorner(rawValue: 1 << 2)
        static let bottomRight = RectCorner(rawValue: 1 << 3)
        static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                       radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                       radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                       radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                       radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()

        return path
    }
}
