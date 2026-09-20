//
//  ClaudeInstancesView.swift
//  AgentIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(l10n.t("No sessions"))
                .appFont(13, weight: .medium)
                .foregroundColor(AppPalette.tertiaryText)

            Text(l10n.t("Sessions appear here when you run an agent in a terminal."))
                .appFont(11)
                .foregroundColor(AppPalette.subtleText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(sortedInstances) { session in
                    InstanceRow(
                        session: session,
                        onFocus: { focusSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
                        onReject: { rejectSession(session) }
                    )
                    .id(session.stableId)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        guard session.isInTmux else { return }

        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(key: session.sessionKey)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(key: session.sessionKey, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(key: session.sessionKey)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isHovered = false
    @State private var isYabaiAvailable = false

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// 是否在该 Agent 行显示归属角标：只有用户启用了多个 Agent 时才需要区分
    private var showsAgentBadge: Bool {
        AgentRegistry.enabled.count > 1
    }

    /// Status text based on session phase (fallback when no other content)
    private var phaseStatusText: String {
        switch session.phase {
        case .processing:
            return l10n.t("Processing...")
        case .compacting:
            return l10n.t("Compacting...")
        case .waitingForInput:
            return l10n.t("Ready")
        case .waitingForApproval:
            return l10n.t("Waiting for approval")
        case .idle:
            return l10n.t("Idle")
        case .ended:
            return l10n.t("Ended")
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 行首状态指示：形状区分相位，颜色只表状态
            stateIndicator
                .accessibilityLabel(phaseStatusText)
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .appFont(13, weight: .medium)
                        .foregroundColor(AppPalette.primaryText)
                        .lineLimit(1)

                    // 多 Agent 时标注会话归属；单 Agent 用户保持原样
                    if showsAgentBadge {
                        AgentBadge(agent: session.agent)
                    }

                    // Token usage indicator
                    if session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .appFont(10, weight: .medium, design: .monospaced)
                            .foregroundColor(AppPalette.subtleText)
                    }
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .appFont(11, weight: .medium, design: .monospaced)
                            .foregroundColor(AppPalette.warning)
                        if isInteractiveTool {
                            Text(l10n.t("Needs your input"))
                                .appFont(11)
                                .foregroundColor(AppPalette.secondaryText)
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .appFont(11)
                                .foregroundColor(AppPalette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .appFont(11, weight: .medium, design: .monospaced)
                                    .foregroundColor(AppPalette.secondaryText)
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .appFont(11)
                                    .foregroundColor(AppPalette.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text(l10n.t("You:"))
                                .appFont(11, weight: .medium)
                                .foregroundColor(AppPalette.secondaryText)
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .appFont(11)
                                    .foregroundColor(AppPalette.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .appFont(11)
                                .foregroundColor(AppPalette.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .appFont(11)
                        .foregroundColor(AppPalette.tertiaryText)
                        .lineLimit(1)
                } else {
                    // Fallback: show phase-based status when no other content
                    Text(phaseStatusText)
                        .appFont(11)
                        .foregroundColor(AppPalette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && !session.agent.supportsPermissionControl {
                // 该 Agent 的审批只能在其自身 CLI 里完成，notch 仅提示
                Text(l10n.t("Waiting for approval in terminal"))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show chat + terminal buttons
                HStack(spacing: 8) {
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Go to Terminal button (only if yabai available)
                    if isYabaiAvailable {
                        TerminalButton(
                            isEnabled: session.isInTmux,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Chat icon - always show
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Focus icon (only for tmux instances with yabai)
                    if session.isInTmux && isYabaiAvailable {
                        IconButton(icon: "eye") {
                            onFocus()
                        }
                    }

                    // Archive button - only for idle or completed sessions
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.panel)
                .fill(isHovered ? AppPalette.rowHover : Color.clear)
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    /// 行首状态指示：**形状**区分相位、颜色只表状态（`AppPalette.warning` 需要授权、
    /// `AppPalette.success` 等待输入、其余相位用 `AppPalette.subtleText`）。处理中沿用
    /// 该 Agent 自己的转轮动效，与关闭态标记同源，相位不再靠色相区分。
    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            AgentSpinner(agent: session.agent)
        case .waitingForApproval:
            phaseGlyph("exclamationmark.circle.fill", color: AppPalette.warning)
        case .waitingForInput:
            phaseGlyph("checkmark.circle.fill", color: AppPalette.success)
        case .idle:
            phaseGlyph("circle.dashed", color: AppPalette.subtleText)
        case .ended:
            phaseGlyph("minus.circle", color: AppPalette.subtleText)
        }
    }

    /// 相位符号：占位宽度与转轮一致，行首列宽不随相位跳动。
    private func phaseGlyph(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .appFont(11, weight: .medium)
            .foregroundColor(color)
            .frame(width: 12)
    }
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text(l10n.t("Deny"))
                    .appFont(11, weight: .medium)
                    .foregroundColor(AppPalette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(SessionPressFeedbackStyle(shape: Capsule()))
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text(l10n.t("Allow"))
                    .appFont(11, weight: .medium)
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(SessionPressFeedbackStyle(shape: Capsule()))
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .appFont(11, weight: .medium)
                .foregroundColor(isHovered ? AppPalette.primaryText : AppPalette.tertiaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control)
                        .fill(isHovered ? AppPalette.rowHover : Color.clear)
                )
        }
        .buttonStyle(SessionPressFeedbackStyle(shape: RoundedRectangle(cornerRadius: AppRadius.control)))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .appFont(8, weight: .medium)
                Text(l10n.t("Go to Terminal"))
                    .appFont(10, weight: .medium)
            }
            .foregroundColor(isEnabled ? AppPalette.primaryText : AppPalette.subtleText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(SessionPressFeedbackStyle(shape: Capsule()))
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .appFont(9, weight: .medium)
                Text(l10n.t("Terminal"))
                    .appFont(11, weight: .medium)
            }
            .foregroundColor(isEnabled ? .black : AppPalette.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(SessionPressFeedbackStyle(shape: Capsule()))
    }
}


// MARK: - 按压反馈

/// 行内控件的按压反馈：按控件自身的形状叠一层 `AppPalette.rowPressed`，不做位移——
/// 与设置面板的行按压（`SettingsRowButtonStyle`）同一口径，区别只是按压层跟随控件
/// 形状，圆角控件按下时不会露出直角。
private struct SessionPressFeedbackStyle<S: Shape>: ButtonStyle {
    /// 控件自身的形状（图标按钮用 `AppRadius.control` 圆角，胶囊按钮用 `Capsule`）。
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(configuration.isPressed ? AppPalette.rowPressed : Color.clear))
    }
}