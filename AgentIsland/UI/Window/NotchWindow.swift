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
nonisolated struct ClickForwarding {
    /// 把这一下（按下 + 抬起）交给下层应用。
    var deliver: @MainActor (NotchForwardedClick) -> Void
    /// 投递时机：得等窗口让开之后才投，否则这一下会被本窗口再吞一次。
    var schedule: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// 此刻该不该接收鼠标事件（= 面板还开着）。转投之后窗口靠它恢复成该有的样子。
    var shouldAcceptMouseEvents: @MainActor () -> Bool

    /// 未装配的面板：不投递。用例里构造的面板走这条，因此不会点到用户的屏幕上。
    static let disabled = ClickForwarding(
        deliver: { _ in },
        schedule: { $0() },
        shouldAcceptMouseEvents: { true })

    /// 生产实现。
    ///
    /// - Parameter shouldAcceptMouseEvents: 由窗口控制器接上「面板是否展开」。
    static func live(shouldAcceptMouseEvents: @escaping @MainActor () -> Bool) -> ClickForwarding {
        ClickForwarding(
            deliver: ClickForwarding.post,
            schedule: { body in
                // `DispatchQueue` 的闭包要求 `@Sendable`（主 actor 隔离的闭包本身就是），
                // 这里把它落回主 actor 再调用——异步派发到主队列正是这个前提。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    MainActor.assumeIsolated { body() }
                }
            },
            shouldAcceptMouseEvents: shouldAcceptMouseEvents)
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

    /// 支持转投的按键；其它按键（中键等）保持原样：不认领也不转投。
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

    /// 点击转投的接缝（见 `ClickForwarding`）。默认 `.disabled` 不投递：只有窗口控制器
    /// 装配过的面板才会真的往屏幕投合成事件。
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

    /// 这次事件要不要转投：鼠标按下、且没有任何视图认领它（`hitTest` 为 nil）。
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
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NotchForwardedClick(
            quartzLocation: CGPoint(
                x: screenLocation.x, y: primaryHeight - screenLocation.y),
            button: button,
            clickCount: max(1, event.clickCount))
    }

    /// 转投这一下：先把本窗口放开鼠标（合成事件按「此刻谁在最上面」重新命中，窗口还接着
    /// 鼠标的话这一下会被自己再吞一次），投完按开合状态恢复——面板还开着就继续接事件，
    /// 否则透明会一直留到下一次状态切换（面板此后点不动）。
    private func forward(_ click: NotchForwardedClick) {
        ignoresMouseEvents = true
        forwarding.schedule { [weak self] in
            guard let self else { return }
            self.forwarding.deliver(click)
            if self.forwarding.shouldAcceptMouseEvents() {
                self.ignoresMouseEvents = false
            }
        }
    }
}
