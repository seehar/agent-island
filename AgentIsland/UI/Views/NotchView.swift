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

// 头部行的间距（实测校准）。展开态右端是「图表 · 额度 · 齿轮 · 计数」：
//   · 三个按钮之间用 `headerControlSpacing`（原先固定 12，字形之间因此有 ~22pt）；
//   · 计数与齿轮之间再多给 `headerGlyphMargin`——按钮是 22pt 的方形悬停框、图标字形
//     只占中间约 12pt（左右各留约 5pt），而计数是字形直接起笔；不多给这 5pt，计数会
//     看起来比两个图标之间更近（原先的算式甚至把计数贴到齿轮上，实测间距 ~6pt）。
// 关闭态没有按钮，计数沿用胶囊自己的 4pt 尾距。
private let headerControlSpacing: CGFloat = 8
private let headerGlyphMargin: CGFloat = 5
private let headerBadgeTrailing: CGFloat = 4

struct NotchView: View {
 @ObservedObject var viewModel: NotchViewModel
 @ObservedObject var sessionMonitor: ClaudeSessionMonitor
 /// 统计页的视图模型：与 `sessionMonitor` 同款，由内容根持有——统计页在设置面板
 /// 里，分组切走再切回来（或从头部图标与齿轮两个入口进）都不重建：时间窗口、
 /// 已取到的快照都留着。
 @StateObject private var usageStatsViewModel = UsageStatsViewModel()
 /// 额度页的视图模型：同样由内容根持有——头部额度按钮与设置面板两个入口共用一份配置与读数。
 @StateObject private var balanceViewModel = NewAPIBalanceViewModel()
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
 /// 头部右上角额度按钮的悬停态（与统计、设置按钮同一反馈口径）
 @State private var isQuotaButtonHovered: Bool = false

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
     .animation(.smooth, value: countEarWidth)
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
    // 头部条带就是面板的「标题栏」：点它收起。它挂在视图上而不是鼠标监听里——
    // 条带里的按钮自己会吃掉点击，因此这里不必知道按钮在哪（用几何去算按钮范围正是
    // 上一版的缺陷来源：胶囊宽度超过约 260pt 后，图表按钮的命中区就整个落进
    // 「点刘海收起」的判定带里，点击被抢走）。命中区因此跟随真实版面，而不是胶囊宽度。
    // 展开态的头部行里有 Spacer，本来就会被撑满内容宽；这里**不要**再给
    // `maxWidth: .infinity`——那会在关闭态把胶囊拉成整屏宽（父容器是宽度不定的）。
    .contentShape(Rectangle())
    .onTapGesture {
     withAnimation(closeAnimation) {
      viewModel.collapseFromHeaderTap()
     }
    }

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
    .frame(
     width: viewModel.status == .opened ? nil : countEarWidth + (hasPendingPermission ? 18 : 0))
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

