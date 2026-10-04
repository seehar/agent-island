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
    /// 全局热键唤出。语义与 `.unknown` 相同（不是通知触发的展开，因此会
    /// 恢复上次的对话面）。
    case hotkey
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

/// 面板状态的快照。
///
/// 屏幕参数变化（改分辨率、换主屏、插拔显示器）时窗口会重建，而用户此刻可能正开着面板
/// 在读东西。重建前把状态取走、装到新窗口上：展开的那一面（会话列表 / 某个设置分组 /
/// 某条对话）与「收起后回到上次那条对话」的粘性都不该因为一次显示设置变化而丢掉。
struct NotchPanelState {
    let status: NotchStatus
    let openReason: NotchOpenReason
    let contentType: NotchContentType
    /// 设置面板当前分组：`.menu` 面靠它决定停在通用页还是统计/额度/智能体页。
    let menuSection: NotchMenuSection
    /// 「收起后下次点开回到哪条对话」的那条会话（`contentType` 为 `.instances` 时也保留）。
    let chatSession: SessionState?
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed {
        didSet {
            // 状态换了 = 指针兴趣区换了（关闭 / popping 态是胶囊、展开态是卡片），重写一次。
            // 写在 didSet 里：读到的是新状态下的矩形（见 `updatePointerInterest`）。
            guard oldValue != status else { return }
            updatePointerInterest()
        }
    }
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances {
        didSet {
            // 离开设置面（收起面板 / 回会话列表 / 进对话）就收起展开的选择器浮层：浮层的
            // 主人是那一行，行随页面卸载；状态留着会让下次进来凭空冒出一张没有主语的列表。
            // 放在状态拥有者这里、而不是视图的 onChange 上：面板收起时设置面板整块被卸载，
            // 视图收不到那一次变化。
            if oldValue == .menu, contentType != .menu {
                PickerExpansion.collapseCurrent()
            }
            // 内容面换了 = `openedSize` 换了（会话列表 / 设置面板 / 对话三种尺寸不同）
            // ⇒ 卡片矩形跟着变。
            updatePointerInterest()
        }
    }
    /// 设置面板当前所在的分组。设置项按分组分页，面板只按当前分组撑高。
    ///
    /// 顺带记住上一次待过的**设置页**分组：统计与额度不是设置分组（是「看数据」与
    /// 「看额度」的页），用户从它们用齿轮回到设置时应当回到原来的位置（见 `toggleMenu()`）。
    @Published var menuSection: NotchMenuSection = .general {
        didSet {
            guard oldValue != menuSection else { return }
            if menuSection != .statistics && menuSection != .quota {
                lastSettingsSection = menuSection
            }
            // 换页也收起浮层：上一页那一行已经卸载，它的列表不该跟着新页面出现。
            PickerExpansion.collapseCurrent()
            // 分组换了 = 设置面板的高度换了（面板按当前分组的行数撑高）⇒ 卡片矩形跟着变。
            updatePointerInterest()
        }
    }

    /// 上一次待过的分段页分组（`menuSection` 的 didSet 维护）。
    private var lastSettingsSection: NotchMenuSection = .general
    /// 指针是否停在刘海/胶囊上（悬停展开的判据）。
    ///
    /// **不发布**：全仓没有读者（视图有自己的 `@State`，悬停展开只在这里的定时器里用），
    /// 而 `@Published` 会让每一次悬停进出都重排整棵面板树。
    var isHovering: Bool = false

    /// 会话列表的键盘选中项（快捷键导航写它，行高亮与滚动读它）。
    /// 选中的会话消失后不必清理：读的时候找不到就回落第一行。
    @Published var selectedSessionKey: SessionKey?

    /// 列表**当前显示**的会话（顺序即显示顺序），由 `ClaudeInstancesView`
    /// 渲染时写回。快捷键的上下移动与「打开对话 / 聚焦终端」按它定位——列表
    /// 口径（保留窗口、隐藏闲置等）因此只有一处实现。
    @Published private(set) var visibleSessionKeys: [SessionKey] = []

