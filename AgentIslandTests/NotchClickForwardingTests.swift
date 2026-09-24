//
//  NotchClickForwardingTests.swift
//  AgentIslandTests
//
//  面板点击转投：展开态窗口盖住整屏宽、屏顶 750pt，落在**面板卡片之外**的窗口带里的
//  点击（用户看到的是自己应用的内容）只有「被这个窗口吞掉」的那一次才允许投给下层应用。
//  钉住五件事——
//  ① 一次点击只投一次（鼠标监听那条路径曾经也投一次：屏幕下半部不在窗口覆盖范围内、
//  系统本来就已经把这一下交给了下层应用，于是变成双击）；
//  ② 卡片内的点击一律不投（展开动画途中「终值矩形内、渲染矩形外」的点正属于这一档），
//  也不让窗口让开——否则注入的点击会被自己重新接住，每 50ms 一环；
//  ③ 每次转投都自己收起（右键也走这条路，而鼠标监听只掩码左键）：投出去的点击 ⟹ 面板
//  收起，窗口才不会停在「看着还在、点不动、点击还穿过去」的幽灵态；
//  ④ 转投事件自身的字段（来源 HID / clickState / 按键 / 坐标）；
//  ⑤ 抬起不投。
//

import AppKit
import Testing

@testable import AgentIsland

@Suite("面板点击转投")
struct NotchClickForwardingTests {
    /// 转投记录器：接缝是非隔离闭包，用例里也只从主线程读写。
    nonisolated final class Recorder: @unchecked Sendable {
        private(set) var clicks: [NotchForwardedClick] = []
        func record(_ click: NotchForwardedClick) { clicks.append(click) }
    }

    /// 用例侧的接缝：判据按给定矩形、统计收起、记录转投，调度立即执行
    /// （用例里绝不真的往屏幕上投事件）。
    @MainActor
    final class Probe {
        /// 夹具卡片矩形；窗口在屏幕原点，因此窗口坐标即屏幕坐标。
        static let card = CGRect(x: 300, y: 100, width: 200, height: 200)

        let recorder = Recorder()
        private(set) var collapses = 0

        func seam(card: @escaping @MainActor (CGPoint) -> Bool) -> ClickForwarding {
            ClickForwarding(
                isPointOnPanel: card,
                collapse: { [weak self] in self?.collapses += 1 },
                deliver: { [recorder] click in recorder.record(click) },
                schedule: { $0() })
        }
    }

