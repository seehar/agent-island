//
//  EventMonitors.swift
//  AgentIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    /// 鼠标按下要监听的事件类型：**左键与右键同一条路**。
    ///
    /// 只掩码左键时，右键在卡片外的点击既不会被面板接收、也不会被这里收掉，面板于是停在
    /// 「看着还在、点不动、点击还穿过去」的状态。关闭态胶囊上右键与左键同义（展开）：
    /// 语义按状态机分（`NotchViewModel.handleMouseDown`），不按按键分。
    ///
    /// 抽成常量只为让用例钉住这条接线（掩码是私有的，行为本身没法在单测里造事件循环）。
    nonisolated static let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    let mouseDown = PassthroughSubject<NSEvent, Never>()

    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?

    private init() {
        setupMonitors()
    }

    private func setupMonitors() {
        mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            self?.mouseLocation.send(NSEvent.mouseLocation)
        }
        mouseMoveMonitor?.start()

        // 左键与右键同一条路（理由见 `mouseDownMask`）：右键在卡片外也要能收起面板。
        mouseDownMonitor = EventMonitor(mask: Self.mouseDownMask) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            self?.mouseLocation.send(NSEvent.mouseLocation)
        }
        mouseDraggedMonitor?.start()
    }

    deinit {
        mouseMoveMonitor?.stop()
        mouseDownMonitor?.stop()
        mouseDraggedMonitor?.stop()
    }
}
