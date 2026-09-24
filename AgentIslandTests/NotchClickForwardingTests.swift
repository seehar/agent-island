//
//  NotchClickForwardingTests.swift
//  AgentIslandTests
//
//  面板点击转投：展开态窗口盖住整屏宽、屏顶 750pt，落在面板矩形之外（或面板内没有控件
//  认领）的点击，只有「被这个窗口吞掉」的那一次才允许投给下层应用。钉住两件事——
//  ① 一次点击只投一次（鼠标监听那条路径曾经也投一次：屏幕下半部不在窗口覆盖范围内、
//  系统本来就已经把点击交给了下层应用，于是那一下变成双击）；
//  ② 转投之后窗口按开合状态恢复鼠标事件接收（面板还开着就继续接事件，否则透明会一直
//  留到下一次状态切换，面板此后点不动）。
//

import AppKit
import Testing

@testable import AgentIsland

@Suite("面板点击转投")
struct NotchClickForwardingTests {
    /// 转投记录器：接缝是非隔离的，用例里也只从主线程读写。
    nonisolated final class Recorder: @unchecked Sendable {
        private(set) var clicks: [NotchForwardedClick] = []
        func record(_ click: NotchForwardedClick) { clicks.append(click) }
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

    /// 面板 + 记录器：转投立即执行（用例里绝不真的往屏幕上投事件）。
    @MainActor
    private func makePanel(content: NSView, panelOpened: Bool) -> (NotchPanel, Recorder) {
        let panel = NotchPanel(
            contentRect: Self.panelRect, styleMask: [], backing: .buffered, defer: false)
        let recorder = Recorder()
        panel.contentView = content
        panel.forwarding = ClickForwarding(
            deliver: { recorder.record($0) },
            schedule: { $0() },
            shouldAcceptMouseEvents: { panelOpened })
        return (panel, recorder)
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

    @Test("被窗口吞掉的按下：转投一次，带上原始 clickCount 与换算好的 Quartz 坐标")
    @MainActor
    func swallowedPressIsForwardedOnce() {
        let (panel, recorder) = makePanel(
            content: BlankContentView(frame: Self.blankFrame), panelOpened: true)

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 2, in: panel))

        #expect(recorder.clicks.count == 1)
        let click = recorder.clicks.first
        #expect(click?.button == CGMouseButton.left)
        // 双击语义要活下来：原始那一击是第 2 击，转投出去的也得是 2。
        #expect(click?.clickCount == 2)
        // 坐标换到 Quartz 系（原点 = 主屏左上、y 向下）：窗口在屏幕原点，于是 y 反过来。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        #expect(click?.quartzLocation == CGPoint(x: 100, y: primaryHeight - 340))
    }

    @Test("抬起不转投：一次点击只投一次")
    @MainActor
    func mouseUpIsNotForwarded() {
        let (panel, recorder) = makePanel(
            content: BlankContentView(frame: Self.blankFrame), panelOpened: true)

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))
        panel.sendEvent(
            mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))

        #expect(recorder.clicks.count == 1)
    }

    @Test("被视图认领的按下不转投：面板自己的控件不该被送到下层应用")
    @MainActor
    func claimedPressIsNotForwarded() {
        let (panel, recorder) = makePanel(
            content: ClaimingContentView(frame: Self.blankFrame), panelOpened: true)

        panel.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 400, y: 200), clickCount: 1, in: panel))

        // 只断言「不转投」：派发本身走 AppKit 的窗口事件链，用例里窗口没上过屏、也没有
        // 事件循环，那条链不在可观测范围内（转投路径由另外几条用例正面钉住）。
        #expect(recorder.clicks.isEmpty)
    }

    @Test("右键同样转投：面板外的空白区右击不该被吃掉")
    @MainActor
    func rightPressIsForwarded() {
        let (panel, recorder) = makePanel(
            content: BlankContentView(frame: Self.blankFrame), panelOpened: true)

        panel.sendEvent(
            mouseEvent(.rightMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: panel))

        #expect(recorder.clicks.count == 1)
        #expect(recorder.clicks.first?.button == CGMouseButton.right)
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

    @Test("转投之后按开合状态恢复鼠标事件接收")
    @MainActor
    func mouseEventAcceptanceIsRestored() {
        // 面板还开着：恢复接收——否则透明会留到下一次状态切换，面板此后点不动。
        let opened = makePanel(
            content: BlankContentView(frame: Self.blankFrame), panelOpened: true)
        opened.0.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: opened.0))
        #expect(opened.0.ignoresMouseEvents == false)

        // 面板已收起：保持透明，后续点击直接落到下层应用。
        let closed = makePanel(
            content: BlankContentView(frame: Self.blankFrame), panelOpened: false)
        closed.0.sendEvent(
            mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 340), clickCount: 1, in: closed.0))
        #expect(closed.0.ignoresMouseEvents)
    }
}
