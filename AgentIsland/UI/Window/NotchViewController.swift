//
//  NotchViewController.swift
//  AgentIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
///
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    /// 卡片范围（宿主视图坐标系）：命中判定的依据。
    ///
    /// **不要**拿它去改宿主视图的 frame：状态变化发生在显示周期里，此时改视图 frame
    /// 会让 AppKit 在 `updateConstraintsIfNeeded` 中抛异常（实测崩溃于
    /// `+[NSApplication _crashOnException:]`）。窗口的鼠标接收范围改由
    /// `NotchWindowController.updateMouseAcceptance` 按指针位置在**窗口层**控制。
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard hitTestRect().contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private let sessionMonitor: ClaudeSessionMonitor
    private var hostingView: PassThroughHostingView<LocalizedRoot<NotchView>>!

    init(viewModel: NotchViewModel, sessionMonitor: ClaudeSessionMonitor) {
        self.viewModel = viewModel
        self.sessionMonitor = sessionMonitor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // 界面只有这一个宿主视图：环境 locale 在这里注入，平台驱动的格式化才跟随界面语言
        hostingView = PassThroughHostingView(
            rootView: LocalizedRoot { NotchView(viewModel: viewModel, sessionMonitor: sessionMonitor) })

        // Calculate the hit-test rect based on panel state
        hostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward
            // The window is positioned at top of screen, so panel is at top of window
            let windowHeight = geometry.windowHeight

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                let panelWidth = panelSize.width + 52  // Account for corner radius padding
                let panelHeight = panelSize.height
                let screenWidth = geometry.screenRect.width
                return CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                // When closed, use the notch rect
                let notchRect = geometry.deviceNotchRect
                let screenWidth = geometry.screenRect.width
                // Add some padding for easier interaction
                return CGRect(
                    x: (screenWidth - notchRect.width) / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        self.view = hostingView
    }
}
