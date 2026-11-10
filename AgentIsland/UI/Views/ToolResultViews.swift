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

    /// 折行估算用的每行字符数：对话面内容宽约 456pt（480pt 面板减卡片侧内边距 24），
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
            path.addArc(
                center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()

        return path
    }
}
