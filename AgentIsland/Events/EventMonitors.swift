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

    /// 指针兴趣区：**只有跨进 / 跨出这块矩形时**才发布 `mouseLocation`。
    ///
    /// 订阅者关心的都是「指针在不在某块矩形里」这一件事（悬停展开、面板收不收鼠标事件），
    /// 区内的连续移动对它们毫无意义——逐事件发布等于每一次移动都白烧一次
    /// `NSEvent.mouseLocation`、一次 Combine 派发和若干次几何判定。因此这里把位置流压成
    /// **边界事件**：进入发一次、离开发一次，区内移动不发。
    ///
    /// 写入方是 `NotchViewModel`：关闭 / popping 态写关闭态胶囊矩形、展开态写卡片矩形
    /// （见 `NotchViewModel.updatePointerInterest`），与行为判据取同一份几何。
    /// `nil`（默认）＝ 保持旧语义：每次移动都发布；单测与未接线时用。
    var interestRect: CGRect? {
        didSet {
            guard interestRect != oldValue else { return }
            // 兴趣区换了一块（换状态、换尺寸）：指针没动，「在不在区内」也可能已经翻面。
            // 按新矩形重算一次并在翻面时发布，否则会出现「面板刚收起，指针明明已经进了
            // 胶囊却收不到事件」这类漏判。
            publishLocationIfInterestChanged()
        }
    }

    /// 是否停在 `interestRect` 内（`interestRect == nil` 时无意义）。
    private var isInsideInterest = false

    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?

    private init() {
        setupMonitors()
    }

    private func setupMonitors() {
        mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            self?.publishLocationIfInterestChanged()
        }
        mouseMoveMonitor?.start()

        // 左键与右键同一条路（理由见 `mouseDownMask`）：右键在卡片外也要能收起面板。
        mouseDownMonitor = EventMonitor(mask: Self.mouseDownMask) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            self?.publishLocationIfInterestChanged()
        }
        mouseDraggedMonitor?.start()
    }

    /// 取一次指针位置（事件这一刻的真实位置，不做缓存），交给
    /// `publishIfInterestChanged(at:)` 判边界。
    private func publishLocationIfInterestChanged() {
        publishIfInterestChanged(at: NSEvent.mouseLocation)
    }

    /// 一条指针事件的发布判据：未接线（`nil`）时一律发；接线后只在「在不在区内」翻面时发。
    ///
    /// 抽成**纯函数**是为了让用例钉住这条契约——它是本改动唯一的行为判据
    /// （少发一次 = 悬停不展开 / 窗口该收鼠标事件时没收）。真正的发布器只负责把结果落进
    /// 状态并 `send`。
    nonisolated static func shouldPublish(
        interestRect: CGRect?, wasInside: Bool, at location: CGPoint
    ) -> (publish: Bool, isInside: Bool) {
        guard let interestRect else { return (true, wasInside) }
        let isInside = interestRect.contains(location)
        return (isInside != wasInside, isInside)
    }

    /// 只有「在不在兴趣区内」翻面时才发布位置（见 `interestRect`）。
    private func publishIfInterestChanged(at location: CGPoint) {
        let outcome = Self.shouldPublish(
            interestRect: interestRect, wasInside: isInsideInterest, at: location)
        guard outcome.publish else { return }
        isInsideInterest = outcome.isInside
        mouseLocation.send(location)
    }

    deinit {
        mouseMoveMonitor?.stop()
        mouseDownMonitor?.stop()
        mouseDraggedMonitor?.stop()
    }
}
