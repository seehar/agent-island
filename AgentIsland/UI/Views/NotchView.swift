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
 /// 统计页的视图模型：与 `sessionMonitor` 同款，由内容根持有，
 /// 内容面切换时不重建（切回统计页时不会重新取一次数据）。
 @StateObject private var usageStatsViewModel = UsageStatsViewModel()
 @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
 @ObservedObject private var updateManager = UpdateManager.shared
 @ObservedObject private var textSizeSelector = TextSizeSelector.shared
 /// 行为偏好里被视图直接读的三项：完成提示窗口、空闲可见性、提示音覆盖范围
 @ObservedObject private var completionBadge = CompletionBadgeSelector.shared
 @ObservedObject private var idleVisibility = IdleNotchVisibilitySelector.shared
 @ObservedObject private var notificationScope = NotificationScopeSelector.shared
 /// 待批到来时是否自动展开（档位见 `ApprovalAutoExpand`）
 @ObservedObject private var autoExpand = ApprovalAutoExpandSelector.shared
 @ObservedObject private var l10n = LocalizationManager.shared
 @State private var previousPendingIds: Set<String> = []
 @State private var previousWaitingForInputIds: Set<String> = []
 @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
 @State private var isVisible: Bool = false
 @State private var isHovering: Bool = false
 @State private var isBouncing: Bool = false
 /// 头部右上角菜单按钮的悬停态（反馈口径与设置面板一致）
 @State private var isMenuButtonHovered: Bool = false
 /// 头部右上角统计按钮的悬停态（与设置面板、设置按钮同一反馈口径）
 @State private var isStatsButtonHovered: Bool = false

 @Namespace private var activityNamespace

 /// 是否有任意 Agent 的会话正在处理或压缩上下文
 private var isAnyProcessing: Bool {
  sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
 }

 /// 是否有任意 Agent 的会话正在等待审批
 private var hasPendingPermission: Bool {
  sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
 }

 /// 是否有任意 Agent 的会话处于等待输入（完成/就绪）状态且还在展示窗口内。
 /// 窗口长度取「完成提示」档位；「一直显示」档位没有窗口，会留到会话状态变化。
 private var hasWaitingForInput: Bool {
  let now = Date()
  let displayWindow = completionBadge.option.window

  return sessionMonitor.instances.contains { session in
   guard session.phase == .waitingForInput else { return false }
   guard let displayWindow else { return true }
   guard let enteredAt = waitingForInputTimestamps[session.stableId] else { return false }
   return now.timeIntervalSince(enteredAt) < displayWindow
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
   if !viewModel.hasPhysicalNotch || !idleVisibility.option.hidesWhenIdle {
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

   // 统计入口：与设置按钮并列，两个按钮各自遵循同一互斥规则——内容面就是自己的
   // 目标面时显示 xmark（点击退回会话列表），否则显示自己的图标。设置按钮因此仍是最右侧
   // 那个，它在设置面板里承担的「唯一返回键」语义不受影响。
   Button {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
     viewModel.toggleStats()
    }
   } label: {
    Image(systemName: viewModel.contentType == .stats ? "xmark" : "chart.bar.xaxis")
     .font(.system(size: 11, weight: .medium))
     .foregroundColor(.white.opacity(0.4))
     .frame(width: 22, height: 22)
     .background(
      RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
       .fill(isStatsButtonHovered ? AppPalette.rowHover : Color.clear)
     )
     .contentShape(Rectangle())
     .onHover { isStatsButtonHovered = $0 }
   }
   .buttonStyle(SettingsCompactButtonStyle())
   .accessibilityLabel(Text(l10n.t("Statistics")))

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
    // 内容面按用户的字号档位缩放；设置面板（.menu）不注入，保持解析式高度
    .environment(\.appTextScale, textSizeSelector.scale)
   case .menu:
    NotchMenuView(viewModel: viewModel)
   case .stats:
    UsageStatsView(viewModel: usageStatsViewModel)
     // 内容面按用户的字号档位缩放；统计页自带滚动，放大也不会被裁掉
     .environment(\.appTextScale, textSizeSelector.scale)
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
    .environment(\.appTextScale, textSizeSelector.scale)
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
   activityCoordinator.hideActivity()
   scheduleIdleHide()
  }
 }

 /// 无活动时是否收起胶囊：按「空闲时的胶囊」档位——「一直显示」档不隐藏，
 /// 其余档在档位给的延时后隐藏；非刘海屏始终保留（用户需要一个可点的目标）。
 private func scheduleIdleHide() {
  let visibility = idleVisibility.option
  guard visibility.hidesWhenIdle, viewModel.status == .closed, viewModel.hasPhysicalNotch else {
   return
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + visibility.lingerWindow) {
   if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput
    && viewModel.status == .closed
   {
    isVisible = false
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
   // 「空闲时的胶囊」为「一直显示」时不隐藏
   guard idleVisibility.option.hidesWhenIdle else { return }
   DispatchQueue.main.asyncAfter(deadline: .now() + idleVisibility.option.closeDelay) {
    if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission
     && !hasWaitingForInput && !activityCoordinator.expandingActivity.show
    {
     isVisible = false
    }
   }
  }
 }

 /// 新的待批要不要把刘海自己展开。
 ///
 /// - `.never`：从不。
 /// - `.always`：任何待批都展开。
 /// - `.whenTerminalIsSilent`（默认）：**入口在刘海上**的待批一定展开——闸门版集成
 ///   （omp / pi / opencode）把工具调用拦在自己手里，终端侧不画提问，等待期间用户唯一
 ///   能作答的地方就是刘海；其余待批（Claude 的 `PermissionRequest`：终端里有对话框）
 ///   沿用「当前空间没有终端时才展开」的老口径，不去抢正在看终端的用户。
 private func shouldAutoExpand(_ newSessions: [SessionState]) -> Bool {
  autoExpand.option.shouldExpand(
   decisionOnlyOnNotch: newSessions.contains(where: decisionOnlyOnNotch),
   terminalVisible: TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace())
 }

 /// 这条待批的决定**只能在刘海**上给。
 ///
 /// 四个条件都要：相位在等待审批、Agent 用的是闸门信封（`ToolApproval`；Claude 的
 /// `PermissionRequest` 意味着终端里本来就有对话框）、刘海**真的持有**这条待批（让位态
 /// `omp_owns_approval` 的信封不登记待批，因此在这里被排除——它代表「终端正在问」，
 /// 不该抢用户的视线）、且不是交互式提问（`ask` 类在终端有自己的弹窗）。
 private func decisionOnlyOnNotch(_ session: SessionState) -> Bool {
  guard session.phase.isWaitingForApproval else { return false }
  guard session.agent.approval.requestEvent == "ToolApproval" else { return false }
  guard let display = sessionMonitor.approvalDisplay(for: session.sessionKey),
   !display.terminalIsAsking
  else { return false }
  guard let tool = session.pendingToolName, !session.agent.isInteractiveTool(tool) else {
   return false
  }
  return true
 }

 private func handlePendingSessionsChange(_ sessions: [SessionState]) {
  let currentIds = Set(sessions.map { $0.stableId })
  let newPendingIds = currentIds.subtracting(previousPendingIds)

  let newSessions = sessions.filter { newPendingIds.contains($0.stableId) }
  if !newSessions.isEmpty && viewModel.status == .closed && shouldAutoExpand(newSessions) {
   viewModel.notchOpen(reason: .notification)
  }

  // 「提示音范围」包含审批时，新出现的待审批会话也响一声
  if !newPendingIds.isEmpty, notificationScope.option.coversApprovals {
   playNotificationSound(for: sessions.filter { newPendingIds.contains($0.stableId) })
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

   playNotificationSound(for: newlyWaitingSessions)

   // Trigger bounce animation to get user's attention
   DispatchQueue.main.async {
    isBouncing = true
    // Bounce back after a short delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
     isBouncing = false
    }
   }

   // 展示窗口到期后刷新一次，让勾与活动态按「完成提示」档位退场；
   // 「一直显示」档位没有窗口，因此不需要这个定时。
   if let displayWindow = completionBadge.option.window {
    DispatchQueue.main.asyncAfter(deadline: .now() + displayWindow) { [self] in
     handleProcessingChange()
    }
   }
  }

  previousWaitingForInputIds = currentIds
 }

 /// 按设置播一声提示音：音效本身取「通知音效」，且只在该会话不在前台时响。
 private func playNotificationSound(for sessions: [SessionState]) {
  guard let soundName = AppSettings.notificationSound.soundName else { return }
  Task {
   guard await shouldPlayNotificationSound(for: sessions) else { return }
   await MainActor.run {
    // `play()` 经可选链后返回 `Void?`，显式丢弃以免闭包返回非 Void 值
    _ = NSSound(named: soundName)?.play()
   }
  }
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
