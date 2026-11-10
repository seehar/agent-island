//
//  ChatView+Tools.swift
//  AgentIsland
//
//  ChatView 的工具调用与子 Agent 家族：工具行、子 Agent 实例行与工具清单。
//
//  自 ChatView.swift 按渲染家族拆出，类型与可见性保持不变（同模块内 internal）。
//

import SwiftUI

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    /// 子 Agent 的 job 名 → 任务描述；由会话状态透传（不再读第二份镜像）。
    let agentDescriptions: [String: String]
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 子代理明细开关（行为页）：关掉后只留摘要行，不列子代理内部工具。
    @ObservedObject private var subagentDetails = SessionDisplayPreferences.showSubagentDetails

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return Color.white
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .white.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT a subagent container, NOT Edit).
    private var canExpand: Bool {
        !tool.presentsAsSubagentContainer && !GenericToolResultBuilder.isEditLike(tool.name)
            && hasResult
    }

    private var showContent: Bool {
        GenericToolResultBuilder.isEditLike(tool.name) || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
            let agentId = tool.input["agentId"]
        else {
            return nil
        }
        return agentDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        statusColor.opacity(
                            tool.status == .running || tool.status == .waitingForApproval
                                ? pulseOpacity : 0.6)
                    )
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .appFont(12, weight: .medium)
                    .foregroundColor(textColor)
                    .fixedSize()

                if tool.presentsAsSubagentContainer {
                    // Claude 给的是子 Agent 内部的工具明细，omp/pi 给的是子 Agent 实例本身。
                    if !tool.subagentTools.isEmpty {
                        let taskDesc = tool.input["description"] ?? l10n.t("Running agent...")
                        Text(l10n.t("%@ (%lld tools)", taskDesc, tool.subagentTools.count))
                            .appFont(11)
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(l10n.t("%lld agents", tool.subagentRuns.count))
                            .appFont(11)
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? l10n.t("Waiting: %@", desc) : desc)
                        .appFont(11)
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .appFont(11)
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(tool.statusDisplay.text)
                        .appFont(11)
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .medium)
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }
            // 摘要行自己承载悬停高亮与「点一下展开/收起」：结果内容区留给文本选择
            // （对话面整体开了 `textSelection`），否则在输出里拖选会被这个点击手势抢走。
            // 命中区至少 22pt 高：摘要行本身只有 ~14pt（12pt 字号 × 行高），而**整块的收起**
            // 只有这一个入口（footer 的 Show all/Collapse 只管内层行数窗口），精确点中 14pt 太容易落空。
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(canExpand && isHovering ? Color.white.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture {
                if canExpand {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)

            // 子代理明细：只有开关打开时才列（关掉后保留上面那行摘要，上下文仍可判断）。
            if subagentDetails.isOn {
                // Subagent tools list (for Task/Agent tools)
                if tool.presentsAsSubagentContainer {
                    SubagentToolsList(tools: tool.subagentTools)
                        .padding(.leading, 12)
                        .padding(.top, 2)
                }

                // 子 Agent 行（omp/pi 通过 task 派发的实例）
                if !tool.subagentRuns.isEmpty {
                    SubagentRunsList(runs: tool.subagentRuns)
                        .padding(.leading, 12)
                        .padding(.top, 2)
                }
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && !tool.presentsAsSubagentContainer
                && (hasResult || tool.name == "Edit")
            {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if GenericToolResultBuilder.isEditLike(tool.name) && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Subagent Views

/// 一个 task 派发出来的子 Agent 列表（omp/pi）。
struct SubagentRunsList: View {
    let runs: [SubagentRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(runs) { run in
                SubagentRunRow(run: run)
            }
        }
    }
}

/// 单个子 Agent 行：实例名 + 类型 + 当前工具 + 状态。
struct SubagentRunRow: View {
    let run: SubagentRun
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch run.status {
        case .started, .running: return .orange
        case .completed: return .green
        case .failed, .aborted: return .red
        case .unknown: return .white.opacity(0.4)
        }
    }

    /// 状态词。运行中用工具状态文案（与普通工具行同源），未知状态不显示文字。
    private var statusText: String {
        switch run.status {
        case .started, .running:
            return ToolStatusDisplay.running(for: run.currentTool ?? "", input: [:]).text
        case .completed: return l10n.t("Completed")
        case .failed: return l10n.t("Failed")
        case .aborted: return l10n.t("Interrupted")
        case .unknown: return ""
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor.opacity(run.status.isRunning ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(run.status)
                .onAppear {
                    if run.status.isRunning {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // 实例名（omp 的 job 名，与它自己的产物页一致）
            Text(run.id)
                .appFont(10, weight: .medium)
                .foregroundColor(.white.opacity(0.6))

            if let agent = run.agent, !agent.isEmpty {
                Text(agent)
                    .appFont(10)
                    .foregroundColor(.white.opacity(0.35))
            }

            if let tool = run.currentTool, run.status.isRunning {
                Text(tool)
                    .appFont(10, design: .monospaced)
                    .foregroundColor(.white.opacity(0.4))
            }

            Text(statusText)
                .appFont(10)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    @ObservedObject private var l10n = LocalizationManager.shared

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text(l10n.t("+%lld more tool uses", hiddenCount))
                    .appFont(10)
                    .foregroundColor(.white.opacity(0.4))
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// 子代理工具行的状态文案。
///
/// 与「主工具行」（`ToolCallItem.statusDisplay`）同一套口径，差别只在子工具没有
/// 结果数据，完成态落不到「Read xxx（12 行）」这类具体文案上，只能取通用词。
///
/// 独立成 `nonisolated` 类型是为了可单测：这里原本是 `SubagentToolRow.statusText`
/// 里的一串 if/else，其中「运行中」那一支与 `else`（完成/失败/等待）那一支**逐字
/// 相同**（都取 `ToolStatusDisplay.running(...)`），于是子工具跑完之后整行仍显示
/// 「Running…」。按 `status` 逐档取词后，用例可以钉住「完成 / 失败 / 中断都不是
/// 运行中文案」这条不变量。
nonisolated enum SubagentToolStatusText {
    static func display(
        for status: ToolStatus, name: String, input: [String: String]
    ) -> ToolStatusDisplay {
        switch status {
        case .running:
            return ToolStatusDisplay.running(for: name, input: input)
        case .waitingForApproval:
            return ToolStatusDisplay(
                text: LocalizationManager.t("Waiting for approval..."), isRunning: true)
        case .success:
            return ToolStatusDisplay(text: LocalizationManager.t("Completed"), isRunning: false)
        case .error:
            return ToolStatusDisplay(text: LocalizationManager.t("Failed"), isRunning: false)
        case .interrupted:
            return ToolStatusDisplay(text: LocalizationManager.t("Interrupted"), isRunning: false)
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// 状态文案按 `tool.status` 逐档取词（见 `SubagentToolStatusText`）。
    private var statusText: String {
        SubagentToolStatusText.display(for: tool.status, name: tool.name, input: tool.input).text
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .appFont(10, weight: .medium)
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools)
            Text(statusText)
                .appFont(10)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]
    @ObservedObject private var l10n = LocalizationManager.shared

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.t("Subagent used %lld tools:", tools.count))
                .appFont(10, weight: .medium)
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .appFont(10, design: .monospaced)
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .appFont(9, design: .monospaced)
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}
