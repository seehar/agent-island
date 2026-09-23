//
//  KeyEventMonitor.swift
//  AgentIsland
//
//  本地键盘监视：能消费事件的那一种（Events/EventMonitor.swift 的本地监视只能旁观）。
//

import AppKit

/// 本地 keyDown 监视。
///
/// 与 `EventMonitor` 并列而不合并：那个包装器的本地监视回调把事件原样放行（鼠标事件只用来
/// 判断位置），而快捷键必须能**消费**按键——返回 true 的事件不再派发给界面与菜单，因此
/// `⌘,` 不会去触发 SwiftUI 空 `Settings` 场景那个窗口。
@MainActor
final class KeyEventMonitor {
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent) -> Bool
    private var monitor: Any?

    /// 回调返回 true 表示消费该事件。
    init(mask: NSEvent.EventTypeMask = [.keyDown], handler: @escaping (NSEvent) -> Bool) {
        self.mask = mask
        self.handler = handler
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handler(event) ? nil : event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