    /// 写回可见列表（顺序即显示顺序）。
    func updateVisibleSessions(_ keys: [SessionKey]) {
        guard keys != visibleSessionKeys else { return }
        visibleSessionKeys = keys
    }

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
        // 它进 `panelChromeHeight`（设置面板的高度）也决定关闭态胶囊的摆位，两个兴趣区
        // 都可能跟着变（见 `updatePointerInterest`）。
        updatePointerInterest()
    }

    /// 关闭态胶囊**画出来的**尺寸，由视图在布局变化时发布（见 `updateClosedCapsuleSize`）。
    @Published private(set) var closedCapsuleSize: CGSize

    /// 发布关闭态胶囊尺寸。
    ///
    /// **不变量：这个尺寸必须是当前真正画出来的那一块**——悬停展开、点击展开与点击转投
    /// 都按它判，画出来的与判据一旦分家，就会出现「看得见的胶囊点上去没反应」或
    /// 「空处也在收点击」。因此它由视图按 `NotchClosedMetrics.capsuleSize` 算出后写回，
    /// 而不是在这里另推一套（耳宽只有视图知道：它来自计数文案的实测宽度）。
    func updateClosedCapsuleSize(_ size: CGSize) {
        guard size != closedCapsuleSize else { return }
        closedCapsuleSize = size
        // 关闭态的兴趣区就是这个胶囊，而胶囊宽度跟着计数文案走、随时会变。
        updatePointerInterest()
    }

    /// 关闭态胶囊**矩形**（屏幕坐标）。命中判定与指针兴趣区共用这一份几何，不各算一套。
    private var closedCapsuleScreenRect: CGRect {
        geometry.closedCapsuleScreenRect(for: closedCapsuleSize)
    }

    /// 关闭态胶囊的命中判据（屏幕坐标）。见 `closedCapsuleSize` 的不变量。
    func isPointInClosedCapsule(_ point: CGPoint) -> Bool {
        closedCapsuleScreenRect.contains(point)
    }

    /// 卡片**画出来的那一块**：视图的 `NotchCard` 按它定死 frame，命中判定、点卡片外收起与
    /// 点击转投也全部取它——三处共用同一个数，才不会出现「看得见却点不到」的死边。
    ///
    /// 关闭态由视图发布（`closedCapsuleSize`，耳宽只有视图知道）；展开态是解析式的：
    /// 面板宽度预算之外左右各再留一圈头部内边距（`NotchMenuMetrics.panelCardHeaderInset`）。
    var cardSize: CGSize {
        guard status == .opened else { return closedCapsuleSize }
        return CGSize(
            width: openedSize.width + 2 * NotchMenuMetrics.panelCardHeaderInset,
            height: openedSize.height
        )
    }

    /// 展开态卡片**矩形**（屏幕坐标）。命中判定与指针兴趣区共用这一份几何。
    private var openedCardScreenRect: CGRect {
        geometry.openedScreenRect(for: cardSize)
    }

    /// 展开态卡片的命中判据（屏幕坐标）。见 `cardSize` 的不变量。
    func isPointInCard(_ point: CGPoint) -> Bool {
        guard status == .opened else { return false }
        return openedCardScreenRect.contains(point)
    }

    /// 指针兴趣区：关闭 / popping 态是关闭态胶囊、展开态是卡片——与
    /// `isPointInClosedCapsule` / `isPointInCard` **取同一份矩形**（两处一旦各算一套，
    /// 事件层的边界判据与行为判据就会互相错位：看得见的胶囊收不到悬停，或空处也在收
    /// 边界事件）。事件层据此把位置流压成边界事件（见 `EventMonitors.interestRect`）。
    private var pointerInterestRect: CGRect {
        status == .opened ? openedCardScreenRect : closedCapsuleScreenRect
    }

    /// 把当前兴趣区写给事件层（幂等：值没变不写）。
    ///
    /// 凡是会动上面这两个矩形的地方都要写一次：状态、内容面、设置分组、设备胶囊矩形、
    /// 关闭态胶囊尺寸，以及进 `openedSize` 的尺寸类选择器（面板尺寸档位、智能体页目录
    /// 编辑器、额度页账号列表）。漏写一处，兴趣区就停在旧矩形上——面板长到指针底下时
    /// 那一段既不收悬停也不收鼠标事件。
    private func updatePointerInterest() {
        let rect = pointerInterestRect
        guard events.interestRect != rect else { return }
        events.interestRect = rect
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
                width: scaledPanelWidth(
                    min(screenRect.width * 0.4, NotchMenuMetrics.panelWidthMax)),
                height: NotchMenuMetrics.panelHeight(
                    for: menuSection,
                    expandedPickerHeight: expandedPickerHeight(for: menuSection),
                    chromeHeight: panelChromeHeight
                )
            )
        case .instances:
            return CGSize(
                width: scaledPanelWidth(
                    min(screenRect.width * 0.4, NotchMenuMetrics.panelWidthMax)),
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

    /// 当前分组里**就地展开**的内容带来的额外高度。
    ///
    /// 只有两类内容还留在这一项：额度页的凭据表单与智能体页的行内目录编辑器（它们是编辑器，
    /// 就地展开才看得清在改谁），以及智能体页的三个工具调用保护档位。
    /// **所有的值选择器都改成浮层展示、恒为 0**（见 `SettingsPickerOverlay`）：那批曾让通用页
    /// （480 + 138）与智能体页（530 + 106）在展开时越过 640 的设置上限、把最后一个档位切到
    /// 隐藏滚动条的视口外。
    /// 只有该分组自己的展开算数，其它分组留着的展开态不会把面板撑高。
    private func expandedPickerHeight(for section: NotchMenuSection) -> CGFloat {
        switch section {
        case .general:
            // 通用页的六个选择器（语言、屏幕、胶囊高度/宽度、内容字号、面板尺寸）都是浮层展示。
            return 0
        case .behavior:
            // 行为页的六个选择器（刘海交互 + 会话列表偏好）同上。
            return 0
        case .notifications:
            // 通知页的四个选择器同上——音效列表可见 6 行（202pt），但它是浮层里自己滚动的
            // 列表，与这一页的高度无关。
            return 0
        case .agents:
            // 只剩**行内目录编辑器**（某个 Agent 的配置根）：它是编辑器、就地展开才看得清在改谁
            // （同一时刻只开一个，展开高度是单份的）。三个保护档位（问什么 / 应用未运行时 /
            // 待批自动展开）是值选择器，已改成浮层展示。
            return AgentDirSelector.shared.expandedPickerHeight
        case .shortcuts:
            // 快捷键页没有可展开的选择器：录制行是行内的按键块，不撑高面板。
            return 0
        case .animations:
            // 标记动态页没有可展开的选择器：状态选择是行内的分段控件，不撑高面板。
            return 0
        case .statistics:
            // 统计页的时间范围控件在设置页的页眉行里（见 `StatsRangePicker`）：它的展开块
            // 是插在页眉与滚动区之间的固定块，挤占页内滚动视口而不撑高面板，因此增量是 0。
            return 0
        case .quota:
            // 额度页的运行时增量有两段：账号列表窗口（行数 = min(账号数, 上限)）与
            // 「编辑凭据」态（列表折叠成一行、详情卡换成凭据表单）；两者互不叠加，
            // 由 `NewAPIAccountPageState` 算成一个数。刷新控件在页眉行里（同统计页）。
            return NewAPIAccountPageState.shared.runtimeHeight
        case .about:
            return 0
        }
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool)
    {
        self.deviceNotchRect = deviceNotchRect
        self.screenRect = screenRect
        self.windowHeight = windowHeight
        self.hasPhysicalNotch = hasPhysicalNotch
        // 关闭态胶囊尺寸先用「最小耳宽 + 空胶囊」形态铺底：视图第一次布局之前就来悬停时
        // 判据不能是 .zero（那段时间会整段漏判）。同一个纯函数，视图随后按真实计数文案覆盖。
        self.closedCapsuleSize = NotchClosedMetrics.capsuleSize(
            notchSize: deviceNotchRect.size,
            earWidth: NotchClosedMetrics.minimumEarWidth(notchHeight: deviceNotchRect.height),
            showsEars: false)
        setupEventHandlers()
        // 视图发布真实胶囊尺寸之前也要有一个兴趣区：先用上面这份铺底几何，否则那段时间
        // 事件层没有边界，悬停展开整段失效（放在订阅之后：指针正停在胶囊上时这一次发布
        // 要能被订阅者收到）。
        updatePointerInterest()
        observeSelectors()
    }

    /// 让「会改变面板尺寸」的选择器在变化时重发布。
    ///
    /// **值选择器不在这里**：它们的展开态画在浮层里、不参与面板高度（见 `SettingsPickerOverlay`），
    /// 取值本身由各自的行与视图订阅（`@ObservedObject`），因此不欠这份重发布。留下来的三类
    /// 都有实打实的理由：
    /// - `PanelSizeSelector`：面板宽度按它的档位缩放（`openedSize.width`）；
    /// - 智能体页的行内目录编辑器、额度页的账号与「编辑凭据」态：就地展开，算进面板高度。
    ///
    /// 这三个来源同时是「指针兴趣区」的来源（都进 `openedSize`），因此除了重发布，还要各挂
    /// 一条把新尺寸写给事件层的订阅（看方法末尾）。
    private func observeSelectors() {
        observe(PanelSizeSelector.shared)

        AgentDirSelector.shared.$expandedKind
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NewAPIAccountPageState.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 同一批来源再挂一条「重算兴趣区」的订阅：它们的通知都是**变更前**发出的
        // （`objectWillChange` 与 `@Published` 的 `$x` 都是 willSet 语义），当场重算读到的
        // 还是旧尺寸，`receive(on:)` 把这一跳推到值落定之后。三个来源都进 `openedSize`：
        // 面板尺寸档位管宽，智能体页目录编辑器与额度页账号列表管高——兴趣区不跟着走，
        // 面板长到指针底下时那一段就不收鼠标事件（看得见却点不到）。
        PanelSizeSelector.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePointerInterest() }
            .store(in: &cancellables)
        AgentDirSelector.shared.$expandedKind
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePointerInterest() }
            .store(in: &cancellables)
        NewAPIAccountPageState.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePointerInterest() }
            .store(in: &cancellables)
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
        // 两个状态的判据都取「画出来的那一块」：关闭态是视图发布的胶囊尺寸，展开态是
        // `cardSize`（见 `NotchGeometry` 与 `closedCapsuleSize` 的不变量）。
        let inClosedCapsule = isPointInClosedCapsule(location)
        let inOpened = isPointInCard(location)

        let newHovering = inClosedCapsule || inOpened

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
    /// 条带上的手势）。原因：这里的判定带是**关闭态胶囊**那一块（`closedCapsuleSize`），
    /// 而「点胶囊收起」这个手势会连头部条带上的按钮一起吃掉——用户把胶囊调宽到 300pt
    /// 后，统计按钮（命中区 [1089, 1111]）整个落进带里（带右边缘 1110），点击被抢走，
    /// 灵动岛收起而不是切页；再宽一点设置按钮与设置页的返回箭头也会中招。
    ///
    /// 这里**不转投**点击：这一下有没有被面板窗口吞掉只有窗口自己知道，转投统一由
    /// `NotchPanel.sendEvent` 做。这里再投一次的话，屏幕下半部（不在窗口覆盖范围内、
    /// 系统本来就已经把点击交给了下层应用）会变成双击。
    ///
    /// 左键与右键走同一个入口：右键在卡片外同样要能收起面板（左键收起、右键不收起的话，
    /// 面板会停在「看着还在、窗口其实已经让开」的状态），在胶囊上则与左键同义（展开）。
    func handleMouseDown(at location: CGPoint) {
        switch status {
        case .opened:
            guard geometry.isPointOutsidePanel(location, size: cardSize) else { return }
            notchClose()
        case .closed, .popping:
            if isPointInClosedCapsule(location) {
                notchOpen(reason: .click)
            }
        }
    }

    // MARK: - 面板点击转投的接口

    /// 屏幕坐标点是否落在**此刻展开的**面板卡片里（面板窗口的转投判据）。
    ///
    /// 与 `handleMouseDown(at:)` 的收起判据是同一个矩形：`NotchGeometry` 里
    /// `isPointInOpenedPanel` 与 `isPointOutsidePanel` 互为补集，两处都按当前的
    /// `geometry` + `openedSize` 现算、不缓存，因此不会出现「窗口判卡片外、这里判面板内」。
    /// 这一处也走 `openedCardScreenRect`（与命中判据、指针兴趣区同一份矩形）。
    ///
    /// 还要合取 `status == .opened`：收起之后 `openedSize` 仍是上一次的展开尺寸，只看矩形
    /// 会把屏顶中央那一片都算成「卡片内」。窗口在关闭态本不该接收事件，但状态机里存在把它
    /// 留在接收态的短态（`AgentSettingsSection` 的 `withNotchPanelYielded` 结束时写回陈旧
    /// 快照），那时按矩形判会让用户点在其他应用内容上的点击被静默吞掉。
    func isScreenPointInPanel(_ point: CGPoint) -> Bool {
        guard status == .opened else { return false }
        return openedCardScreenRect.contains(point)
    }

    /// 面板把一次「卡片外、被窗口吞掉」的点击转投给下层应用之后收起自己（幂等）。
    ///
    /// 为什么不能只靠鼠标监听：监听掩码只有 `.leftMouseDown`，**右键**转投不会触发
    /// `handleMouseDown`，面板就会停在「看着还在、其实窗口已经让开」的状态（点不动，
    /// 点击还会穿过去）。收起因此挂在转投那条路径上。
    func collapseForForwardedClick() {
        guard status == .opened else { return }
        notchClose()
    }

    // MARK: - 状态接续（屏幕参数变化重建窗口）

    /// 当前状态快照：窗口管理器在销毁旧窗口**之前**取走，装到新窗口上（见 `NotchPanelState`）。
    var panelState: NotchPanelState {
        NotchPanelState(
            status: status,
            openReason: openReason,
            contentType: contentType,
            menuSection: menuSection,
            chatSession: currentChatSession)
    }

    /// 把一份状态快照装回来。`status` 最后写：状态订阅随后看到的是这一份完整的快照。
    ///
    /// 刻意**不**在这里抢键盘焦点：状态变化时用户多半正在系统设置里改显示参数，
    /// 抢走键盘会打断他；焦点该不该拿仍由 `takesKeyboardFocusOnOpen` 那套规则管，
    /// 窗口控制器在接续这一跳里会跳过它。
    func restorePanelState(_ state: NotchPanelState) {
        openReason = state.openReason
        contentType = state.contentType
        menuSection = state.menuSection
        currentChatSession = state.chatSession
        status = state.status
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead.
        // 只「这次不恢复」：以前顺手把 `currentChatSession` 清成 nil，通知展开一次就把用户
        // 正在读的对话永久弄丢了（作答/收起后再点开刘海回到会话列表，位置没了）。
        if reason == .notification {
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
        // 面板被收起过一次 = 用户已经见过它，首次启动的引导到此结束。
        // 只在「还待做」时写一次：收起是热路径（点一下面板外就走到这），不必每次都落盘。
        if AppSettings.firstRunIntroPending {
            AppSettings.firstRunIntroPending = false
        }

        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    /// 展开时是否把键盘焦点抢到面板上（窗口层据此决定 `NSApp.activate` + `makeKey`）。
    ///
    /// 只有**用户主动唤出**才算：点击胶囊、或全局热键。悬停展开（默认 1s，鼠标只是路过
    /// 而已）、启动动画、通知触发的展开都是「用户没点任何东西」时发生的 —— 抢焦点会让他
    /// 在编辑器/终端里正在打的字丢进面板（面板里当时没有聚焦的输入框，字直接没了）。
    /// 「到底要不要抢焦点」这个总开关在通用页（`AppSettings.panelTakesFocus`）。
    ///
    /// 已知取舍：面板内的键盘快捷键要求 `panel.isKeyWindow && NSApp.isActive`
    /// （见 `ShortcutController`），因此**悬停展开的面板只能用鼠标操作**——与通知触发的
    /// 展开一直如此（那条路径改动前也不抢焦点），不是本批新增的例外。要面板接管键盘：
    /// 用全局热键唤出，或点一下面板。反过来「鼠标只是路过就抢走键盘」的代价更大（用户
    /// 正在编辑器/终端里打的字会丢进面板，而面板里当时没有聚焦的输入框）。
    var takesKeyboardFocusOnOpen: Bool {
        openReason == .click || openReason == .hotkey
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

    /// 内容面就是额度页（设置面板的额度分组）。头部额度按钮据此显示 xmark。
    var isShowingQuota: Bool {
        contentType == .menu && menuSection == .quota
    }

    /// 内容面在设置面板里、且不在统计与额度分组。头部齿轮按钮据此显示 xmark——
    /// 它与 `isShowingStatistics`、`isShowingQuota` 正好把「在设置里」分完，
    /// 三个按钮任何时刻最多一个显示 xmark。
    /// 判据与「这个面显不显示侧栏」同源（`NotchMenuSection.isDashboard`）：读数面
    /// 不显示侧栏、也不点亮齿轮。
    var isShowingSettings: Bool {
        contentType == .menu && !NotchMenuSection.isDashboard(menuSection)
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

    /// 额度按钮：进额度页；已经在额度页时退回会话列表（与图表按钮同构）。
    func toggleQuota() {
        if isShowingQuota {
            exitMenu()
        } else {
            contentType = .menu
            menuSection = .quota
        }
    }

    /// 齿轮按钮：进设置面板；已经在设置里时退回会话列表；在统计 / 额度分组或从它们回来时，
    /// 回到上一次待过的设置分组，而不是从「通用」重来。
    func toggleMenu() {
        if isShowingSettings {
            exitMenu()
        } else {
            contentType = .menu
            if menuSection == .statistics || menuSection == .quota {
                menuSection = lastSettingsSection
            }
        }
    }

    /// 直接跳到「智能体」页。空态里那枚按钮用它——Agent 默认关闭之后，
    /// 「没有会话」最常见的成因就是「一个都没启用」，得给出唯一那步动作。
    func openAgentsSettings() {
        contentType = .menu
        menuSection = .agents
    }

    /// 直接跳到「快捷键」页。关于页那一行入口用它（快捷键页不占侧栏位，
    /// 没有其它常驻入口）。
    func openShortcutsSettings() {
        contentType = .menu
        menuSection = .shortcuts
    }

    /// 直接跳到「标记动态」页。「监控的智能体」卡片第一行那个入口行用它（这一页也不占侧栏位）。
    func openAnimationsSettings() {
        contentType = .menu
        menuSection = .animations
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
    ///
    /// 首次启动（还没有任何 Agent 被启用）时**不自动收起**：这次展开的就是「没有启用
    /// 任何 Agent」的空态 —— 装完只闪 1 秒空列表，用户既不知道面板在哪、也看不到
    /// 「去启用一个 Agent」那一步。用户自己收起一次就把标记清掉，之后恢复 1 秒动画。
    func performBootAnimation() {
        notchOpen(reason: .boot)

        guard
            !Self.shouldKeepBootPanelOpen(
                firstRunIntroPending: AppSettings.firstRunIntroPending,
                enabledAgentCount: AgentRegistry.enabled.count)
        else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }

    /// 启动那次展开是否要**留着不收起**：首次启动（引导还没走完）且还没有任何 Agent 被启用。
    ///
    /// 抽成纯函数是为了能单测——定时器那段在用例里跑不了，而这条判据一旦反过来（老用户
    /// 每次启动都停在展开态）是明显的体验事故。
    nonisolated static func shouldKeepBootPanelOpen(
        firstRunIntroPending: Bool, enabledAgentCount: Int
    ) -> Bool {
        firstRunIntroPending && enabledAgentCount == 0
    }
}
