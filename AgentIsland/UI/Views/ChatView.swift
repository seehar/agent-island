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
 @FocusState private var isInputFocused: Bool

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

 var body: some View {
  ZStack {
   VStack(spacing: 0) {
    // Header
    chatHeader

    // Messages
    if isLoading {
     loadingState
    } else if history.isEmpty {
     emptyState
    } else {
     messageList
    }

    // Approval bar, interactive prompt, or Input bar
    if let tool = approvalTool {
     if tool == "AskUserQuestion" {
      // Interactive tools - show prompt to answer in terminal
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
     if !isAutoscrollPaused && countChanged {
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

 private var chatHeader: some View {
  Button {
   viewModel.exitChat()
  } label: {
   HStack(spacing: 8) {
    Image(systemName: "chevron.left")
     .font(.system(size: 14, weight: .semibold))
     .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
     .frame(width: 24, height: 24)

    Text(session.displayTitle)
     .font(.system(size: 14, weight: .semibold))
     .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
     .lineLimit(1)

    // 多 Agent 时标注当前会话归属；单 Agent 用户保持原样
    if AgentRegistry.enabled.count > 1 {
     AgentBadge(agent: session.agent)
    }

    Spacer()
   }
   .padding(.horizontal, 12)
   .padding(.vertical, 10)
   .background(
    RoundedRectangle(cornerRadius: 8)
     .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
   )
  }
  .buttonStyle(.plain)
  .onHover { isHeaderHovered = $0 }
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
    .font(.system(size: 13, weight: .medium))
    .foregroundColor(.white.opacity(0.4))
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity)
 }

 // MARK: - Empty State

 private var emptyState: some View {
  VStack(spacing: 8) {
   Image(systemName: "bubble.left.and.bubble.right")
    .font(.system(size: 24))
    .foregroundColor(.white.opacity(0.2))
   Text(l10n.t("No messages yet"))
    .font(.system(size: 13, weight: .medium))
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
   // New messages indicator overlay
   .overlay(alignment: .bottom) {
    if isAutoscrollPaused && newMessageCount > 0 {
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
    .spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0
   )
  }
 }

 // MARK: - Input Bar

 /// Can send messages only if session is in tmux
 private var canSendMessages: Bool {
  session.isInTmux && session.tty != nil
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
   .font(.system(size: 13))
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
     .font(.system(size: 28))
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

 // MARK: - Approval Bar

 private func approvalBar(tool: String) -> some View {
  ChatApprovalBar(
   tool: tool,
   toolInput: session.pendingToolInput,
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
   if let pid = session.pid {
    _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
   } else {
    _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
   }
  }
 }

 private func approvePermission() {
  sessionMonitor.approvePermission(key: key)
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

 /// 把一条消息送进该会话所在的 tmux pane，返回是否真的送达。
 /// 以前这个返回值被丢弃：「找不到 pane / tmux 路径不可用 / 发送失败」在界面上完全一样，
 /// 用户看到的是消息凭空消失。
 private func sendToSession(_ text: String) async -> Bool {
  guard session.isInTmux else { return false }
  guard let tty = session.tty else { return false }

  guard let target = await findTmuxTarget(tty: tty) else { return false }
  return await ToolApprovalHandler.shared.sendMessage(text, to: target)
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
      .font(.system(size: 12))
     Text(l10n.t("Image (%@)", image.mediaType))
      .font(.system(size: 12))
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
    .font(.system(size: 13))
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
     .font(.system(size: 12, weight: .medium))
     .foregroundColor(textColor)
     .fixedSize()

    if tool.presentsAsSubagentContainer {
     // Claude 给的是子 Agent 内部的工具明细，omp/pi 给的是子 Agent 实例本身。
     if !tool.subagentTools.isEmpty {
      let taskDesc = tool.input["description"] ?? l10n.t("Running agent...")
      Text(l10n.t("%@ (%lld tools)", taskDesc, tool.subagentTools.count))
       .font(.system(size: 11))
       .foregroundColor(textColor.opacity(0.7))
       .lineLimit(1)
       .truncationMode(.tail)
     } else {
      Text(l10n.t("%lld agents", tool.subagentRuns.count))
       .font(.system(size: 11))
       .foregroundColor(textColor.opacity(0.7))
       .lineLimit(1)
       .truncationMode(.tail)
     }
    } else if tool.name == "AgentOutputTool", let desc = agentDescription {
     let blocking = tool.input["block"] == "true"
     Text(blocking ? l10n.t("Waiting: %@", desc) : desc)
      .font(.system(size: 11))
      .foregroundColor(textColor.opacity(0.7))
      .lineLimit(1)
      .truncationMode(.tail)
    } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
     Text(MCPToolFormatter.formatArgs(tool.input))
      .font(.system(size: 11))
      .foregroundColor(textColor.opacity(0.7))
      .lineLimit(1)
      .truncationMode(.tail)
    } else {
     Text(tool.statusDisplay.text)
      .font(.system(size: 11))
      .foregroundColor(textColor.opacity(0.7))
      .lineLimit(1)
      .truncationMode(.tail)
    }

    Spacer()

    // Expand indicator (only for expandable tools)
    if canExpand && tool.status != .running && tool.status != .waitingForApproval {
     Image(systemName: "chevron.right")
      .font(.system(size: 9, weight: .medium))
      .foregroundColor(.white.opacity(0.3))
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }
   }

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
    .font(.system(size: 10, weight: .medium))
    .foregroundColor(.white.opacity(0.6))

   if let agent = run.agent, !agent.isEmpty {
    Text(agent)
     .font(.system(size: 10))
     .foregroundColor(.white.opacity(0.35))
   }

   if let tool = run.currentTool, run.status.isRunning {
    Text(tool)
     .font(.system(size: 10, design: .monospaced))
     .foregroundColor(.white.opacity(0.4))
   }

   Text(statusText)
    .font(.system(size: 10))
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
     .font(.system(size: 10))
     .foregroundColor(.white.opacity(0.4))
   }

   // Show last 2 tools (most recent activity)
   ForEach(recentTools) { tool in
    SubagentToolRow(tool: tool)
   }
  }
 }
}

/// Single subagent tool row
struct SubagentToolRow: View {
 let tool: SubagentToolCall
 @ObservedObject private var l10n = LocalizationManager.shared

 @State private var dotOpacity: Double = 0.5

 private var statusColor: Color {
  switch tool.status {
  case .running, .waitingForApproval: return .orange
  case .success: return .green
  case .error, .interrupted: return .red
  }
 }

 /// Get status text using the same logic as regular tools
 private var statusText: String {
  if tool.status == .interrupted {
   return l10n.t("Interrupted")
  } else if tool.status == .running {
   return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
  } else {
   // For completed subagent tools, we don't have the result data
   // so use a simple display based on tool name and input
   return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
  }
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
    .font(.system(size: 10, weight: .medium))
    .foregroundColor(.white.opacity(0.6))

   // Status text (same format as regular tools)
   Text(statusText)
    .font(.system(size: 10))
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
    .font(.system(size: 10, weight: .medium))
    .foregroundColor(.white.opacity(0.5))

   HStack(spacing: 8) {
    ForEach(toolCounts.prefix(5), id: \.0) { name, count in
     HStack(spacing: 2) {
      Text(name)
       .font(.system(size: 10, design: .monospaced))
       .foregroundColor(.white.opacity(0.4))
      Text("×\(count)")
       .font(.system(size: 9, design: .monospaced))
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
     .font(.system(size: 11))
     .foregroundColor(.gray)
     .italic()
     .lineLimit(isExpanded ? nil : 1)
     .multilineTextAlignment(.leading)

    Spacer()

    if canExpand {
     Image(systemName: "chevron.right")
      .font(.system(size: 9, weight: .medium))
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
    .font(.system(size: 13))
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
     .font(.system(size: 12, weight: .medium, design: .monospaced))
     .foregroundColor(TerminalColors.amber)
    Text(l10n.t("%@ needs your input", agent.displayName))
     .font(.system(size: 11))
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
      .font(.system(size: 11, weight: .medium))
     Text(l10n.t("Terminal"))
      .font(.system(size: 13, weight: .medium))
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

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
 let tool: String
 let toolInput: String?
 let onApprove: () -> Void
 let onDeny: () -> Void
 @ObservedObject private var l10n = LocalizationManager.shared

 @State private var showContent = false
 @State private var showAllowButton = false
 @State private var showDenyButton = false

 var body: some View {
  HStack(spacing: 12) {
   // Tool info
   VStack(alignment: .leading, spacing: 2) {
    Text(MCPToolFormatter.formatToolName(tool))
     .font(.system(size: 12, weight: .medium, design: .monospaced))
     .foregroundColor(TerminalColors.amber)
    if let input = toolInput {
     Text(input)
      .font(.system(size: 11))
      .foregroundColor(.white.opacity(0.5))
      .lineLimit(1)
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
     .font(.system(size: 13, weight: .medium))
     .foregroundColor(.white.opacity(0.7))
     .padding(.horizontal, 16)
     .padding(.vertical, 8)
     .background(Color.white.opacity(0.1))
     .clipShape(Capsule())
   }
   .buttonStyle(.plain)
   .opacity(showDenyButton ? 1 : 0)
   .scaleEffect(showDenyButton ? 1 : 0.8)

   // Allow button
   Button {
    onApprove()
   } label: {
    Text(l10n.t("Allow"))
     .font(.system(size: 13, weight: .medium))
     .foregroundColor(.black)
     .padding(.horizontal, 16)
     .padding(.vertical, 8)
     .background(Color.white.opacity(0.95))
     .clipShape(Capsule())
   }
   .buttonStyle(.plain)
   .opacity(showAllowButton ? 1 : 0)
   .scaleEffect(showAllowButton ? 1 : 0.8)
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
    showDenyButton = true
   }
   withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
    showAllowButton = true
   }
  }
 }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
 let count: Int
 /// 归属 Agent 的品牌色
 let color: Color
 let onTap: () -> Void
 @ObservedObject private var l10n = LocalizationManager.shared

 @State private var isHovering: Bool = false

 var body: some View {
  Button(action: onTap) {
   HStack(spacing: 6) {
    Image(systemName: "chevron.down")
     .font(.system(size: 10, weight: .bold))

    Text(l10n.t("%lld new messages", count))
     .font(.system(size: 12, weight: .medium))
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
  .onHover { hovering in
   withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
    isHovering = hovering
   }
  }
 }
}
