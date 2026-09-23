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
    /// 已结束会话的保留档位（变化时重新过滤列表）
    @ObservedObject private var retention = SessionRetentionSelector.shared
    /// 「隐藏闲置会话」开关（行为页）：与设置行共用同一实例，改完立刻重排列表。
    @ObservedObject private var hideIdleSessions = SessionDisplayPreferences.hideIdleSessions

    var body: some View {
        if visibleInstances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    /// 列表里要显示的会话：先按「已结束的会话」档位过滤结束会话，再按「隐藏闲置」过滤空闲会话。
    /// 判据抽在 `SessionVisibility` 里（纯函数，可单测），视图只做映射。
    private var visibleInstances: [SessionState] {
        let now = Date()
        let retention = retention.option
        return sessionMonitor.instances.filter { session in
            SessionVisibility.isVisible(
                phase: session.phase,
                lastActivity: session.lastActivity,
                retention: retention,
                hideIdleSessions: hideIdleSessions.isOn,
                now: now)
        }
    }

    /// 被「隐藏闲置」挡下的会话数：不为零时空态要说清原因，并给出把开关关掉的入口。
    private var hiddenIdleCount: Int {
        guard hideIdleSessions.isOn else { return 0 }
        return max(0, sessionMonitor.instances.count - visibleInstances.count)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            if AgentRegistry.enabled.isEmpty {
                // Agent 默认关闭：此时「没有会话」几乎总是因为一个都没启用，
                // 因此换成能直接走通的那一步，而不是让用户以为应用坏了。
                Text(l10n.t("No agents enabled"))
                    .appFont(13, weight: .medium)
                    .foregroundColor(AppPalette.tertiaryText)

                Text(l10n.t("Turn an agent on in Settings → Agents, or install them all at once."))
                    .appFont(11)
                    .foregroundColor(AppPalette.subtleText)

                Button {
                    viewModel.openAgentsSettings()
                } label: {
                    Text(l10n.t("Open Agents Settings"))
                        .appFont(11, weight: .medium)
                        .foregroundColor(AppPalette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if hiddenIdleCount > 0 {
                // 会话其实还在，只是被「隐藏闲置」挡下了：说明原因 + 一步关掉它。
                Text(l10n.t("All sessions are idle"))
                    .appFont(13, weight: .medium)
                    .foregroundColor(AppPalette.tertiaryText)

                Button {
                    hideIdleSessions.set(false)
                } label: {
                    Text(l10n.t("Show Idle Sessions"))
                        .appFont(11, weight: .medium)
                        .foregroundColor(AppPalette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else {
                Text(l10n.t("No sessions"))
                    .appFont(13, weight: .medium)
                    .foregroundColor(AppPalette.tertiaryText)

                Text(l10n.t("Sessions appear here when you run an agent in a terminal."))
                    .appFont(11)
                    .foregroundColor(AppPalette.subtleText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// 显示顺序：相位优先级 + 最近用户消息。
    /// 口径抽在 `SessionListOrdering`（纯函数，可单测），快捷键按同一顺序导航。
    private var sortedInstances: [SessionState] {
        SessionListOrdering.sorted(visibleInstances)
    }

    private var instancesList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(sortedInstances) { session in
                        InstanceRow(
                            session: session,
                            isCriticalApproval: sessionMonitor.approvalDisplay(
                                for: session.sessionKey)?.isCritical == true,
                            isSelected: viewModel.selectedSessionKey == session.sessionKey,
                            onSelect: { viewModel.selectedSessionKey = session.sessionKey },
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
            // 键盘导航后把选中的那一行滚进视野（居中，不贴边）。
            .onChange(of: viewModel.selectedSessionKey) { _, key in
                guard let key,
                    let session = sortedInstances.first(where: { $0.sessionKey == key })
                else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(session.stableId, anchor: .center)
                }
            }
            // 把当前显示顺序写回视图模型：快捷键按它定位。
            .onAppear { publishVisibleSessions() }
            .onChange(of: sortedInstances.map(\.stableId)) { _, _ in
                publishVisibleSessions()
            }
        }
    }

    /// 写回「当前显示的会话 + 顺序」（比较标识数组，顺序没变就不写）。
    private func publishVisibleSessions() {
        viewModel.updateVisibleSessions(sortedInstances.map(\.sessionKey))
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        Task {
            // 不再要求「先装 yabai」：没有 yabai 时 `TerminalFocuser` 会退到
            // 「激活宿主应用」（tmux 会话先经 tmux 客户端定位终端）。
            let focused = await TerminalFocuser.shared.focus(
                pid: session.pid, workingDirectory: session.cwd)
            guard !focused else { return }

            // 聚焦失败时退回打开对话：点了总要看到反馈，而对话页是这个动作的无损替代——
            // 反过来说，原来的「静默什么都不做」是最差的一种反馈。
            openChat(session)
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
    /// 该会话的待批工具是否命中危险命令档（集成侧判定）；行内据此给出警示。
    let isCriticalApproval: Bool
    /// 是否是键盘选中项（背景高亮）。
    let isSelected: Bool
    /// 点这一行时把选中态同步过来（键盘与鼠标不会各指一行）。
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 列表内容密度与单击动作
    @ObservedObject private var density = SessionRowDensitySelector.shared
    @ObservedObject private var clickAction = SessionRowClickActionSelector.shared

    @State private var isHovered = false
    /// 上一次「双击」被处理的时刻。两个手势同时挂（见 `body` 末尾），
    /// 这里用来在 SwiftUI 把同一次点击也交给单选手势时把重复的那次丢掉。
    @State private var lastDoubleTapAt: Date?

    /// 双击的静默窗口：比系统双击间隔略短，确保同一组点击里第二下一定落在窗口内。
    private static let doubleTapGuard: TimeInterval = 0.35

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// 待批工具是否需要交互式作答（不是批准/拒绝）。工具名按 Agent 驱动：
    /// Claude 是 `AskUserQuestion`，omp/pi 是 `ask`，opencode 无。
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return session.agent.isInteractiveTool(toolName)
    }

    /// 是否在该 Agent 行显示归属角标：只有用户启用了多个 Agent 时才需要区分
    private var showsAgentBadge: Bool {
        AgentRegistry.enabled.count > 1
    }

    /// 能不能把会话所在的终端带到前台：有集成上报的 pid 就能沿进程链找宿主应用，
    /// 只有 tmux 面板（没有 pid）也能靠面板路径找；两者都没有就是「没有线索」。
    private var canFocusTerminal: Bool {
        session.pid != nil || session.isInTmux
    }

    /// 禁用「去终端」时的说明：禁用必须给原因，否则用户只会觉得按钮坏了。
    private var noFocusTargetHint: String {
        l10n.t("This session has no process or tmux pane to focus.")
    }

    /// 单击的落点由档位决定（见 `SessionRowClickAction.singleTapTarget`）。
    private func handleSingleTap() {
    onSelect()
        switch clickAction.option.singleTapTarget(isInTmux: session.isInTmux) {
        case .chat:
            onChat()
        case .terminal:
            onFocus()
        case nil:
            return
        }
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

    /// 活动行：等待审批时显示工具与入参，否则显示最后一条消息；
    /// 「列表信息密度」为紧凑档时整行不画（只留标题）。
    @ViewBuilder
    private var activityLine: some View {
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

                    // Token usage indicator（紧凑档不显示）
                    if density.option.showsTokenUsage && session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .appFont(10, weight: .medium, design: .monospaced)
                            .foregroundColor(AppPalette.subtleText)
                    }
                }

                if density.option.showsActivityLine {
                    activityLine
                }

                // 详细档：再补一行工作目录
                if density.option.showsWorkingDirectory {
                    Text(session.cwd)
                        .appFont(10)
                        .foregroundColor(AppPalette.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && !session.agent.approval.canDecideRemotely {
                // 该 Agent 的审批只能在其自身 CLI 里完成，notch 仅提示
                Text(l10n.t("Waiting for approval in terminal"))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval && isInteractiveTool {
                // 交互式提问（Claude 的 AskUserQuestion / omp 的 ask）：这不是批准或
                // 拒绝，行内给 Allow/Deny 会误导，因此只给「去刘海上作答」的入口。
                HStack(spacing: 8) {
                    AnswerButton(onTap: onChat)

                    // 「去终端」不再依赖 yabai（见 `TerminalFocuser` 的回退链）；
                    // 只有连进程与 tmux 面板都没有的会话（仅凭记录发现的）才禁用。
                    TerminalButton(
                        isEnabled: canFocusTerminal,
                        helpText: canFocusTerminal ? nil : noFocusTargetHint,
                        onTap: { onFocus() }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                HStack(spacing: 6) {
                    if isCriticalApproval {
                        // 危险档用符号表达（同一行左侧的状态图标），不再放一行文字：
                        // 默认面板宽下这行文字会把 Allow / Deny 挤到换行。
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(AppPalette.danger)
                            .help(l10n.t("Dangerous command"))
                            .accessibilityLabel(Text(l10n.t("Dangerous command")))
                    }
                    InlineApprovalButtons(
                        onChat: onChat,
                        onApprove: onApprove,
                        onReject: onReject
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Chat icon - always show
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // 聚焦终端：与「去终端」按钮同一判据（见上）
                    IconButton(icon: "eye") {
                        onFocus()
                    }
                    .disabled(!canFocusTerminal)
                    .help(canFocusTerminal ? l10n.t("Focus Terminal") : noFocusTargetHint)

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
        // 双击**始终**进聊天，单击按「单击动作」档位——两个手势同时挂，不再二选一。
        // 曾经只挂一层（按档位在 count:1 / count:2 之间切），于是设了单击动作的用户永久
        // 失去「双击进聊天」，且双击会连发两次单击动作。
        // SwiftUI 对 `count: 2` 与 `count: 1` 同时存在时的仲裁没有明确契约，所以不赌它：
        // 双击路径记下时刻，单击路径看到刚发生过双击就跳过——无论系统怎么派发，
        // 结果都收敛到「双击只进聊天」，而单击仍即时响应（不被双击等待窗口拖慢）。
        .onTapGesture(count: 2) {
            lastDoubleTapAt = Date()
            onSelect()
            onChat()
        }
        .onTapGesture(count: 1) {
            if let last = lastDoubleTapAt, Date().timeIntervalSince(last) < Self.doubleTapGuard {
                return
            }
            handleSingleTap()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.panel)
                .fill(
                    isSelected
                        ? AppPalette.segmentedThumb
                        : (isHovered ? AppPalette.rowHover : Color.clear))
        )
        .onHover { isHovered = $0 }
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
            phaseGlyph(
                "exclamationmark.circle.fill",
                color: isCriticalApproval ? AppPalette.danger : AppPalette.warning)
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
                    .lineLimit(1)
                    .fixedSize()
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
                    .lineLimit(1)
                    .fixedSize()
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

// MARK: - 作答入口按钮

/// 「去刘海上作答」入口：交互式提问待批时替代 Allow/Deny——那两个按钮对提问
/// 不成立（点了也答不了题），而提问的选项在对话页里。
struct AnswerButton: View {
    let onTap: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "questionmark.bubble")
                    .appFont(9, weight: .medium)
                Text(l10n.t("Answer"))
                    .appFont(11, weight: .medium)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.95))
            .clipShape(Capsule())
        }
        .buttonStyle(SessionPressFeedbackStyle(shape: Capsule()))
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    /// 禁用时的原因（tooltip）；可用时传 nil。
    var helpText: String? = nil
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
        .help(helpText ?? l10n.t("Focus Terminal"))
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