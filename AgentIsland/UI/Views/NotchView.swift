//
//  NotchView.swift
//  AgentIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
 opened: (top: CGFloat(19), bottom: CGFloat(24)),
 closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
 @ObservedObject var viewModel: NotchViewModel
 @StateObject private var sessionMonitor = ClaudeSessionMonitor()
 @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
 @ObservedObject private var updateManager = UpdateManager.shared
 @ObservedObject private var l10n = LocalizationManager.shared
 @State private var previousPendingIds: Set<String> = []
 @State private var previousWaitingForInputIds: Set<String> = []
 @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
 @State private var isVisible: Bool = false
 @State private var isHovering: Bool = false
 @State private var isBouncing: Bool = false
 /// 头部右上角菜单按钮的悬停态（反馈口径与设置面板一致）
 @State private var isMenuButtonHovered: Bool = false

 @Namespace private var activityNamespace

 /// 是否有任意 Agent 的会话正在处理或压缩上下文
 private var isAnyProcessing: Bool {
  sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
 }

 /// 是否有任意 Agent 的会话正在等待审批
 private var hasPendingPermission: Bool {
  sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
 }

 /// 是否有任意 Agent 的会话处于等待输入（完成/就绪）状态且还在展示窗口内
 private var hasWaitingForInput: Bool {
  let now = Date()
  let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

  return sessionMonitor.instances.contains { session in
   guard session.phase == .waitingForInput else { return false }
   // Only show if within the 30-second display window
   if let enteredAt = waitingForInputTimestamps[session.stableId] {
    return now.timeIntervalSince(enteredAt) < displayDuration
   }
   return false
  }
 }

 /// 处理中（含压缩上下文）的会话数：关闭态计数徽标的分子
 private var activeSessionCount: Int {
  sessionMonitor.instances.filter { $0.phase.isActive }.count
 }

 /// 当前纳管的会话总数：关闭态计数徽标的分母
 private var totalSessionCount: Int {
  sessionMonitor.instances.count
 }

 /// 正在跑的 subAgent 总数（跨会话求和）。
 /// omp/pi 走子 Agent 生命周期（`task:subagent:*`），Claude 退回「在飞的 Task 工具」，
 /// 两者收敛在 `SessionState.activeSubagentCount`。
 private var activeSubagentCount: Int {
  sessionMonitor.instances.reduce(0) { $0 + $1.activeSubagentCount }
 }

 /// 计数徽标的取色：与左侧标记**同一个来源**（headerAgent 的品牌色），
 /// 所以两侧永远同色；没有标记可挂时退回弱化色。状态由标记的动效（呼吸 / 走 / 弹跳）
 /// 与左侧的审批指示表达，不再占用这个色位。
 private var sessionCountColor: Color {
  headerAgent?.brandColor ?? TerminalColors.dim
 }

 // MARK: - Sizing

 private var closedNotchSize: CGSize {
  CGSize(
   width: viewModel.deviceNotchRect.width,
   height: viewModel.deviceNotchRect.height
  )
 }

 /// Extra width for expanding activities (like Dynamic Island)
 private var expansionWidth: CGFloat {
  // Permission indicator adds width on left side only
  let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0

  // Expand for processing activity
  if activityCoordinator.expandingActivity.show {
   switch activityCoordinator.expandingActivity.type {
   case .processing:
    let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
    return baseWidth + permissionIndicatorWidth
   case .none:
    break
   }
  }

  // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
  if hasPendingPermission {
   return 2 * max(0, closedNotchSize.height - 12) + 20 + permissionIndicatorWidth
  }

  // Waiting for input just shows checkmark on right, no extra left indicator
  if hasWaitingForInput {
   return 2 * max(0, closedNotchSize.height - 12) + 20
  }

  return 0
 }

 private var notchSize: CGSize {
  switch viewModel.status {
  case .closed, .popping:
   return closedNotchSize
  case .opened:
   return viewModel.openedSize
  }
 }

 /// Width of the closed content (notch + any expansion)
 private var closedContentWidth: CGFloat {
  closedNotchSize.width + expansionWidth
 }

 // MARK: - Corner Radii

 private var topCornerRadius: CGFloat {
  viewModel.status == .opened
   ? cornerRadiusInsets.opened.top
   : cornerRadiusInsets.closed.top
 }

 private var bottomCornerRadius: CGFloat {
  viewModel.status == .opened
   ? cornerRadiusInsets.opened.bottom
   : cornerRadiusInsets.closed.bottom
 }

 private var currentNotchShape: NotchShape {
  NotchShape(
   topCornerRadius: topCornerRadius,
   bottomCornerRadius: bottomCornerRadius
  )
 }

 // Animation springs
 private let openAnimation = Animation.spring(
  response: 0.42, dampingFraction: 0.8, blendDuration: 0)
 private let closeAnimation = Animation.spring(
  response: 0.45, dampingFraction: 1.0, blendDuration: 0)

 // MARK: - Body

 var body: some View {
  ZStack(alignment: .top) {
   // Outer container does NOT receive hits - only the notch content does
   VStack(spacing: 0) {
    notchLayout
     .frame(
      maxWidth: viewModel.status == .opened ? notchSize.width : nil,
      alignment: .top
     )
     .padding(
      .horizontal,
      viewModel.status == .opened
       ? cornerRadiusInsets.opened.top
       : cornerRadiusInsets.closed.bottom
     )
     .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
     .background(.black)
     .clipShape(currentNotchShape)
     .overlay(alignment: .top) {
      Rectangle()
       .fill(.black)
       .frame(height: 1)
       .padding(.horizontal, topCornerRadius)
     }
     .shadow(
      color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
      radius: 6
     )
     .frame(
      maxWidth: viewModel.status == .opened ? notchSize.width : nil,
      maxHeight: viewModel.status == .opened ? notchSize.height : nil,
      alignment: .top
     )
     .animation(
      viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status
     )
     .animation(openAnimation, value: notchSize)  // Animate container size changes between content types
     .animation(.smooth, value: activityCoordinator.expandingActivity)
     .animation(.smooth, value: hasPendingPermission)
     .animation(.smooth, value: hasWaitingForInput)
     .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
     .contentShape(Rectangle())
     .onHover { hovering in
      withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
       isHovering = hovering
      }
     }
     .onTapGesture {
      if viewModel.status != .opened {
       viewModel.notchOpen(reason: .click)
      }
     }
   }
  }
  .opacity(isVisible ? 1 : 0)
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  .preferredColorScheme(.dark)
  .onAppear {
   sessionMonitor.startMonitoring()
   // On non-notched devices, keep visible so users have a target to interact with
   if !viewModel.hasPhysicalNotch {
    isVisible = true
   }
  }
  .onChange(of: viewModel.status) { oldStatus, newStatus in
   handleStatusChange(from: oldStatus, to: newStatus)
  }
  .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
   handlePendingSessionsChange(sessions)
  }
  .onChange(of: sessionMonitor.instances) { _, instances in
   handleProcessingChange()
   handleWaitingForInputChange(instances)
  }
 }

 // MARK: - Notch Layout

 private var isProcessing: Bool {
  activityCoordinator.expandingActivity.show
   && activityCoordinator.expandingActivity.type == .processing
 }

 /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
 private var showClosedActivity: Bool {
  isProcessing || hasPendingPermission || hasWaitingForInput
 }

 @ViewBuilder
 private var notchLayout: some View {
  VStack(alignment: .leading, spacing: 0) {
   // Header row - always present, contains crab and spinner that persist across states
   headerRow
    .frame(height: max(24, closedNotchSize.height))

   // Main content only when opened
   if viewModel.status == .opened {
    contentView
     .frame(width: notchSize.width - 24)  // Fixed width to prevent reflow
     .transition(
      .asymmetric(
       insertion: .scale(scale: 0.8, anchor: .top)
        .combined(with: .opacity)
        .animation(.smooth(duration: 0.35)),
       removal: .opacity.animation(.easeOut(duration: 0.15))
      )
     )
   }
  }
 }

 // MARK: - Header Row (persists across states)

 /// 头部标记归属的 Agent：当前正在查看的聊天会话优先，其次是最需要用户注意的
 /// 会话，最后退到实例列表首行；都无法归属时不画标记，以免张冠李戴。
 private var headerAgent: AgentKind? {
  if case .chat(let session) = viewModel.contentType {
   return session.agent
  }
  return attentionSession?.agent ?? sessionMonitor.instances.first?.agent
 }

 /// 最需要用户注意的会话：待审批 > 处理中 > 等待输入，同级取最近活动的那个。
 private var attentionSession: SessionState? {
  var best: (session: SessionState, rank: Int)?
  for session in sessionMonitor.instances {
   guard let rank = attentionRank(session) else { continue }
   if let current = best,
    current.rank < rank || (current.rank == rank && current.session.lastActivity >= session.lastActivity)
   {
    continue
   }
   best = (session, rank)
  }
  return best?.session
 }

 /// 会话的注意力优先级：待审批 0、处理中 1、等待输入 2；其余状态不参与排序。
 private func attentionRank(_ session: SessionState) -> Int? {
  if session.phase.isWaitingForApproval { return 0 }
  if session.phase == .processing || session.phase == .compacting { return 1 }
  if session.phase == .waitingForInput { return 2 }
  return nil
 }

 /// 头部标记的动效：跟着当前最需要注意的会话走，聊天中则跟聊天会话。
 private var headerActivity: AgentLogoActivity {
  if case .chat(let session) = viewModel.contentType {
   return AgentLogoActivity(session.phase)
  }
  return attentionSession.map { AgentLogoActivity($0.phase) } ?? .idle
 }

 /// 头部左侧的 Agent 标记。`isSource` 交给 matchedGeometryEffect，
 /// 让标记在关闭态与展开态的头部之间平滑过渡。
 @ViewBuilder
 private func headerLogo(isSource: Bool) -> some View {
  if let agent = headerAgent {
   AgentLogo(agent: agent, size: 14, activity: headerActivity)
    .matchedGeometryEffect(id: "agent-logo", in: activityNamespace, isSource: isSource)
  }
 }

 @ViewBuilder
 private var headerRow: some View {
  HStack(spacing: 0) {
   // 左侧 - Agent 标记 + 可选审批指示（处理中、待审批、等待输入时可见）
   if showClosedActivity {
    HStack(spacing: 4) {
     headerLogo(isSource: showClosedActivity)

     // Permission indicator only (amber) - waiting for input shows checkmark on right
     if hasPendingPermission {
      PermissionIndicatorIcon(size: 14, color: TerminalColors.amber)
       .matchedGeometryEffect(
        id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
     }
    }
    .frame(width: viewModel.status == .opened ? nil : sideWidth + (hasPendingPermission ? 18 : 0))
    .padding(.leading, viewModel.status == .opened ? 8 : 0)
   }

   // Center content
   if viewModel.status == .opened {
    // Opened: show header content
    openedHeaderContent
   } else if !showClosedActivity {
    // Closed without activity: empty space
    Rectangle()
     .fill(.clear)
     .frame(width: closedNotchSize.width - 20)
   } else {
    // Closed with activity: black spacer (with optional bounce)
    Rectangle()
     .fill(.black)
     .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
   }

   // Right side - 关闭态展示「活跃数/总数」，状态由计数取色与左侧 logo 表达
   if showClosedActivity {
    sessionCountBadge
     .frame(width: viewModel.status == .opened ? nil : sideWidth)
     .padding(.trailing, viewModel.status == .opened ? 0 : 4)
   }
  }
  .frame(height: closedNotchSize.height)
 }

 private var sideWidth: CGFloat {
  max(0, closedNotchSize.height - 12) + 10
 }

 /// 关闭态右侧的会话计数：`活跃/总数`，有 subAgent 在跑时追加 `+N`。
 /// 活跃数取头部标记的品牌色、总数弱化，数字等宽以免计数刷新时宽度抖动
 private var sessionCountBadge: some View {
  (
   Text("\(activeSessionCount)").foregroundColor(sessionCountColor)
    + Text(activeSubagentCount > 0 ? "+\(activeSubagentCount)" : "").foregroundColor(
     sessionCountColor)
    + Text("/\(totalSessionCount)").foregroundColor(TerminalColors.dim)
  )
  .font(.system(size: 11, weight: .semibold, design: .rounded))
  .monospacedDigit()
  .lineLimit(1)
  .minimumScaleFactor(0.75)  // 会话很多时缩字而非溢出 36pt 的关闭态槽位
  .accessibilityLabel(
   Text(
    activeSubagentCount > 0
     ? l10n.t(
      "Active sessions %lld of %lld, %lld subagents running", activeSessionCount,
      totalSessionCount, activeSubagentCount)
     : l10n.t("Active sessions %lld of %lld", activeSessionCount, totalSessionCount)))
 }

 // MARK: - Opened Header Content

 @ViewBuilder
 private var openedHeaderContent: some View {
  HStack(spacing: 12) {
   // Show static crab only if not showing activity in headerRow
   // (headerRow handles crab + indicator when showClosedActivity is true)
   if !showClosedActivity {
    headerLogo(isSource: !showClosedActivity)
     .padding(.leading, 8)
   }

   Spacer()

   // Menu toggle
   Button {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
     viewModel.toggleMenu()
     if viewModel.contentType == .menu {
      updateManager.markUpdateSeen()
     }
    }
   } label: {
    ZStack(alignment: .topTrailing) {
     Image(systemName: viewModel.contentType == .menu ? "xmark" : "gearshape")
      .font(.system(size: 11, weight: .medium))
      .foregroundColor(.white.opacity(0.4))

     // 有未看过的更新：用形状（向下箭头徽标）承载状态，颜色只作辅助——
     // 只靠颜色区分状态，在黑白截图与色觉障碍下都会丢信息。
     if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
      Image(systemName: "arrow.down.circle.fill")
       .font(.system(size: 9, weight: .semibold))
       .foregroundColor(AppPalette.accent)
       .offset(x: -2, y: 2)
       .accessibilityHidden(true)
     }
    }
    .frame(width: 22, height: 22)
    .background(
     RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
      .fill(isMenuButtonHovered ? AppPalette.rowHover : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { isMenuButtonHovered = $0 }
   }
   .buttonStyle(SettingsCompactButtonStyle())
  }
 }

 // MARK: - Content View (Opened State)

 @ViewBuilder
 private var contentView: some View {
  Group {
   switch viewModel.contentType {
   case .instances:
    ClaudeInstancesView(
     sessionMonitor: sessionMonitor,
     viewModel: viewModel
    )
   case .menu:
    NotchMenuView(viewModel: viewModel)
   case .chat(let session):
    ChatView(
     key: session.sessionKey,
     initialSession: session,
     sessionMonitor: sessionMonitor,
     viewModel: viewModel
    )
    // Force a fresh ChatView when switching sessions — otherwise
    // @State (history, session, scroll position) leaks from the
    // previous session and the view shows the wrong conversation.
    // 只用会话键作为 identity（不用整个 SessionState），
    // 这样逐事件更新时仍复用同一个视图。
    .id(session.sessionKey.rawValue)
   }
  }
  .frame(width: notchSize.width - 24)  // Fixed width to prevent text reflow
 }

 // MARK: - Event Handlers

 private func handleProcessingChange() {
  if isAnyProcessing || hasPendingPermission {
   // Show claude activity when processing or waiting for permission
   activityCoordinator.showActivity(type: .processing)
   isVisible = true
  } else if hasWaitingForInput {
   // Keep visible for waiting-for-input but hide the processing spinner
   activityCoordinator.hideActivity()
   isVisible = true
  } else {
   // Hide activity when done
   activityCoordinator.hideActivity()

   // Delay hiding the notch until animation completes
   // Don't hide on non-notched devices - users need a visible target
   if viewModel.status == .closed && viewModel.hasPhysicalNotch {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
     if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput
      && viewModel.status == .closed
     {
      isVisible = false
     }
    }
   }
  }
 }

 private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
  switch newStatus {
  case .opened, .popping:
   isVisible = true
   // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
   if viewModel.openReason == .click || viewModel.openReason == .hover {
    waitingForInputTimestamps.removeAll()
   }
  case .closed:
   // Don't hide on non-notched devices - users need a visible target
   guard viewModel.hasPhysicalNotch else { return }
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
    if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission
     && !hasWaitingForInput && !activityCoordinator.expandingActivity.show
    {
     isVisible = false
    }
   }
  }
 }

 private func handlePendingSessionsChange(_ sessions: [SessionState]) {
  let currentIds = Set(sessions.map { $0.stableId })
  let newPendingIds = currentIds.subtracting(previousPendingIds)

  if !newPendingIds.isEmpty && viewModel.status == .closed
   && !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace()
  {
   viewModel.notchOpen(reason: .notification)
  }

  previousPendingIds = currentIds
 }

 private func handleWaitingForInputChange(_ instances: [SessionState]) {
  // Get sessions that are now waiting for input
  let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
  let currentIds = Set(waitingForInputSessions.map { $0.stableId })
  let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

  // Track timestamps for newly waiting sessions
  let now = Date()
  for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
   waitingForInputTimestamps[session.stableId] = now
  }

  // Clean up timestamps for sessions no longer waiting
  let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
  for staleId in staleIds {
   waitingForInputTimestamps.removeValue(forKey: staleId)
  }

  // Bounce the notch when a session newly enters waitingForInput state
  if !newWaitingIds.isEmpty {
   // Get the sessions that just entered waitingForInput
   let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

   // Play notification sound if the session is not actively focused
   if let soundName = AppSettings.notificationSound.soundName {
    // Check if we should play sound (async check for tmux pane focus)
    Task {
     let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
     if shouldPlaySound {
      await MainActor.run {
       // `play()` 经可选链后返回 `Void?`，显式丢弃以免闭包返回非 Void 值
       _ = NSSound(named: soundName)?.play()
      }
     }
    }
   }

   // Trigger bounce animation to get user's attention
   DispatchQueue.main.async {
    isBouncing = true
    // Bounce back after a short delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
     isBouncing = false
    }
   }

   // Schedule hiding the checkmark after 30 seconds
   DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
    // Trigger a UI update to re-evaluate hasWaitingForInput
    handleProcessingChange()
   }
  }

  previousWaitingForInputIds = currentIds
 }

 /// Determine if notification sound should play for the given sessions
 /// Returns true if ANY session is not actively focused
 private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
  for session in sessions {
   guard let pid = session.pid else {
    // No PID means we can't check focus, assume not focused
    return true
   }

   let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
   if !isFocused {
    return true
   }
  }

  return false
 }
}
