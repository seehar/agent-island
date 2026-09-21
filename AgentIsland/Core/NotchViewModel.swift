//
//  NotchViewModel.swift
//  AgentIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    /// 用量统计页。
    case stats
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .stats: return "stats"
        case .chat(let session): return "chat-\(session.sessionKey.rawValue)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    /// 设置面板当前所在的分组。设置项按分组分页，面板只按当前分组撑高。
    @Published var menuSection: NotchMenuSection = .general
    @Published var isHovering: Bool = false

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let claudeDirSelector = ClaudeDirSelector.shared
    private let languageSelector = LanguageSelector.shared
    private let heightSelector = NotchHeightSelector.shared
    private let widthSelector = NotchWidthSelector.shared
    private let textSizeSelector = TextSizeSelector.shared

    // MARK: - Geometry

    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    /// 窗口覆盖的屏幕区域（整块屏幕的 frame）。
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// 关闭态胶囊的矩形。屏幕或高度设置变化时由 NotchWindowController 更新，
    /// 关闭态尺寸、命中区与面板的固定开销都从它派生，所以换高度不必重建窗口。
    @Published private(set) var deviceNotchRect: CGRect

    /// 命中区与面板位置用的几何，由 `deviceNotchRect` 与屏幕尺寸推导。
    var geometry: NotchGeometry {
        NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
    }

    /// 换一个关闭态胶囊矩形（宽度跟着屏幕走，高度跟着高度设置走）。
    func updateDeviceNotchRect(_ rect: CGRect) {
        deviceNotchRect = rect
    }

    /// Dynamic opened size based on content type
    ///
    /// 尺寸取基准值乘「面板尺寸」档位的比例；宽度不越过屏幕，高度不越过窗口。
    /// 设置面板的高度例外：它由 `NotchMenuMetrics` 的解析式给出，缩放会裁掉内容，
    /// 因此那一档只影响面板宽度（宽度与行高无关，解析式仍然成立）。
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: scaledPanelWidth(min(screenRect.width * 0.5, 600)),
                height: scaledPanelHeight(580)
            )
        case .menu:
            // 只按当前分组算高度：固定开销 + 该分组的设置行 + 该分组里展开的
            // 选择器增量（见 NotchMenuMetrics）。分组越短，面板越矮。
            return CGSize(
                width: scaledPanelWidth(min(screenRect.width * 0.4, 480)),
                height: NotchMenuMetrics.panelHeight(
                    for: menuSection,
                    expandedPickerHeight: expandedPickerHeight(for: menuSection),
                    chromeHeight: panelChromeHeight
                )
            )
        case .stats:
            // 统计页高度固定：窗口高 750 是这个内容面的硬顶（设置面板的 maxPanelHeight
            // 夹取只作用于 .menu），内容超出由页内滚动接管（见 UsageStatsMetrics）。
            return CGSize(
                width: min(screenRect.width * 0.4, UsageStatsMetrics.panelWidthMax),
                height: UsageStatsMetrics.panelHeight
            )
        case .instances:
            return CGSize(
                width: scaledPanelWidth(min(screenRect.width * 0.4, 480)),
                height: scaledPanelHeight(320)
            )
        }
    }

    /// 按「面板尺寸」档位缩放面板宽度，并留出屏幕边缘。
    private func scaledPanelWidth(_ base: CGFloat) -> CGFloat {
        min(base * PanelSizeSelector.shared.option.scale, screenRect.width - 40)
    }

    /// 按「面板尺寸」档位缩放面板高度，并留出窗口顶部与底部。
    private func scaledPanelHeight(_ base: CGFloat) -> CGFloat {
        min(base * PanelSizeSelector.shared.option.scale, windowHeight - 20)
    }

    /// 面板中菜单之外的固定高度：头部行（物理刘海高度，非刘海屏至少 24）
    /// 加上 NotchView 给面板留的 12pt 底部内边距。
    private var panelChromeHeight: CGFloat {
        max(24, deviceNotchRect.height) + 12
    }

    /// 当前分组里展开的选择器带来的额外高度。只有该分组自己的选择器算数，
    /// 其它分组留着的展开态不会把面板撑高。
    private func expandedPickerHeight(for section: NotchMenuSection) -> CGFloat {
        switch section {
        case .general:
            // 通用页有六个可展开的选择器：语言、屏幕、胶囊高度、胶囊宽度、内容字号、通知音效。
            return languageSelector.expandedPickerHeight
                + screenSelector.expandedPickerHeight
                + heightSelector.expandedPickerHeight
                + widthSelector.expandedPickerHeight
                + textSizeSelector.expandedPickerHeight
                + soundSelector.expandedPickerHeight
        case .behavior:
            // 行为页的选择器都是同一个骨架，逐个累加各自的展开高度
            return [
                HoverExpandSelector.shared.expandedPickerHeight,
                IdleNotchVisibilitySelector.shared.expandedPickerHeight,
                CompletionBadgeSelector.shared.expandedPickerHeight,
                PanelSizeSelector.shared.expandedPickerHeight,
                SessionRetentionSelector.shared.expandedPickerHeight,
                SessionRowDensitySelector.shared.expandedPickerHeight,
                SessionRowClickActionSelector.shared.expandedPickerHeight,
                RefreshCadenceSelector.shared.expandedPickerHeight,
                NotificationScopeSelector.shared.expandedPickerHeight,
            ].reduce(0, +)
        case .agents:
            // 智能体页有两个可展开的选择器：Claude 配置目录、审批降级档
            return claudeDirSelector.expandedPickerHeight
                + ApprovalDegradationSelector.shared.expandedPickerHeight
        case .about:
            return 0
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.deviceNotchRect = deviceNotchRect
        self.screenRect = screenRect
        self.windowHeight = windowHeight
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        claudeDirSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        languageSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        heightSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 字号与宽度选择器也要订阅：它们的展开态同样算进面板高度
        textSizeSelector.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        widthSelector.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 行为类偏好：展开态影响面板高度，取值影响面板尺寸等派生值，
        // 因此统一按「任一变化即重发布」订阅。
        observe(PanelSizeSelector.shared)
        observe(HoverExpandSelector.shared)
        observe(IdleNotchVisibilitySelector.shared)
        observe(CompletionBadgeSelector.shared)
        observe(SessionRetentionSelector.shared)
        observe(SessionRowDensitySelector.shared)
        observe(RefreshCadenceSelector.shared)
        observe(NotificationScopeSelector.shared)
        observe(SessionRowClickActionSelector.shared)
    }

    /// 订阅一个枚举偏好的任何变化（取值或展开态），让读到它的视图重算。
    private func observe<P: PreferenceOption>(_ selector: EnumPreference<P>) {
        selector.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        // 悬停自动展开：延时按「悬停展开」档位；该档位为「从不」时不自动展开，
        // 点击刘海仍然可以展开（通知触发的自动展开也不受影响）。
        if isHovering, status == .closed || status == .popping,
            let delay = HoverExpandSelector.shared.option.delay
        {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isHovering else { return }
                self.notchOpen(reason: .hover)
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionKey == chatSession.sessionKey {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    /// 在会话列表与统计页之间翻转（与 `toggleMenu()` 同形，两者互不干扰：
    /// 在设置面板里点统计直接切到统计页，在统计页里点设置直接切到设置页）。
    func toggleStats() {
        contentType = contentType == .stats ? .instances : .stats
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionKey == session.sessionKey {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
