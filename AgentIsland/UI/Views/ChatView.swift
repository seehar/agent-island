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
 @State private var isAutoscrollPaused: Bool = false
 @State private var newMessageCount: Int = 0
 @State private var previousHistoryCount: Int = 0
 @State private var isBottomVisible: Bool = true
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

  // Initialize from cache if available (prevents loading flicker on view recreation)
  let cachedHistory = ChatHistoryManager.shared.history(for: key)
  let alreadyLoaded = !cachedHistory.isEmpty
  self._history = State(initialValue: cachedHistory)
  self._isLoading = State(initialValue: !alreadyLoaded)
  self._hasLoadedOnce = State(initialValue: alreadyLoaded)
 }

 /// Whether we're waiting for approval
 private var isWaitingForApproval: Bool {
  session.phase.isWaitingForApproval
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

   // Check if already loaded (from previous visit)
   if ChatHistoryManager.shared.isLoaded(key: key) {
    history = ChatHistoryManager.shared.history(for: key)
    isLoading = false
    return
   }

   // Load in background, show loading state
   await ChatHistoryManager.shared.loadFromFile(key: key, cwd: session.cwd)
   history = ChatHistoryManager.shared.history(for: key)

   withAnimation(.easeOut(duration: 0.2)) {
    isLoading = false
   }
  }
  .onReceive(ChatHistoryManager.shared.$histories) { histories in
   // Update when count changes, last item differs, or content changes (e.g., tool status)
   if let newHistory = histories[key] {
    let countChanged = newHistory.count != history.count
    let lastItemChanged = newHistory.last?.id != history.last?.id
    // 流式回复期间条目数不变、只有最后一条的正文在长大：那也算「尾部在动」。
    // 少了这条判据，正在输出的答案会在视口里一点点漂走（用户得手动往下追）。
    let lastItemContentChanged =
     newHistory.last?.id == history.last?.id && newHistory.last != history.last
    // Always update - the @Published ensures we only get notified on real changes
    // This allows tool status updates (waitingForApproval -> running) to reflect
    if countChanged || lastItemChanged || newHistory != history {
     // Track new messages when autoscroll is paused
     if isAutoscrollPaused && newHistory.count > previousHistoryCount {
      let addedCount = newHistory.count - previousHistoryCount
      newMessageCount += addedCount
      previousHistoryCount = newHistory.count
     }

     history = newHistory

     // Auto-scroll to bottom only if autoscroll is NOT paused
     if MessageAutoscroll.shouldFollow(
      isAutoscrollPaused: isAutoscrollPaused,
      countChanged: countChanged,
      lastItemContentChanged: lastItemContentChanged)
     {
      shouldScrollToBottom = true
     }

     // If we have data, skip loading state (handles view recreation)
     if isLoading && !newHistory.isEmpty {
      isLoading = false
     }
    }
   } else if hasLoadedOnce {
    // Session was loaded but is now gone (removed via /clear) - navigate back
    viewModel.exitChat()
   }
  }
  .onReceive(sessionMonitor.$instances) { sessions in
   // 展示档位随 pending 生命周期刷新：每次会话发布都重查一次，否则「同会话补发了
   // 让位信号但 SessionState 没变」时卡片不会更新。
   let isWaiting =
    sessions.first(where: { $0.sessionKey == key })?.phase.isWaitingForApproval == true
   approvalDisplay = isWaiting ? sessionMonitor.approvalDisplay(for: key) : nil
   pendingAsk = isWaiting ? sessionMonitor.pendingAsk(for: key) : nil
   if let updated = sessions.first(where: { $0.sessionKey == key }),
    updated != session
   {
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
 /// 两者走的是同一条路，先按 tty 解析出 pane，再交给 `ToolApprovalHandler`。
 /// 不可用时按钮仍在（用户看得到它存在），只是置灰。
 private var interruptButton: some View {
  Button {
   interruptSession()
  } label: {
   Image(systemName: "stop.circle")
    .appFont(13)
    .foregroundColor(
     canSendMessages ? .white.opacity(isInterruptHovered ? 1.0 : 0.6) : .white.opacity(0.2)
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
         insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
         removal: .opacity
        ))
     }

     ForEach(history.reversed()) { item in
      MessageItemView(item: item, key: key)
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
 private var canSendMessages: Bool {
  (session.isInTmux && session.tty != nil) || session.paseoTerminalId != nil
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
      !canSendMessages || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
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
  isAutoscrollPaused = true
  previousHistoryCount = history.count
 }

 /// Resume autoscroll and reset new message count
 private func resumeAutoscroll() {
  isAutoscrollPaused = false
  newMessageCount = 0
  previousHistoryCount = history.count
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

 /// 把一条消息送进该会话所在的终端，返回是否真的送达：
 /// ① tmux（原有通道，pane 级更精确）② Paseo 托管终端（`paseo terminal send-keys`）。
 /// 以前这个返回值被丢弃：「找不到 pane / tmux 路径不可用 / 发送失败」在界面上完全一样，
 /// 用户看到的是消息凭空消失。
 private func sendToSession(_ text: String) async -> Bool {
  if session.isInTmux, let tty = session.tty,
   let target = await findTmuxTarget(tty: tty),
   await ToolApprovalHandler.shared.sendMessage(text, to: target)
  {
   return true
  }

  if let terminalId = session.paseoTerminalId {
   return await PaseoCli.shared.sendMessage(
    text, toTerminal: terminalId, cliPath: session.paseoCliPath)
  }

  return false
 }

 private func findTmuxTarget(tty: String) async -> TmuxTarget? {
  guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
   return nil
  }

  do {
   let output = try await ProcessExecutor.shared.run(
    tmuxPath,
    arguments: [
     "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}",
    ]
   )

   let lines = output.components(separatedBy: "\n")
   for line in lines {
    let parts = line.components(separatedBy: " ")
    guard parts.count >= 2 else { continue }

    let target = parts[0]
    let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

    if paneTty == tty {
     return TmuxTarget(from: target)
    }
   }
  } catch {
   return nil
  }

  return nil
 }

 /// 中断当前会话：先按 tmux pane 发 Ctrl-C，退到 Paseo 托管终端。
 /// 两条通道与「发送消息」同源（都不自解析 pane、不直接跑 tmux 命令），
 /// 因此可用条件也一致（`canSendMessages`）。
 private func interruptSession() {
  guard canSendMessages, !isInterrupting else { return }
  sendErrorMessage = nil
  isInterrupting = true

  Task {
   defer { isInterrupting = false }

   if session.isInTmux, let tty = session.tty,
    let target = await findTmuxTarget(tty: tty),
    await ToolApprovalHandler.shared.sendInterrupt(to: target)
   {
    return
   }

   if let terminalId = session.paseoTerminalId,
    await PaseoCli.shared.sendInterrupt(
     toTerminal: terminalId, cliPath: session.paseoCliPath)
   {
    return
   }

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

// MARK: - Message Item View

struct MessageItemView: View {
 let item: ChatHistoryItem
 let key: SessionKey

 var body: some View {
  switch item.type {
  case .user(let text):
   UserMessageView(text: text)
  case .assistant(let text):
   AssistantMessageView(text: text)
  case .toolCall(let tool):
   ToolCallView(tool: tool, key: key)
  case .thinking(let text):
   ThinkingView(text: text)
  case .image(let block):
   ImageMessageView(image: block)
  case .interrupted:
   InterruptedMessageView()
  }
 }
}

// MARK: - Image Message

struct ImageMessageView: View {
 let image: ImageBlock
 @ObservedObject private var l10n = LocalizationManager.shared

 /// Decoded image cached so base64 isn't re-decoded on every render.
 /// Large inline images (tens of KB) would otherwise thrash during
 /// scrolling or parent re-renders.
 @State private var decoded: NSImage?

 var body: some View {
  HStack {
   Spacer(minLength: 60)

   if let decoded {
    Image(nsImage: decoded)
     .resizable()
     .aspectRatio(contentMode: .fit)
     .frame(maxWidth: 280, maxHeight: 280)
     .clipShape(RoundedRectangle(cornerRadius: 12))
     .overlay(
      RoundedRectangle(cornerRadius: 12)
       .stroke(Color.white.opacity(0.1), lineWidth: 1)
     )
   } else {
    // Decode failed — show a labelled placeholder rather than silently dropping
    HStack(spacing: 6) {
     Image(systemName: "photo")
      .appFont(12)
     Text(l10n.t("Image (%@)", image.mediaType))
      .appFont(12)
    }
    .foregroundColor(.white.opacity(0.5))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
     RoundedRectangle(cornerRadius: 8)
      .fill(Color.white.opacity(0.08))
    )
   }
  }
  .task(id: image.id) {
   // Decode off the main thread so large images don't hitch scrolling.
   let b64 = image.base64Data
   let decoded = await Task.detached(priority: .userInitiated) {
    guard let data = Data(base64Encoded: b64) else { return nil as NSImage? }
    return NSImage(data: data)
   }.value
   self.decoded = decoded
  }
 }
}

// MARK: - User Message

struct UserMessageView: View {
 let text: String

 var body: some View {
  HStack {
   Spacer(minLength: 60)

   MarkdownText(text, color: .white, fontSize: 13)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
     RoundedRectangle(cornerRadius: 18)
      .fill(Color.white.opacity(0.15))
    )
  }
 }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
 let text: String

 var body: some View {
  // Skip rendering when text is empty — otherwise the dot indicator
  // shows up alone (orphan dot) for tool-only assistant turns.
  if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
   EmptyView()
  } else {
   HStack(alignment: .top, spacing: 6) {
    // White dot indicator
    Circle()
     .fill(Color.white.opacity(0.6))
     .frame(width: 6, height: 6)
     .padding(.top, 5)

    MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

    Spacer(minLength: 60)
   }
  }
 }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
 @ObservedObject private var l10n = LocalizationManager.shared
 /// 转轮帧表与强调色都归属当前会话的 Agent
 let agent: AgentKind

 /// 文案配色取该 Agent 的品牌色
 private var color: Color { agent.brandColor }

 /// 每种语言的候选文案数量，init 与 baseText 必须一致。
 private static let variantCount = 2
 private let textIndex: Int

 @State private var dotCount: Int = 1
 private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

 /// 用 turnId 为同一轮对话稳定地挑选文案
 init(turnId: String = "", agent: AgentKind) {
  self.agent = agent
  // 取哈希绝对值再取模（magnitude 避免 abs(Int.min) 溢出崩溃）
  textIndex = Int(turnId.hashValue.magnitude % UInt(Self.variantCount))
 }

 /// 基础文案在每次渲染时解析，以便跟随语言切换
 private var baseText: String {
  textIndex == 0 ? l10n.t("Processing") : l10n.t("Working")
 }

 private var dots: String {
  String(repeating: ".", count: dotCount)
 }

 var body: some View {
  HStack(alignment: .center, spacing: 6) {
   AgentSpinner(agent: agent)
    .frame(width: 6)

   Text(baseText + dots)
    .appFont(13)
    .foregroundColor(color)

   Spacer()
  }
  .onReceive(timer) { _ in
   dotCount = (dotCount % 3) + 1
  }
 }
}

// MARK: - Tool Call View

struct ToolCallView: View {
 let tool: ToolCallItem
 let key: SessionKey
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
  !tool.presentsAsSubagentContainer && !GenericToolResultBuilder.isEditLike(tool.name) && hasResult
 }

 private var showContent: Bool {
  GenericToolResultBuilder.isEditLike(tool.name) || isExpanded
 }

 private var agentDescription: String? {
  guard tool.name == "AgentOutputTool",
   let agentId = tool.input["agentId"],
   let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[key]
  else {
   return nil
  }
  return sessionDescriptions[agentId]
 }

 var body: some View {
  VStack(alignment: .leading, spacing: 4) {
   HStack(spacing: 6) {
    Circle()
     .fill(
      statusColor.opacity(
       tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6)
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

// MARK: - Thinking View

struct ThinkingView: View {
 let text: String

 @State private var isExpanded = false

 private var canExpand: Bool {
  text.count > 80
 }

 var body: some View {
  // Skip rendering when text is empty — streaming thinking blocks can
  // briefly arrive empty, which otherwise leaves an orphan grey dot.
  if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
   EmptyView()
  } else {
   HStack(alignment: .top, spacing: 6) {
    Circle()
     .fill(Color.gray.opacity(0.5))
     .frame(width: 6, height: 6)
     .padding(.top, 4)

    Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
     .italic()
     .appFont(11)
     .foregroundColor(.gray)
     .lineLimit(isExpanded ? nil : 1)
     .multilineTextAlignment(.leading)

    Spacer()

    if canExpand {
     Image(systemName: "chevron.right")
      .appFont(9, weight: .medium)
      .foregroundColor(.gray.opacity(0.5))
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .padding(.top, 3)
    }
   }
   .contentShape(Rectangle())
   .onTapGesture {
    if canExpand {
     withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
      isExpanded.toggle()
     }
    }
   }
   .frame(maxWidth: .infinity, alignment: .leading)
   .padding(.vertical, 2)
  }
 }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
 @ObservedObject private var l10n = LocalizationManager.shared
 var body: some View {
  HStack {
   Text(l10n.t("Interrupted"))
    .appFont(13)
    .foregroundColor(.red)
   Spacer()
  }
 }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
 let agent: AgentKind
 let isInTmux: Bool
 let onGoToTerminal: () -> Void
 @ObservedObject private var l10n = LocalizationManager.shared

 @State private var showContent = false
 @State private var showButton = false

 var body: some View {
  HStack(spacing: 12) {
   // Tool info - same style as approval bar
   VStack(alignment: .leading, spacing: 2) {
    Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
     .appFont(12, weight: .medium, design: .monospaced)
     .foregroundColor(TerminalColors.amber)
    Text(l10n.t("%@ needs your input", agent.displayName))
     .appFont(11)
     .foregroundColor(.white.opacity(0.5))
     .lineLimit(1)
   }
   .opacity(showContent ? 1 : 0)
   .offset(x: showContent ? 0 : -10)

   Spacer()

   // Terminal button on right (similar to Allow button)
   Button {
    if isInTmux {
     onGoToTerminal()
    }
   } label: {
    HStack(spacing: 4) {
     Image(systemName: "terminal")
      .appFont(11, weight: .medium)
     Text(l10n.t("Terminal"))
      .appFont(13, weight: .medium)
    }
    .foregroundColor(isInTmux ? .black : .white.opacity(0.4))
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
    .clipShape(Capsule())
   }
   .buttonStyle(.plain)
   .opacity(showButton ? 1 : 0)
   .scaleEffect(showButton ? 1 : 0.8)
  }
  .frame(minHeight: 44)  // Consistent height with other bars
  .padding(.horizontal, 16)
  .padding(.vertical, 12)
  .background(Color.black.opacity(0.2))
  .onAppear {
   withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
    showContent = true
   }
   withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
    showButton = true
   }
  }
 }
}

// MARK: - Chat Approval Bar

/// 审批主按钮的形态。
///
/// 危险档（集成侧命中危险命令名单）**不能与常规档同形**：同一个位置、同一个词、
/// 同一个强调色会让「放行」变成肌肉记忆，危险命令被顺手点掉。抽成纯类型是为了把
/// 这条映射钉进单测（见 `ApprovalInteractionTests`）。
nonisolated enum ApprovalPrimaryAction: Equatable {
 /// 常规档：`.borderedProminent` + 「Allow」。
 case routine
 /// 危险档：`.bordered` + 危险色 + 「Run anyway」。
 case runAnyway

 init(isCritical: Bool) {
  self = isCritical ? .runAnyway : .routine
 }

 /// 是否用突出样式。只有常规档用——危险档保持描边，不抢主按钮位。
 var isProminent: Bool { self == .routine }
}

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
 let tool: String
 /// 要授权的输入的完整文本（不截断）；`nil` = 集成没带入参。
 let detail: String?
 /// 原始工具入参 JSON，供「详情」展开态显示。
 let rawInput: String?
 let display: PendingApprovalDisplay?
 let onApprove: () -> Void
 let onDeny: () -> Void
 @ObservedObject private var l10n = LocalizationManager.shared

 /// 主按钮形态：危险档换文案、换样式、换色（见 `ApprovalPrimaryAction`）。
 private var primaryAction: ApprovalPrimaryAction {
  ApprovalPrimaryAction(isCritical: display?.isCritical == true)
 }

 /// 系统的「减弱动态效果」偏好：入场弹性经 `AppMotion` 换曲线。错峰的延迟**保留**——
 /// 命中区门禁（`approveButton`）跟的是「已显示」这个状态，不跟曲线。
 @Environment(\.accessibilityReduceMotion) private var reduceMotion

 @State private var showContent = false
 @State private var showAllowButton = false
 @State private var showDenyButton = false

 var body: some View {
  VStack(alignment: .leading, spacing: 8) {
   HStack(spacing: 12) {
    // Tool info
    VStack(alignment: .leading, spacing: 2) {
     Text(MCPToolFormatter.formatToolName(tool))
      .appFont(12, weight: .medium, design: .monospaced)
      .foregroundColor(display?.isCritical == true ? AppPalette.danger : TerminalColors.amber)
     if let display, display.isCritical {
      // 集成侧命中危险命令名单：与普通待批区分开，避免「看不出这次是危险的」
      Text(l10n.t("Dangerous command"))
       .appFont(11, weight: .medium)
       .foregroundColor(AppPalette.danger)
     }
     if let display, display.terminalIsAsking {
      Text(l10n.t("Asking in terminal"))
       .appFont(11)
       .foregroundColor(AppPalette.tertiaryText)
     }
     if let display, display.isGateDegraded {
      Text(
       display.degradedTier.map { l10n.t("Gate degraded: %@", $0) }
        ?? l10n.t("Gate degraded")
      )
      .appFont(11)
      .foregroundColor(AppPalette.warning)
     }
    }
    .opacity(showContent ? 1 : 0)
    .offset(x: showContent ? 0 : -10)

    Spacer()

    // Deny button
    Button {
     onDeny()
    } label: {
     Text(l10n.t("Deny"))
      .appFont(13, weight: .medium)
      .lineLimit(1)
      .fixedSize()
    }
    .buttonStyle(.bordered)
    .opacity(showDenyButton ? 1 : 0)
    .scaleEffect(showDenyButton ? 1 : 0.8)
    // 与放行按钮同一条不变量：看不见的按钮不能接点击（见 `approveButton`）。
    .allowsHitTesting(showDenyButton)

    approveButton
   }

   // 要授权的输入在这里完整摊开：此前它只是标题下面一行 `lineLimit(1)` 的摘要，
   // Write/Edit 只看得见文件名、Bash 只看得见前 100 字——「看清再放行」在界面上
   // 根本做不到。整块与按钮行同宽，长路径/长命令才读得下去。
   if let detail {
    ApprovalDetailBlock(text: detail, rawInput: rawInput)
     .opacity(showContent ? 1 : 0)
   }
  }
  .frame(minHeight: 44)  // Consistent height with other bars
  .padding(.horizontal, 16)
  .padding(.vertical, 12)
  .background(Color.black.opacity(0.2))
  .onAppear {
   withAnimation(
    AppMotion.pick(
     .spring(response: 0.3, dampingFraction: 0.7), reduceMotion: reduceMotion
    ).delay(0.05)
   ) {
    showContent = true
   }
   withAnimation(
    AppMotion.pick(
     .spring(response: 0.35, dampingFraction: 0.7), reduceMotion: reduceMotion
    ).delay(0.1)
   ) {
    showDenyButton = true
   }
   withAnimation(
    AppMotion.pick(
     .spring(response: 0.35, dampingFraction: 0.7), reduceMotion: reduceMotion
    ).delay(0.15)
   ) {
    showAllowButton = true
   }
  }
 }

 /// 放行按钮。**命中区必须与可见性同步**：`opacity(0)` 不参与命中测试，淡入的这
 /// 100–150ms 里一枚看不见的按钮就能放行一次权限请求。`.allowsHitTesting` 是这条
 /// 不变量的落点，别把它当成多余的一行删掉。
 @ViewBuilder
 private var approveButton: some View {
  if primaryAction.isProminent {
   Button {
    onApprove()
   } label: {
    approveLabel(l10n.t("Allow"))
   }
   .buttonStyle(.borderedProminent)
   .opacity(showAllowButton ? 1 : 0)
   .scaleEffect(showAllowButton ? 1 : 0.8)
   .allowsHitTesting(showAllowButton)
  } else {
   Button {
    onApprove()
   } label: {
    approveLabel(l10n.t("Run anyway"))
   }
   .buttonStyle(.bordered)
   .tint(AppPalette.danger)
   .opacity(showAllowButton ? 1 : 0)
   .scaleEffect(showAllowButton ? 1 : 0.8)
   .allowsHitTesting(showAllowButton)
  }
 }

 private func approveLabel(_ text: String) -> some View {
  Text(text)
   .appFont(13, weight: .medium)
   .lineLimit(1)
   .fixedSize()
 }
}

/// 审批输入块的高度算术（用于 `ApprovalDetailBlock`）。
///
/// 单独抽出来是为了可单测，也为了把「一行短路径不该撑出一片空白」写成不变量：
/// 里层的 `ScrollView` 是灵活的，让面板自己分高度的话，它会分走一大块（把对话区挤小）
/// 甚至留白。这里按估算的折行数给确定高度，超出上限才交给滚动。
nonisolated enum ApprovalDetailLayout {
 /// 11pt 等宽字的一行高度（pt）：系统行高约为字号的 1.2 倍，取 14 留一点余量，
 /// 免得估算偏小把最后一行裁掉。
 static let lineHeight: CGFloat = 14

 /// 块高 = 内容（估算）高，最多 `ToolOutputWindow.expandedMaxHeight`。
 static func height(for text: String) -> CGFloat {
  let lines = CGFloat(ToolOutputWindow.estimatedWrappedLineCount(of: text))
  return min(lines * lineHeight, ToolOutputWindow.expandedMaxHeight)
 }
}

/// 审批输入块：把「要授权的东西」完整摊开，再挂一层原始入参 JSON。
///
/// 高度是算出来的确定值（`ApprovalDetailLayout`），上限与工具输出的长文本同一档
/// （`ToolOutputWindow.expandedMaxHeight`），不另起常量：整条命令可能很长，但审批条
/// 不能把对话区撑满。
private struct ApprovalDetailBlock: View {
 let text: String
 /// `nil` = 没有原始入参（旧集成），不画详情开关。
 let rawInput: String?

 @ObservedObject private var l10n = LocalizationManager.shared
 @State private var showsRawInput = false

 var body: some View {
  VStack(alignment: .leading, spacing: 4) {
   ScrollView(.vertical, showsIndicators: false) {
    Text(text)
     .appFont(11, design: .monospaced)
     .foregroundColor(AppPalette.secondaryText)
     .textSelection(.enabled)
     .frame(maxWidth: .infinity, alignment: .leading)
   }
   .frame(height: ApprovalDetailLayout.height(for: text))

   if let rawInput {
    if showsRawInput {
     ScrollView(.vertical, showsIndicators: false) {
      Text(rawInput)
       .appFont(10, design: .monospaced)
       .foregroundColor(AppPalette.tertiaryText)
       .textSelection(.enabled)
       .frame(maxWidth: .infinity, alignment: .leading)
     }
     .frame(height: ApprovalDetailLayout.height(for: rawInput))
    }

    Button {
     showsRawInput.toggle()
    } label: {
     // 文案复用既有的「Show / Collapse」两条键：catalog 里没有「详情」这一条，
     // 需要新键时先上报，不擅自往 catalog 里加（单写者纪律）。
     Text(showsRawInput ? l10n.t("Collapse") : l10n.t("Show"))
      .appFont(10, weight: .medium)
      .foregroundColor(AppPalette.secondaryText)
      .contentShape(Rectangle())
    }
    .buttonStyle(SettingsCompactButtonStyle())
    .accessibilityLabel(Text(showsRawInput ? l10n.t("Collapse") : l10n.t("Show")))
   }
  }
 }
}

// MARK: - New Messages Indicator

/// 回到最新入口的悬浮胶囊。上翻回看时出现（见 `LatestJumpIndicator`）；
/// `count == 0` 时只剩箭头——没有新消息也必须有入口，否则用户卡在半空。
struct NewMessagesIndicator: View {
 let count: Int
 /// 归属 Agent 的品牌色
 let color: Color
 let onTap: () -> Void
 @ObservedObject private var l10n = LocalizationManager.shared

 @State private var isHovering: Bool = false

 /// 无障碍名称：无新消息时胶囊里只有一枚箭头，VoiceOver 只能念出「chevron down」。
 /// catalog 里没有「回到底部」这一条，这里先复用既有的 Show（需要新键时另行上报）。
 private var accessibilityText: String {
  count > 0 ? l10n.t("%lld new messages", count) : l10n.t("Show")
 }

 var body: some View {
  Button(action: onTap) {
   HStack(spacing: 6) {
    Image(systemName: "chevron.down")
     .appFont(10, weight: .bold)

    if count > 0 {
     Text(l10n.t("%lld new messages", count))
      .appFont(12, weight: .medium)
    }
   }
   .foregroundColor(.white)
   .padding(.horizontal, 14)
   .padding(.vertical, 8)
   .background(
    Capsule()
     .fill(color)
     .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
   )
   .scaleEffect(isHovering ? 1.05 : 1.0)
  }
  .buttonStyle(.plain)
  .accessibilityLabel(Text(accessibilityText))
  .onHover { hovering in
   withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
    isHovering = hovering
   }
  }
 }
}
