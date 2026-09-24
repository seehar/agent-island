//
//  NotchWindow.swift
//  AgentIsland
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
//

import AppKit

// MARK: - 点击转投

/// 一次被面板窗口吞掉的鼠标按下：投给下层应用所需的全部信息。
///
/// 坐标已换算到 Quartz 屏幕系（原点 = 主屏左上、y 向下）：合成事件直接用这个值，
/// 换算（含基准屏的选择）在窗口那边完成 —— `NSScreen` 是主 actor 隔离的，
/// 这个接缝本身要能被非隔离的投递代码使用。
nonisolated struct NotchForwardedClick: Equatable {
    let quartzLocation: CGPoint
    let button: CGMouseButton
    let clickCount: Int
}

/// 点击转投的接缝：生产实现（`live`）投合成事件，用例换成记录器 + 立即执行，
/// 于是「一次点击只投一次」这类不变量不必真的往屏幕上点一下就能钉住。
///
/// 判据（`isPointOnPanel`）与收起（`collapse`）也放这里：它们是同一次转投的三个面，
/// 拆开注入会出现「装了投递、没装收起」的半装配面板。
nonisolated struct ClickForwarding {
    /// 屏幕坐标点是否落在面板卡片上。**卡片外**才转投：卡片内的点击哪怕这一刻没有控件
    /// 认领（展开动画途中卡片还没长到终值，或 SwiftUI 的透明区）也该由面板自己吞下——
    /// 投出去只会让下层应用收到一次「隔着卡片」的点击，而且窗口一旦因此让开，注进来的
    /// 那一下还会被本窗口重新接住，每 50ms 一环。
    var isPointOnPanel: @MainActor (CGPoint) -> Bool
    /// 转投之后收起面板（幂等）。它是「转投出去的点击 ⟹ 面板一定收起」的**结构性**来源：
    /// 只靠鼠标监听的话，右键转投不会触发 `handleMouseDown`，窗口就会一直透明——面板
    /// 看着还在、点不动，点击还会穿过去打到下层应用。
    var collapse: @MainActor () -> Void
    /// 把这一下（按下 + 抬起）交给下层应用。
    var deliver: @MainActor (NotchForwardedClick) -> Void
    /// 投递时机：得等窗口让开之后才投，否则这一下会被本窗口再吞一次。
    var schedule: @MainActor (@escaping @MainActor () -> Void) -> Void

    /// 未装配的面板：判据按「都在卡片上」处理（最坏是卡片外点了没反应）且不投递 ——
    /// 用例里构造的面板走这条，因此不会点到用户的屏幕上，也不会成环。
    static let disabled = ClickForwarding(
        isPointOnPanel: { _ in true },
        collapse: {},
        deliver: { _ in },
        schedule: { $0() })

    /// 生产实现。
    ///
    /// - Parameters:
    ///   - isPointOnPanel: 由窗口控制器接上视图模型的几何。
    ///   - collapse: 由窗口控制器接上视图模型的收起（幂等）。
    static func live(
        isPointOnPanel: @escaping @MainActor (CGPoint) -> Bool,
        collapse: @escaping @MainActor () -> Void
    ) -> ClickForwarding {
        ClickForwarding(
            isPointOnPanel: isPointOnPanel,
            collapse: collapse,
            deliver: ClickForwarding.post,
            schedule: { body in
                // `DispatchQueue` 的闭包要求 `@Sendable`（主 actor 隔离的闭包本身就是），
                // 这里把它落回主 actor 再调用——异步派发到主队列正是这个前提。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    MainActor.assumeIsolated { body() }
                }
            })
    }

    /// 生产投递：把这一下作为合成事件投给下层应用。
    @MainActor
    static func post(_ click: NotchForwardedClick) {
        for event in makeEvents(for: click) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// 这一下要投出去的事件（按下 + 抬起）。构造与投递分开：投递只能靠真人点击取证，
    /// 而事件本身的字段（来源、`clickState`、按键、坐标）因此可以被用例钉住。
    ///
    /// 事件源取 `.hidSystemState`、`clickState` 取原始事件的 `clickCount`：本机用独立
    /// 接收端实测过——不设 `clickState` 时抬起事件的 clickCount 读出来是 0（双击的 2 也会
    /// 退化成 0），不指定事件源则来源标记不是 HID（真实点击是 HID）。
    @MainActor
    static func makeEvents(for click: NotchForwardedClick) -> [CGEvent] {
        guard let types = eventTypes(for: click.button),
            let source = CGEventSource(stateID: .hidSystemState)
        else { return [] }

        return [types.down, types.up].compactMap { type in
            guard
                let event = CGEvent(
                    mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: click.quartzLocation, mouseButton: click.button)
            else { return nil }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(click.clickCount))
            return event
        }
    }

    /// 支持转投的按键。其它按键（中键等）不转投——事件照旧交给 `NSWindow` 分派，
    /// 没人认领时仍然会被本窗口吞掉（不是「放行」）。
    nonisolated private static func eventTypes(
        for button: CGMouseButton
    ) -> (down: CGEventType, up: CGEventType)? {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        default: return nil
        }
    }
}

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // CRITICAL: Window ignores ALL mouse events
        // This allows clicks to pass through to the menu bar
        // We use global event monitors to detect hover/clicks on the notch area
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Click-through for areas outside the panel content

    /// 点击转投的接缝（见 `ClickForwarding`）：判据、收起与投递都在它里面，
    /// 默认 `.disabled` 既不投递也不判「卡片外」。只有窗口控制器装配过的面板才会真的
    /// 往屏幕投合成事件。
    var forwarding: ClickForwarding = .disabled

    /// 本窗口吞下的点击要交给下层应用。
    ///
    /// 展开态窗口盖住整屏宽、屏顶 750pt：落在面板矩形之外（或面板内没有任何控件认领）的
    /// 点击如果只是被这里吃掉，用户看到的就是「点了没反应」。
    ///
    /// 只处理**按下**，且一次点击只投这一次：抬起要么在本窗口让开之后由系统直接交给下层
    /// 应用，要么落回面板内的透明区（本来也没有视图要它）。转投**独占**在这里——鼠标监听
    /// 那条路径再投一次的话，屏幕下半部（窗口覆盖不到、系统已经把点击交给了下层应用）
    /// 会变成双击。
    override func sendEvent(_ event: NSEvent) {
        if let click = forwardedClick(for: event) {
            forward(click)
            return
        }

        super.sendEvent(event)
    }

    /// 这次事件要不要转投：鼠标按下、落在**卡片之外**、且没有任何视图认领它
    /// （`hitTest` 为 nil）。三个条件缺一不可——少了「卡片之外」，注入的点击会被让开后的
    /// 本窗口重新接住并再投一次（成环），而卡片内的点击本来就该由面板吞下。
    private func forwardedClick(for event: NSEvent) -> NotchForwardedClick? {
        let button: CGMouseButton
        switch event.type {
        case .leftMouseDown: button = .left
        case .rightMouseDown: button = .right
        default: return nil
        }

        guard let contentView, contentView.hitTest(event.locationInWindow) == nil else {
            return nil
        }

        // 窗口坐标 → 屏幕坐标 → Quartz 坐标：y 从下往上换成从上往下，基准是**主屏**
        // 高度（`NSScreen.main` 是当前有键盘焦点的屏，外接屏为主时高度不同，
        // 按它换算会把 y 投到隔壁屏上）。
        let screenLocation = convertPoint(toScreen: event.locationInWindow)
        guard !forwarding.isPointOnPanel(screenLocation) else { return nil }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NotchForwardedClick(
            quartzLocation: CGPoint(
                x: screenLocation.x, y: primaryHeight - screenLocation.y),
            button: button,
            clickCount: max(1, event.clickCount))
    }

    /// 转投这一下：先收起面板、把本窗口放开鼠标（合成事件按「此刻谁在最上面」重新命中，
    /// 窗口还接着鼠标的话这一下会被自己再吞一次），50ms 后再投。
    ///
    /// 收起挂在这条路径上（`forwarding.collapse`）而不是只靠鼠标监听：监听只掩码
    /// `.leftMouseDown`，右键转投不会触发它就收起，窗口会一直透明。
    ///
    /// 投完**不**恢复接收：能走到这里的点击都在卡片之外、且这里已同步收起，透明正是该有
    /// 的样子（`NotchWindowController` 的状态订阅随后重申同一值）；真在这儿恢复的话，
    /// 注入的点击会被重新接住并再投一次。
    private func forward(_ click: NotchForwardedClick) {
        ignoresMouseEvents = true
        forwarding.collapse()
        forwarding.schedule { [weak self] in
            self?.forwarding.deliver(click)
        }
    }
}
