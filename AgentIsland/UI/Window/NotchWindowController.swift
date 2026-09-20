//
//  NotchWindowController.swift
//  AgentIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen, animateOnLaunch: Bool = true) {
        self.screen = screen

        let screenFrame = screen.frame

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: Self.closedNotchRect(for: screen),
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.physicalNotchHeight > 0
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Dynamically toggle mouse event handling based on notch state:
        // - Closed: ignoresMouseEvents = true (clicks pass through to menu bar/apps)
        // - Opened: ignoresMouseEvents = false (buttons inside panel work)
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] status in
                switch status {
                case .opened:
                    // Accept mouse events when opened so buttons work
                    notchWindow?.ignoresMouseEvents = false
                    // Don't steal focus when opened by notification (task finished)
                    if viewModel?.openReason != .notification {
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKey()
                    }
                case .closed, .popping:
                    // Ignore mouse events when closed so clicks pass through
                    notchWindow?.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // 胶囊几何设置（高度或宽度）变化：只换关闭态胶囊矩形，不重建窗口。
        // 面板因此能一直开着，用户微调时胶囊实时跟手。
        NotificationCenter.default.publisher(for: .notchGeometryPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.viewModel.updateDeviceNotchRect(Self.closedNotchRect(for: self.screen))
            }
            .store(in: &cancellables)

        // Perform boot animation after a brief delay (only on initial launch)
        if animateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 关闭态胶囊矩形：宽度与高度各按自己的设置解析（宽度默认取屏幕的刘海宽度，
    /// 高度自动模式在有刘海的屏幕上取刘海高度、外接屏取菜单栏高度）。
    private static func closedNotchRect(for screen: NSScreen) -> CGRect {
        let width = NotchWidthSelector.shared.resolvedWidth(for: screen)
        let height = NotchHeightSelector.shared.resolvedHeight(for: screen)
        return CGRect(
            x: (screen.frame.width - width) / 2,
            y: 0,
            width: width,
            height: height
        )
    }
}
