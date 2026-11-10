//
//  ToolResultViews+Files.swift
//  AgentIsland
//
//  Read / Edit / Write 结果视图，以及文件内容、代码预览、文件列表等共用渲染件。
//

import SwiftUI

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
                SimpleDiffView(
                    oldString: oldString, newString: newString, filename: result.filename)
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
        ToolOutputWindow.visibleLineCount(
            total: lines.count, limit: maxLines, isExpanded: isExpanded)
    }

    private var hiddenLineCount: Int {
        ToolOutputWindow.hiddenLineCount(
            total: lines.count, limit: maxLines, isExpanded: isExpanded)
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
                .clipShape(
                    RoundedCorner(radius: AppRadius.control, corners: [.bottomLeft, .bottomRight]))
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
            .clipShape(
                RoundedCorner(
                    radius: AppRadius.control, corners: isLast ? [.bottomLeft, .bottomRight] : []))
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
        ToolOutputWindow.visibleLineCount(
            total: lines.count, limit: maxLines, isExpanded: isExpanded)
    }

    private var hiddenLineCount: Int {
        ToolOutputWindow.hiddenLineCount(
            total: lines.count, limit: maxLines, isExpanded: isExpanded)
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
