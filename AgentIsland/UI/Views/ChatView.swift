//
//  ChatView.swift
//  AgentIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI

struct ChatView: View {
    let key: SessionKey
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var inputText: String = ""
    /// 发送失败时的行内提示（不弹窗）：非空时显示在输入框上方
    @State private var sendErrorMessage: String? = nil
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    /// 跟随到底的状态机（暂停 / 攒下的新消息数 / 基线）：判据与计数都在 `ChatScrollState`。
    @State private var scroll = ChatScrollState()
    @State private var isBottomVisible: Bool = true

    private var isAutoscrollPaused: Bool { scroll.isPaused }
    private var newMessageCount: Int { scroll.newMessageCount }
    @State private var approvalDisplay: PendingApprovalDisplay?
    /// 待批工具若是 `ask`（交互式提问），这里持有它的问题集。
    @State private var pendingAsk: AskPayload?
    @FocusState private var isInputFocused: Bool
    /// 系统的「减弱动态效果」偏好：本切片动的弹性动效一律经 `AppMotion` 换曲线
    /// （见 `AppMotion.pick`）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        key: SessionKey, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor,
        viewModel: NotchViewModel
    ) {
        self.key = key
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // 首帧直接用当前会话的条目（防止视图重建时闪一下加载态）
        let cachedHistory = ChatHistoryProjection.items(for: initialSession)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// 把新的条目列表接进视图状态：变化判据、暂停自动滚动时的新消息计数与自动滚动
    /// 都只在这里判一次（原先散在 `$histories` 的订阅闭包里）。
    private func applyHistory(_ newHistory: [ChatHistoryItem]) {
        guard newHistory != history else { return }

        // 「要不要滚到底」与暂停期间的计数都在 `ChatScrollState`（纯值，有单测）。
        let shouldFollow = scroll.noteHistoryChanged(from: history, to: newHistory)
        history = newHistory

        if shouldFollow {
            shouldScrollToBottom = true
        }

        // If we have data, skip loading state (handles view recreation)
        if isLoading && !newHistory.isEmpty {
            isLoading = false
        }
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    /// 待作答的 `ask` 问题集。非空时作答卡独占对话区（历史列表与底部条都让位）。
    /// 三个条件缺一不可：待批工具是交互式提问、信封确实带了 `ask` 载荷、该 Agent
    /// 的决定能回传（否则卡片给不出可用入口，退回「去终端作答」）。
    private var activeAsk: AskPayload? {
        guard let tool = approvalTool,
            key.agent.isInteractiveTool(tool),
            key.agent.approval.canDecideRemotely,
            let ask = pendingAsk
        else { return nil }
        return ask
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // 待作答：作答卡独占整个对话区，历史列表让位。
                if let ask = activeAsk {
                    askCard(ask)
                } else if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                // 底部条：作答卡占据对话区时整条不渲染——卡片本身已经是整个面，
                // 再画一条会变成同一张卡出现两次。
                if activeAsk == nil {
                    bottomBar
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // 这两处赋值只是兜底：条目真正的来源是 `sessionMonitor.$instances` 的发布。若发布
            // 已经先到（读记录那一跳是异步的），`history` 就是新的，不能被这份可能更旧的
            // `session` 覆盖回去。
            if ChatHistoryManager.shared.isLoaded(key: key) {
                if history.isEmpty {
                    history = ChatHistoryProjection.items(for: session)
                }
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(key: key, cwd: session.cwd)
            if history.isEmpty {
                history = ChatHistoryProjection.items(for: session)
            }

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            // 会话消失（/clear 或回收）：对话页跟着退回去。原先这条判据挂在第二个发布通道上，
            // 现在条目与会话状态来自同一次发布，两条分支只在这里各写一次。
            guard let updated = sessions.first(where: { $0.sessionKey == key }) else {
                if hasLoadedOnce {
                    viewModel.exitChat()
                }
                return
            }

            // 条目：投影规则在 `ChatHistoryProjection`（子 Agent 内部工具已折叠进容器卡片）。
            applyHistory(ChatHistoryProjection.items(for: updated))

            // 展示档位随 pending 生命周期刷新：每次会话发布都重查一次，否则「同会话补发了
            // 让位信号但 SessionState 没变」时卡片不会更新。等值不写：@State 赋值会唤醒视图，
            // 而这类发布在流式输出时每秒好几次。
            let isWaiting = updated.phase.isWaitingForApproval
            let nextDisplay = isWaiting ? sessionMonitor.approvalDisplay(for: key) : nil
            if approvalDisplay != nextDisplay {
                approvalDisplay = nextDisplay
            }
            let nextAsk = isWaiting ? sessionMonitor.pendingAsk(for: key) : nil
            if pendingAsk != nextAsk {
                pendingAsk = nextAsk
            }

            if updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false
    @State private var isInterruptHovered = false
    /// 中断请求在途：拦住连点，免得同一个 pane 连收两次 Ctrl-C。
    @State private var isInterrupting = false

    private var chatHeader: some View {
        HStack(spacing: 4) {
            exitButton
            interruptButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24)  // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1)  // Render above message list
    }

    /// 返回按钮：占满头部里除中断按钮之外的整行，点任意处退出对话。
    private var exitButton: some View {
        Button {
            viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .appFont(14, weight: .semibold)
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                Text(session.displayTitle)
                    .appFont(14, weight: .semibold)
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                    .lineLimit(1)

                // 多 Agent 时标注当前会话归属；单 Agent 用户保持原样
                if AgentRegistry.enabled.count > 1 {
                    AgentBadge(agent: session.agent)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
    }

    /// 中断按钮：给跑偏的 Agent 补上一次 Ctrl-C（此前全仓没有中断入口，只能干等）。
    /// 可用条件与「发送消息」同源（`canSendMessages`：会话在 tmux 且拿得到 tty）——
    /// 两者走的是同一条路（`SessionMessageRouter`）：先按 tty 解析出 pane，退到 Paseo 终端。
    /// 不可用时按钮仍在（用户看得到它存在），只是置灰。
    private var interruptButton: some View {
        Button {
            interruptSession()
        } label: {
            Image(systemName: "stop.circle")
                .appFont(13)
                .foregroundColor(
                    canSendMessages
                        ? .white.opacity(isInterruptHovered ? 1.0 : 0.6) : .white.opacity(0.2)
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSendMessages || isInterrupting)
        .onHover { isInterruptHovered = $0 }
        .help(l10n.t("Send Ctrl-C to this session"))
        .accessibilityLabel(Text(l10n.t("Interrupt")))
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text(l10n.t("Loading messages..."))
                .appFont(13, weight: .medium)
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .appFont(24)
                .foregroundColor(.white.opacity(0.2))
            Text(l10n.t("No messages yet"))
                .appFont(13, weight: .medium)
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId, agent: session.agent)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.95))
                                        .combined(with: .offset(y: -4)),
                                    removal: .opacity
                                ))
                    }

                    ForEach(history.reversed()) { item in
                        MessageItemView(
                            item: item, agentDescriptions: session.subagentState.agentDescriptions
                        )
                        .padding(.horizontal, 16)
                        .scaleEffect(x: 1, y: -1)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            // 对话面整体可选中、可复制：此前全仓没有 textSelection，用户看到 agent 给出的
            // 命令/路径/结论只能手抄。落在**列表容器**上（不是每个 `Text` 各来一遍），
            // 消息正文、工具入参/输出、Thinking 文本一并覆盖。
            .textSelection(.enabled)
            // 右键此前在对话面是死手势：整条转录既没有菜单、也拿不走。这里给「复制整段
            // 对话」一个入口；拖选某一段仍走系统自己的复制（`textSelection` 已开）。
            .contextMenu {
                Button {
                    CopyAction.write(transcriptText)
                } label: {
                    Text(l10n.t("Copy"))
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // 回到最新的入口：判据只看 `isAutoscrollPaused`。
            // 此前这里是 `isAutoscrollPaused && newMessageCount > 0`——用户上翻回看、期间恰好
            // 没有新消息时，这枚胶囊根本不出现，视口卡在半空、没有任何回到底部的入口。
            // 没有新消息时退化成只有箭头的形态（见 `LatestJumpIndicator`）。
            .overlay(alignment: .bottom) {
                switch LatestJumpIndicator.resolve(
                    isAutoscrollPaused: isAutoscrollPaused, newMessageCount: newMessageCount)
                {
                case .hidden:
                    EmptyView()
                case .chevronOnly, .count:
                    NewMessagesIndicator(count: newMessageCount, color: session.agent.brandColor) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                }
            }
            .animation(
                AppMotion.pick(
                    .spring(response: 0.35, dampingFraction: 0.85), reduceMotion: reduceMotion),
                value: isAutoscrollPaused
            )
        }
    }

    // MARK: - Transcript

    /// 转录的纯文本形式：右键「复制」拿走的整段对话。
    ///
    /// 只收对话本身（用户 / 助手 / 思考），不收工具调用与图片——它们的载荷动辄几千字、
    /// 多是过程噪音，要单独拿走某一块的原文，用块内自己的复制入口。
    /// 顺序就是 `history` 的时间序（首条最早、末条最新）。
    private var transcriptText: String {
        history.compactMap { item -> String? in
            switch item.type {
            case .user(let text):
                return l10n.t("You:") + " " + text
            case .assistant(let text):
                return text
            case .thinking(let text):
                return text
            case .toolCall, .image, .interrupted:
                return nil
            }
        }
        .joined(separator: "\n\n")
    }

    // MARK: - Input Bar

    /// 能否往该会话写东西：tmux（原有通道）或 Paseo 托管终端（`PASEO_TERMINAL_ID`）。
    /// 输入框是否可用：与发送/中断共用同一份通道判据（`ChatSendRoute`）。
    private var canSendMessages: Bool {
        sendRoute.isAvailable
    }

    private var sendRoute: ChatSendRoute {
        ChatSendRoute(session: session)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(
                canSendMessages
                    ? l10n.t("Message %@...", key.agent.shortName)
                    : l10n.t("Open %@ in tmux to enable messaging", key.agent.displayName),
                text: $inputText
            )
            .textFieldStyle(.plain)
            .appFont(13)
            .foregroundColor(canSendMessages ? .white : .white.opacity(0.4))
            .focused($isInputFocused)
            .disabled(!canSendMessages)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .onSubmit {
                sendMessage()
            }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .appFont(28)
                    .foregroundColor(
                        !canSendMessages || inputText.isEmpty
                            ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24)  // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1)  // Render above message list
    }

    /// 底部条：待批卡片 / 交互式提示 / 输入框。作答卡占据对话区时整条不渲染。
    @ViewBuilder
    private var bottomBar: some View {
        if let tool = approvalTool {
            if key.agent.isInteractiveTool(tool) {
                // 交互式提问不是批准/拒绝：信封带 `ask` 且决定能回传时，问题已经在
                // 对话区作答（见 `activeAsk`），这里只剩两种兜底——载荷缺失（Claude 的
                // AskUserQuestion 只走 hook、不带 ask）或该 Agent 无法远程决定——都退回
                // 「去终端作答」，免得给出误导性的 Allow/Deny。
                interactivePromptBar
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
            } else {
                approvalBar(tool: tool)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
            }
        } else {
            VStack(spacing: 0) {
                if let sendErrorMessage {
                    SettingsNotice(message: sendErrorMessage)
                        .padding(.top, 8)
                }

                inputBar
            }
            .transition(.opacity)
        }
    }

    // MARK: - Approval Bar

    /// 作答卡：独占对话区（撑满头部以下），选项、自由文本与提交/跳过都在刘海上完成。
    private func askCard(_ ask: AskPayload) -> some View {
        ApprovalAskView(
            ask: ask,
            onSubmit: { answerPermission($0) },
            onSkip: { denyPermission() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    /// 审批条取 `activePermission` 的**详情**形态（完整路径 / 整条命令）与原始入参 JSON，
    /// 不是列表行用的紧凑摘要：看清要授权的东西是这一步的全部意义
    /// （见 `PermissionContext.detailedInput`）。
    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            detail: session.activePermission?.detailedInput,
            rawInput: session.activePermission?.rawInputJSON,
            display: approvalDisplay,
            onApprove: { approvePermission() },
            onDeny: { denyPermission() }
        )
    }

    // MARK: - Interactive Prompt Bar

    /// Bar for interactive tools like AskUserQuestion that need terminal input
    private var interactivePromptBar: some View {
        ChatInteractivePromptBar(
            agent: key.agent,
            isInTmux: session.isInTmux,
            onGoToTerminal: { focusTerminal() }
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        scroll.pause(atCount: history.count)
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        scroll.resume(atCount: history.count)
    }

    // MARK: - Actions

    private func focusTerminal() {
        Task {
            // 与列表行同一入口：yabai 优先，没有 yabai 时退到「激活宿主应用」。
            _ = await TerminalFocuser.shared.focus(pid: session.pid, workingDirectory: session.cwd)
        }
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(key: key)
    }

    /// 在刘海上作答：由会话监视器折成回传决定（空答案按放弃处理）。
    private func answerPermission(_ answers: [String: [String]]) {
        sessionMonitor.answerPermission(key: key, answers: answers)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(key: key, reason: nil)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        sendErrorMessage = nil

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
        Task {
            guard await sendToSession(text) else {
                // 发送失败：把内容放回输入框（用户已重新输入则不覆盖），并在输入框上方说明原因。
                // 这一条不进 history——history 只由记录同步喂入，所以不会重复出现。
                if inputText.isEmpty {
                    inputText = text
                }
                isInputFocused = true
                sendErrorMessage = l10n.t("Couldn't send to the terminal")
                return
            }
        }
    }

    /// 会话写入通道：通道依据在这里解析一次（输入框可否用的判据也读同一份 `sendRoute`），
    /// 「① tmux ② Paseo」的回退顺序收在 `SessionMessageRouter` 里。
    private var messageRouter: SessionMessageRouter {
        SessionMessageRouter(route: sendRoute, paseoCliPath: session.paseoCliPath)
    }

    /// 把一条消息送进该会话所在的终端，返回是否真的送达。
    /// 以前这个返回值被丢弃：「找不到 pane / tmux 路径不可用 / 发送失败」在界面上完全一样，
    /// 用户看到的是消息凭空消失。
    private func sendToSession(_ text: String) async -> Bool {
        await messageRouter.send(text)
    }

    /// 中断当前会话：先按 tmux pane 发 Ctrl-C，退到 Paseo 托管终端。
    /// 两条通道与「发送消息」同源（都由 `SessionMessageRouter` 决定），
    /// 因此可用条件也一致（`canSendMessages`）。
    private func interruptSession() {
        guard canSendMessages, !isInterrupting else { return }
        sendErrorMessage = nil
        isInterrupting = true

        Task {
            defer { isInterrupting = false }

            if await messageRouter.interrupt() { return }

            // 与发送消息共用同一处提示位：找不到 pane / 终端 / 写不进去都在这里说，
            // 不再出现「点了没反应」。
            sendErrorMessage = l10n.t("Couldn't send to the terminal")
        }
    }
}

// MARK: - Autoscroll Judgement

/// 「要不要把视口重新锚到底部」的判据。
///
/// 单独抽成 `nonisolated` 纯函数是为了可单测：这条判据此前只看条目数变化，于是
/// **流式回复**（条目数不变、最后一条正文一直在长）在视口里会一点点漂走。
nonisolated enum MessageAutoscroll {
    /// - Parameters:
    ///   - countChanged: 条目数变了（新消息进来）。
    ///   - lastItemContentChanged: 末条正文变了（正在流式输出）。
    static func shouldFollow(
        isAutoscrollPaused: Bool, countChanged: Bool, lastItemContentChanged: Bool
    ) -> Bool {
        guard !isAutoscrollPaused else { return false }
        return countChanged || lastItemContentChanged
    }
}

/// 「回到最新」入口的形态。
///
/// 判据只看 `isAutoscrollPaused`：上翻回看本身就该有一个回得去的入口，不能只在
/// 恰好来了新消息时才出现。
nonisolated enum LatestJumpIndicator: Equatable {
    /// 停在底部：不需要入口。
    case hidden
    /// 上翻且没有新消息：只剩一枚箭头。
    case chevronOnly
    /// 上翻且有新消息：箭头 + 条数。
    case count(Int)

    static func resolve(isAutoscrollPaused: Bool, newMessageCount: Int) -> LatestJumpIndicator {
        guard isAutoscrollPaused else { return .hidden }
        return newMessageCount > 0 ? .count(newMessageCount) : .chevronOnly
    }
}
