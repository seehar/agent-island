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
    /// 由 `NotchViewController` 接上视图模型那套**同源矩形**（`NotchGeometry` 的卡片矩形，
    /// 与 `NotchCard` 画出来的那一块、与「点卡片外收起」的判据都是同一个数）。
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

        // 命中范围就是**画出来的那一块**（宿主视图坐标系），两个状态都取自视图模型那套
        // 同源矩形（见 `NotchGeometry`）。
        //
        // 打开态曾经写 `openedSize.width + 52`（比卡片宽出十几 pt：卡片边上于是有一条
        // 「窗口收下了、又没有任何控件认领」的带子，点上去既不响应也不转投）；关闭态曾经是
        // 「物理刘海外扩 10/5」（比画出来的胶囊窄一头，角色与计数徽标的外半截点不到）。
        // 窗口层的鼠标接收判据（`NotchWindowController.updateMouseAcceptance`）用的是同一个
        // 矩形，因此不会出现「窗口判卡内、收起判卡外」。
        hostingView.hitTestRect = { [weak self] in
            guard let self else { return .zero }
            let vm = self.viewModel
            switch vm.status {
            case .opened:
                return vm.geometry.openedWindowRect(for: vm.openedSize)
            case .closed, .popping:
                return vm.geometry.closedCapsuleWindowRect(for: vm.closedCapsuleSize)
            }
        }

        self.view = hostingView
    }
}