    /// 不认领点击的内容视图（`hitTest` 为 nil = 这里没有控件）。
    final class BlankContentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// 认领点击的内容视图（`hitTest` 返回自己 = 这里有控件，面板头部那排按钮就是这一类）。
    final class ClaimingContentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }

    private static let panelRect = NSRect(x: 0, y: 0, width: 800, height: 400)
    private static let blankFrame = NSRect(x: 0, y: 0, width: 800, height: 400)

    /// 面板 + 默认夹具接缝（卡片 = `Probe.card`）。
    @MainActor
    private func makePanel(content: NSView) -> (panel: NotchPanel, probe: Probe) {
        let panel = NotchPanel(
            contentRect: Self.panelRect, styleMask: [], backing: .buffered, defer: false)
        let probe = Probe()
        panel.contentView = content
        panel.forwarding = probe.seam(card: { Probe.card.contains($0) })
        return (panel, probe)
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, clickCount: Int, in panel: NotchPanel
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1)!
    }

    @Test("被窗口吞掉的卡片外按下：转投一次并自己收起，带上原始 clickCount 与 Quartz 坐标")
    @MainActor
    func swallowedPressIsForwardedOnce() {
        let (panel, probe) = makePanel(content: BlankContentView(frame: Self.blankFrame))

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 2, in: panel))

        #expect(probe.recorder.clicks.count == 1)
        let click = probe.recorder.clicks.first
        #expect(click?.button == CGMouseButton.left)
        // 双击语义要活下来：原始那一击是第 2 击，转投出去的也得是 2。
        #expect(click?.clickCount == 2)
        // 坐标换到 Quartz 系（原点 = 主屏左上、y 向下）：窗口在屏幕原点，于是 y 反过来。
        // 局限：期望值用实现同一个 API（`NSScreen.screens.first`）复算，单屏机器上它与
        // `NSScreen.main` 相等，因此这条抓的是「没翻转 / 翻反了」，抓不到「基准退回
        // NSScreen.main」（多屏才暴露）。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        #expect(click?.quartzLocation == CGPoint(x: 100, y: primaryHeight - 340))
        #expect(probe.collapses == 1)
    }

    @Test("卡片内没人认领的按下：不转投、不收起，也不让开窗口（展开动画途中的点属于这一档）")
    @MainActor
    func pressOnPanelCardIsNotForwarded() {
        let (panel, probe) = makePanel(content: BlankContentView(frame: Self.blankFrame))
        // 显式置成「接收事件」：不能靠 NotchPanel.init 的默认 true，否则即使实现把窗口
        // 让开也照样绿。
        panel.ignoresMouseEvents = false

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 400, y: 200), clickCount: 1, in: panel))

        #expect(probe.recorder.clicks.isEmpty)
        #expect(probe.collapses == 0)
        // 窗口仍接收事件 ⇒ 面板此后点得动；注入的点击也不可能被自己重新接住。
        #expect(panel.ignoresMouseEvents == false)
    }

    @Test("抬起不转投：一次点击只投一次")
    @MainActor
    func mouseUpIsNotForwarded() {
        let (panel, probe) = makePanel(content: BlankContentView(frame: Self.blankFrame))

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))
        panel.sendEvent(
            mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))

        #expect(probe.recorder.clicks.count == 1)
        #expect(probe.collapses == 1)
    }

    @Test("认领点击的视图不转投：面板自己的控件不该被送到下层应用")
    @MainActor
    func claimedPressIsNotForwarded() {
        let (panel, probe) = makePanel(content: ClaimingContentView(frame: Self.blankFrame))

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))

        // 只断言「不转投」：派发本身走 AppKit 的窗口事件链，用例里窗口没上过屏、也没有
        // 事件循环，那条链不在可观测范围内（转投路径由另外几条用例正面钉住）。
        #expect(probe.recorder.clicks.isEmpty)
        #expect(probe.collapses == 0)
    }

    @Test("右键转投同样自己收起：鼠标监听只掩码左键，缺了这条就是幽灵面板")
    @MainActor
    func rightPressIsForwardedAndCollapses() {
        let (panel, probe) = makePanel(content: BlankContentView(frame: Self.blankFrame))

        panel.sendEvent(
            mouseEvent(.rightMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))

        #expect(probe.recorder.clicks.count == 1)
        #expect(probe.recorder.clicks.first?.button == CGMouseButton.right)
        #expect(probe.collapses == 1)
    }

    @Test("转投时窗口先让开：注入的合成点击不会被自己接住")
    @MainActor
    func forwardedClickLeavesWindowTransparent() {
        let (panel, probe) = makePanel(content: BlankContentView(frame: Self.blankFrame))
        panel.ignoresMouseEvents = false

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))

        #expect(probe.recorder.clicks.count == 1)
        #expect(probe.collapses == 1)
        #expect(panel.ignoresMouseEvents)
    }

    @Test("转投判据与收起判据同源：卡片外才投，且每次转投都自己收起")
    @MainActor
    func forwardingMatchesTheCollapsingRect() {
        // 真实几何 + 真实视图模型（接缝与生产装配同一表达式），内容视图取最坏情况：
        // 没有任何 SwiftUI 视图认领点击。
        let model = NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowHeight: 750,
            hasPhysicalNotch: false)
        let (panel, probe) = makePanel(content: BlankContentView(frame: Self.blankFrame))

        // 窗口在屏幕原点 ⇒ 窗口坐标 == 屏幕坐标。只取窗口带内（y ≥ 330）的点：带外的点
        // 生产里根本不会送进这个窗口（系统直接交给下层应用），不在本用例的范围内。
        let samples = [
            CGPoint(x: 960, y: 1000),  // 卡片内（头部条带）
            CGPoint(x: 960, y: 500),  // 卡片外，仍在带内（卡片下方那条）
            CGPoint(x: 100, y: 1000),  // 卡片外的带子左上角
            CGPoint(x: 100, y: 400),  // 卡片外的带子左侧
        ]

        // 两个内容面（`openedSize` 不同）：判据必须跟着面现算，不能缓存。
        for face in [0, 1] {
            if face == 1 { model.toggleStatistics() }
            panel.forwarding = probe.seam(card: { model.isScreenPointInPanel($0) })

            for point in samples {
                let clicksBefore = probe.recorder.clicks.count
                let collapsesBefore = probe.collapses
                panel.sendEvent(mouseEvent(.leftMouseDown, at: point, clickCount: 1, in: panel))

                let forwarded = probe.recorder.clicks.count == clicksBefore + 1
                let collapsedByPanel = probe.collapses == collapsesBefore + 1
                let outsidePanel = model.geometry.isPointOutsidePanel(
                    point, size: model.openedSize)

                #expect(forwarded == outsidePanel, "\(point) 的转投判据必须与卡片矩形一致")
                #expect(
                    forwarded == collapsedByPanel, "\(point) 转投必须同时收起（否则窗口一直透明）")

                // 同源：被转投的点也必须被「点面板外收起」判为收起。
                model.notchOpen(reason: .click)
                model.handleMouseDown(at: point)
                #expect(
                    (model.status == .closed) == forwarded,
                    "\(point) 的面板外收起判据必须与转投判据一致")
            }
        }
    }

    @Test("转投出去的事件：来源是 HID、clickState 带原始击数、按键与坐标一致")
    @MainActor
    func forwardedEventsCarryClickMetadata() {
        // 左键双击：按下 + 抬起两条，clickState 都带原始击数
        // （本机实测：不设时抬起事件读出来的 clickCount 是 0）。
        let left = ClickForwarding.makeEvents(
            for: NotchForwardedClick(
                quartzLocation: CGPoint(x: 123, y: 45), button: .left, clickCount: 2))

        #expect(left.count == 2)
        #expect(left.map(\.type) == [CGEventType.leftMouseDown, .leftMouseUp])
        for event in left {
            #expect(event.getIntegerValueField(.mouseEventClickState) == 2)
            // 来源标记：真实点击是 HID（1）；不指定事件源时读出来是 0。
            #expect(event.getIntegerValueField(.eventSourceStateID) == 1)
            #expect(event.location == CGPoint(x: 123, y: 45))
            #expect(event.getIntegerValueField(.mouseEventButtonNumber) == 0)
        }

        // 右键走右边那一对类型，按键号是 1。
        let right = ClickForwarding.makeEvents(
            for: NotchForwardedClick(
                quartzLocation: CGPoint(x: 10, y: 20), button: .right, clickCount: 1))
        #expect(right.map(\.type) == [CGEventType.rightMouseDown, .rightMouseUp])
        #expect(right.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == 1 })
    }
}