   // Right side - **只画关闭态**的「活跃数/总数」：状态由计数取色与左侧 logo 表达。
   // 展开态的计数在 `openedHeaderContent` 里（与两个按钮同一个 HStack，间距才统一）；
   // 两处都画会重叠成两个计数。
   if showClosedActivity && viewModel.status != .opened {
    sessionCountBadge(for: closedCountLabel)
     .frame(width: countEarWidth)
     .padding(.trailing, headerBadgeTrailing)
   }
  }
  .frame(height: closedNotchSize.height)
 }

 /// 关闭态的**最小**耳宽：由胶囊高度推出（32pt 高的刘海 → 30），跟着「胶囊高度」设置走。
 /// 计数文案更宽时由 `countEarWidth` 抬上去，见 `NotchClosedMetrics`。
 private var sideWidth: CGFloat {
  max(0, closedNotchSize.height - 12) + 10
 }

 /// 关闭态计数徽标的档位：受胶囊耳宽上限约束，超宽的计数退成更短的写法，而不是被截断。
 private var closedCountLabel: NotchClosedMetrics.Label {
  countLabel(limit: NotchClosedMetrics.maximumEarWidth)
 }

 /// 展开态头部的计数：面板够宽、不受上限约束，始终给最全的一档。
 private var openedCountLabel: NotchClosedMetrics.Label {
  countLabel(limit: .infinity)
 }

 private func countLabel(limit: CGFloat) -> NotchClosedMetrics.Label {
  NotchClosedMetrics.label(
   activeSessions: activeSessionCount,
   subagents: activeSubagentCount,
   totalSessions: totalSessionCount,
   limit: limit)
 }

 /// 关闭态左右耳的宽度：按当前计数文案的实测宽度自适应，夹在最小耳宽与上限之间。
 /// 左右耳**同宽**——胶囊在屏幕上居中，文字槽在右耳里居中，因此「计数避开相机挖孔」
 /// 只由耳宽决定；只加宽右耳反而会把计数推回挖孔里（推导见 `NotchClosedMetrics`）。
 private var countEarWidth: CGFloat {
  NotchClosedMetrics.earWidth(for: closedCountLabel, minimum: sideWidth)
 }

 /// 会话计数徽标：`活跃[+子]/总数`，按档位取舍（见 `NotchClosedMetrics`）。
 /// 活跃数与子 Agent 数取头部标记的品牌色、总数弱化，数字等宽以免计数刷新时宽度抖动。
 /// 槽宽由调用方给：关闭态用 `countEarWidth`，展开态不限制（自己那个 HStack 里放得下）。
 private func sessionCountBadge(for label: NotchClosedMetrics.Label) -> some View {
  sessionCountText(for: label)
   .font(
    .system(
     size: NotchClosedMetrics.fontSize,
     weight: NotchClosedMetrics.fontWeight,
     design: NotchClosedMetrics.fontDesign)
   )
   .monospacedDigit()
   .lineLimit(1)
   .minimumScaleFactor(0.75)  // 退到最省位的档仍超上限时缩字，而不是溢出
   .accessibilityLabel(Text(countAccessibilityLabel(for: label)))
 }

 /// 计数的可见文案：按档位画「活跃 / +子 / /总数」三段。
 private func sessionCountText(for label: NotchClosedMetrics.Label) -> Text {
  var text = Text("\(label.activeSessions)").foregroundColor(sessionCountColor)
  if let subagents = label.subagents {
   text = text + Text("+\(subagents)").foregroundColor(sessionCountColor)
  }
  if let total = label.totalSessions {
   text = text + Text("/\(total)").foregroundColor(TerminalColors.dim)
  }
  return text
 }

 /// 计数的无障碍文案：与可见档位一致——少画一段就少一句。
 private func countAccessibilityLabel(for label: NotchClosedMetrics.Label) -> String {
  if let subagents = label.subagents, let total = label.totalSessions {
   return l10n.t(
    "Active sessions %lld of %lld, %lld subagents running", label.activeSessions, total, subagents)
  }
  if let subagents = label.subagents {
   return l10n.t("Active sessions %lld, %lld subagents running", label.activeSessions, subagents)
  }
  if let total = label.totalSessions {
   return l10n.t("Active sessions %lld of %lld", label.activeSessions, total)
  }
  return l10n.t("Active sessions %lld", label.activeSessions)
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

   // 右端：图表 · 齿轮 · 计数。三者放进一个 HStack，间距取 headerControlSpacing——
   // 计数之前是 headerRow 的直接子项，被「固定槽宽 + 内边距」的算式推到了齿轮身上
   // （实测 6pt，而图表↔齿轮是 22pt）。
   HStack(spacing: headerControlSpacing) {
    // 统计入口：与设置按钮并列，两个按钮各自遵循同一互斥规则——内容面就是自己的
    // 目标面时显示 xmark（点击退回会话列表），否则显示自己的图标。统计页是设置面板里的
    // 一个分组，因此这个按钮等价于「设置面板 → 统计」；设置页自己的返回箭头仍负责
    // 「回到会话列表」。
    Button {
     withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      viewModel.toggleStatistics()
     }
    } label: {
     Image(systemName: viewModel.isShowingStatistics ? "xmark" : "chart.bar.xaxis")
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

    // 额度入口：与统计、设置按钮并列，规则同前——内容面就是额度页时显示 xmark（点击退回
    // 会话列表），否则显示信用卡图标。额度页同样是设置面板里的一个分组，因此这个按钮等价于
    // 「设置面板 → 额度」。
    Button {
     withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      viewModel.toggleQuota()
     }
    } label: {
     Image(systemName: viewModel.isShowingQuota ? "xmark" : "creditcard")
      .font(.system(size: 11, weight: .medium))
      .foregroundColor(.white.opacity(0.4))
      .frame(width: 22, height: 22)
      .background(
       RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        .fill(isQuotaButtonHovered ? AppPalette.rowHover : Color.clear)
      )
      .contentShape(Rectangle())
      .onHover { isQuotaButtonHovered = $0 }
    }
    .buttonStyle(SettingsCompactButtonStyle())
    .accessibilityLabel(Text(l10n.t("Quota")))

    // Menu toggle
    Button {
     withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      viewModel.toggleMenu()
      if viewModel.isShowingSettings {
       updateManager.markUpdateSeen()
      }
     }
    } label: {
     ZStack(alignment: .topTrailing) {
      Image(systemName: viewModel.isShowingSettings ? "xmark" : "gearshape")
       .font(.system(size: 11, weight: .medium))
       .foregroundColor(.white.opacity(0.4))

      // 有未看过的更新：用形状（向下箭头徽标）承载状态，颜色只作辅助——
      // 只靠颜色区分状态，在黑白截图与色觉障碍下都会丢信息。
      if updateManager.hasUnseenUpdate && !viewModel.isShowingSettings {
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
    // 齿轮按钮原本没有无障碍标签（统计按钮有），顺带让 "Settings" 这个键仍有落点：
    // 设置页眉改成显示当前分组名后，这里是它唯一的引用处。
    .accessibilityLabel(Text(l10n.t("Settings")))

    if showClosedActivity {
     // 计数与齿轮之间补上图标字形在悬停框里的留白，三种元素的字形间距才读得一致。
     sessionCountBadge(for: openedCountLabel)
      .padding(.leading, headerGlyphMargin)
    }
   }
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
    NotchMenuView(
     viewModel: viewModel,
     statsViewModel: usageStatsViewModel,
     balanceViewModel: balanceViewModel
    )
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
  guard !AppSettings.notificationSoundChoice.isSilent else { return }
  Task {
   guard await shouldPlayNotificationSound(for: sessions) else { return }
   await MainActor.run {
    // 音量与安静时段都在播放器里收口：命中安静时段时这里什么都不做。
    // `play` 的返回值只给单测/排查用，这里显式丢弃，避免 `MainActor.run` 返回它。
    _ = NotificationSoundPlayer.play(AppSettings.notificationSoundChoice)
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
