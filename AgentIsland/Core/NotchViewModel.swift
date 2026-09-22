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
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
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
    ///
    /// 顺带记住上一次待过的**非统计**分组：统计分组是「看数据」的页，用户从它用齿轮
    /// 回到设置时应当回到原来的位置（见 `toggleMenu()`）。
    @Published var menuSection: NotchMenuSection = .general {
        didSet {
            if menuSection != .statistics { lastSettingsSection = menuSection }
        }
    }

    /// 上一次待过的非统计分组（`menuSection` 的 didSet 维护）。
    private var lastSettingsSection: NotchMenuSection = .general
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
                width: scaledPanelWidth(min(screenRect.width * 0.4, NotchMenuMetrics.panelWidthMax)),
                height: NotchMenuMetrics.panelHeight(
                    for: menuSection,
                    expandedPickerHeight: expandedPickerHeight(for: menuSection),
                    chromeHeight: panelChromeHeight
                )
            )
        case .instances:
            return CGSize(
                width: scaledPanelWidth(min(screenRect.width * 0.4, NotchMenuMetrics.panelWidthMax)),
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
            // 通用页有六个可展开的选择器：语言、屏幕、胶囊高度、胶囊宽度、内容字号、面板尺寸。
            // 音效不在这里——它已归到行为页的「通知」组（见 NotchMenuPages）。
            return languageSelector.expandedPickerHeight
                + screenSelector.expandedPickerHeight
                + heightSelector.expandedPickerHeight
                + widthSelector.expandedPickerHeight
                + textSizeSelector.expandedPickerHeight
                + PanelSizeSelector.shared.expandedPickerHeight
        case .behavior:
            // 行为页的选择器都是同一个骨架，逐个累加各自的展开高度。
            // 通知音效那一行也在这里（4 档可见，超出的在选项列表里滚动）。
            return [
                HoverExpandSelector.shared.expandedPickerHeight,
                IdleNotchVisibilitySelector.shared.expandedPickerHeight,
                CompletionBadgeSelector.shared.expandedPickerHeight,
                SoundSelector.shared.expandedPickerHeight,
                SessionRetentionSelector.shared.expandedPickerHeight,
                SessionRowDensitySelector.shared.expandedPickerHeight,
                SessionRowClickActionSelector.shared.expandedPickerHeight,
                RefreshCadenceSelector.shared.expandedPickerHeight,
                NotificationScopeSelector.shared.expandedPickerHeight,
            ].reduce(0, +)
        case .agents:
            // 智能体页有四个可展开的行：三个闸门档位（问什么 / 应用未运行时 /
            // 待批时自动展开）与 Claude 配置目录。
            return claudeDirSelector.expandedPickerHeight
                + ApprovalDegradationSelector.shared.expandedPickerHeight
                + ApprovalAskScopeSelector.shared.expandedPickerHeight
                + ApprovalAutoExpandSelector.shared.expandedPickerHeight
        case .statistics:
            // 统计页的时间范围控件在设置页的页眉行里（见 `StatsRangePicker`）：它的展开块
            // 是插在分段条与滚动区之间的固定块，挤占页内滚动视口而不撑高面板，因此增量是 0。
            return 0
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
        // 「待批时自动展开」与「问什么」也跟着「智能体」页的高度走：它们在那一页展开时
        // 同样要撑高面板。
        observe(PanelSizeSelector.shared)
        observe(HoverExpandSelector.shared)
        observe(IdleNotchVisibilitySelector.shared)
        observe(CompletionBadgeSelector.shared)
        observe(SessionRetentionSelector.shared)
        observe(SessionRowDensitySelector.shared)
        observe(RefreshCadenceSelector.shared)
        observe(NotificationScopeSelector.shared)
        observe(SessionRowClickActionSelector.shared)
        // 参与「智能体」页高度的每一行都必须在这里订阅：面板内的点击不会走
        // handleMouseDown（落在面板内直接 return），漏订阅就等于「展开不撑高面板，
        // 选项被面板下边缘裁掉」。新增可展开行时，这里与 expandedPickerHeight(for:)
        // 必须同时改。
        observe(ApprovalAskScopeSelector.shared)
        observe(ApprovalDegradationSelector.shared)
        observe(ApprovalAutoExpandSelector.shared)
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
        handleMouseDown(at: NSEvent.mouseLocation)
    }

    /// 一次鼠标按下（位置可注入，便于单测）。
    ///
    /// 面板**内部**的点击一律不在这里处理，交给 SwiftUI 自己分派（见 `NotchView` 头部
    /// 条带上的手势）。原因：这里的判定带是**关闭态胶囊**矩形（`notchScreenRect`），
    /// 而「点胶囊收起」这个手势会连头部条带上的按钮一起吃掉——用户把胶囊调宽到 300pt
    /// 后，统计按钮（命中区 [1089, 1111]）整个落进带里（带右边缘 1110），点击被抢走，
    /// 灵动岛收起而不是切页；再宽一点设置按钮与设置页的返回箭头也会中招。
    func handleMouseDown(at location: CGPoint) {
        switch status {
        case .opened:
            guard geometry.isPointOutsidePanel(location, size: openedSize) else { return }
            notchClose()
            // Re-post the click so it reaches the window/app behind us
            repostClickAt(location)
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // 测试宿主里不派发合成点击：单测会在没有真实点击的情况下走这条路径，
        // 否则会真的点到用户当前的屏幕上。
        guard !AppEnvironment.isRunningTests else { return }

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

    // MARK: - 内容面的入口

    /// 内容面就是统计页（设置面板的统计分组）。头部图表按钮据此显示 xmark。
    var isShowingStatistics: Bool {
        contentType == .menu && menuSection == .statistics
    }

    /// 内容面在设置面板里、且不在统计分组。头部齿轮按钮据此显示 xmark——
    /// 它与 `isShowingStatistics` 正好把「在设置里」分完，两个按钮不会同时显示 xmark。
    var isShowingSettings: Bool {
        contentType == .menu && menuSection != .statistics
    }

    /// 图表按钮：进统计页；已经在统计页时退回会话列表。
    func toggleStatistics() {
        if isShowingStatistics {
            exitMenu()
        } else {
            contentType = .menu
            menuSection = .statistics
        }
    }

    /// 齿轮按钮：进设置面板；已经在设置里时退回会话列表；在统计分组或从统计页回来时，
    /// 回到上一次待过的设置分组，而不是从「通用」重来。
    func toggleMenu() {
        if isShowingSettings {
            exitMenu()
        } else {
            contentType = .menu
            if menuSection == .statistics {
                menuSection = lastSettingsSection
            }
        }
    }

    /// 离开设置面板回到会话列表（设置页页眉的返回箭头与两个按钮的 xmark 共用）。
    func exitMenu() {
        contentType = .instances
    }

    /// 点面板的头部条带（面板的「标题栏」）：收起面板。
    ///
    /// 这条手势挂在头部条带上而不是鼠标监听里：按钮自己会吃掉点击，因此不必再知道
    /// 「按钮在哪」——用几何去算按钮范围正是上一版的缺陷来源（见 `handleMouseDown`）。
    func collapseFromHeaderTap() {
        guard Self.collapsesOnHeaderTap(status: status, contentType: contentType) else { return }
        notchClose()
    }

    /// 点头部条带要不要收起面板（纯函数，便于单测）：展开中，且不在聊天面——
    /// 聊天是粘性的，读到一半不该被头部误关（点面板外面仍然会收起）。
    static func collapsesOnHeaderTap(status: NotchStatus, contentType: NotchContentType) -> Bool {
        guard status == .opened else { return false }
        if case .chat = contentType { return false }
        return true
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
