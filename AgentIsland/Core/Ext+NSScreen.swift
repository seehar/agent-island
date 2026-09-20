//
//  Ext+NSScreen.swift
//  AgentIsland
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

extension NSScreen {
    /// 关闭态胶囊的宽度：有物理刘海时取两侧辅助区之间的空隙（+4 与 boring.notch 对齐），
    /// 没有物理刘海的外接屏退回典型 MacBook 刘海宽度。
    var notchWidth: CGFloat {
        guard physicalNotchHeight > 0 else {
            // Fallback for non-notch displays (matches typical MacBook notch)
            return 224
        }

        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0

        guard leftPadding > 0, rightPadding > 0 else {
            // Fallback if auxiliary areas unavailable
            return 180
        }

        // +4 to match boring.notch's calculation for proper alignment
        return frame.width - leftPadding - rightPadding + 4
    }

    /// 本屏幕物理刘海（相机凸起）的高度；没有刘海的屏幕为 0。
    var physicalNotchHeight: CGFloat {
        safeAreaInsets.top
    }

    /// 本屏幕顶部菜单栏占用的高度。
    ///
    /// 可见区域的上边被菜单栏让出（Dock 只吃下边与侧边），所以可见区上边与屏幕上边的高度差
    /// 就是菜单栏高度；推导不出来时（例如菜单栏自动隐藏）退回主菜单实测值，再退回 24。
    var menuBarHeight: CGFloat {
        let derived = frame.maxY - visibleFrame.maxY
        if derived > 0 { return derived.rounded() }

        if let measured = NSApplication.shared.mainMenu?.menuBarHeight, measured > 0 {
            return measured.rounded()
        }
        return 24
    }

    /// 自动模式下的胶囊高度：有物理刘海就用刘海高度，没有（外接屏）就用菜单栏高度——
    /// 否则胶囊会比菜单栏高出一截，屏幕顶部多出一条黑边。
    var autoIslandHeight: CGFloat {
        physicalNotchHeight > 0 ? physicalNotchHeight : menuBarHeight
    }

    /// Whether this is the built-in display
    var isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// The built-in display (with notch on newer MacBooks)
    static var builtin: NSScreen? {
        if let builtin = screens.first(where: { $0.isBuiltinDisplay }) {
            return builtin
        }
        return NSScreen.main
    }
}
