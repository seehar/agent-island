//
//  WindowManager.swift
//  AgentIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Window")

class WindowManager {
    private(set) var windowController: NotchWindowController?
    private var isInitialLaunch = true
    private var currentScreenFrame: NSRect?

    /// 按当前屏幕建立（或按新的屏幕参数重建）刘海窗口。
    ///
    /// 重建（换了屏幕、改了分辨率）时把面板状态接续过去：`status` / `openReason` /
    /// `contentType` / 设置面板当前分组与「收起后回到哪条对话」都不丢——用户此刻可能正开着
    /// 面板在读东西，一次显示设置变化不该让展开的面板消失（见 `NotchPanelState`）。
    func setupNotchWindow() -> NotchWindowController? {
        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        // Skip recreation if screen hasn't meaningfully changed
        if let existingController = windowController,
           let existingFrame = currentScreenFrame,
           existingFrame == screen.frame {
            logger.debug("Screen unchanged, skipping window recreation")
            return existingController
        }

        // Only animate on initial app launch, not on screen changes
        let shouldAnimate = isInitialLaunch
        isInitialLaunch = false

        // 重建前先取走面板状态（`capturedPanelState` 是旧视图模型的快照）。
        let restoring = windowController?.capturedPanelState

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            windowController = nil
        }

        currentScreenFrame = screen.frame
        windowController = NotchWindowController(
            screen: screen, animateOnLaunch: shouldAnimate, restoring: restoring)
        windowController?.showWindow(nil)

        return windowController
    }
}
