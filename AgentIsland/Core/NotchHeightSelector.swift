//
//  NotchHeightSelector.swift
//  AgentIsland
//
//  关闭态胶囊（「灵动岛」）的高度设置。有物理刘海的屏幕取刘海高度；外接屏没有刘海，
//  因此取菜单栏高度——否则胶囊比菜单栏高出一截，屏幕顶部会多出一条黑边。
//  用户也可以在设置里选定固定的菜单栏高度 / 刘海高度，或逐点微调；微调之后就不再跟随屏幕。
//

import AppKit
import Combine
import Foundation

/// 关闭态胶囊高度的来源。
nonisolated enum NotchHeightMode: String, Codable, Sendable, CaseIterable {
    /// 自动：跟随屏幕——有物理刘海用刘海高度，没有用菜单栏高度。
    case automatic
    /// 固定用当前屏幕的菜单栏高度（有刘海的屏幕上也让胶囊与菜单栏齐平）。
    case menuBar
    /// 固定用内置屏的刘海高度（外接屏上保持与内置屏一致的观感）。
    case notch
    /// 固定高度：用户逐点微调过，不再跟随屏幕。
    case custom
}

/// 胶囊高度设置的持久化与行内展开状态（与 LanguageSelector / ScreenSelector 同族）。
@MainActor
final class NotchHeightSelector: ObservableObject {
    static let shared = NotchHeightSelector()

    // MARK: - 常量

    /// 微调范围：菜单栏 24~33、刘海 32~38 都落在区间内。
    static let minimumHeight: CGFloat = 16
    static let maximumHeight: CGFloat = 64
    /// 微调步长。
    static let step: CGFloat = 1
    /// 没有内置刘海屏时「刘海高度」退回的数值（典型 MacBook 刘海高度）。
    static let fallbackNotchHeight: CGFloat = 38
    /// 拿不到屏幕时的兜底高度（典型菜单栏高度）。
    static let fallbackHeight: CGFloat = 24
    // MARK: - 状态

    @Published private(set) var mode: NotchHeightMode = .automatic
    /// 「自定义」来源的高度；尚未微调过时只是一个起点，不参与解析。
    @Published private(set) var customHeight: CGFloat = NotchHeightSelector.fallbackHeight
    @Published var isPickerExpanded: Bool = false

    // MARK: - 持久化键

    private let modeKey = "notchHeightMode"
    private let customHeightKey = "notchHeightCustom"

    private init() {
        loadPreferences()
    }

    // MARK: - 解析

    /// 某个来源在某个屏幕上会得到的高度。
    /// 高度按屏幕解析，所以同一份设置在内置屏与外接屏上可以是不同的数值。
    func height(for mode: NotchHeightMode, on screen: NSScreen?) -> CGFloat {
        switch mode {
        case .automatic:
            return screen?.autoIslandHeight ?? Self.fallbackHeight
        case .menuBar:
            return screen?.menuBarHeight ?? Self.fallbackHeight
        case .notch:
            return Self.notchPresetHeight
        case .custom:
            return customHeight
        }
    }

    /// 当前设置在该屏幕上实际生效的高度。
    func resolvedHeight(for screen: NSScreen?) -> CGFloat {
        height(for: mode, on: screen)
    }

    /// 「刘海高度」这一来源的数值：内置屏的刘海高度，没有内置刘海屏时退回典型值。
    static var notchPresetHeight: CGFloat {
        let notchHeight = NSScreen.builtin?.physicalNotchHeight ?? 0
        return notchHeight > 0 ? notchHeight : fallbackNotchHeight
    }

    // MARK: - 修改

    /// 切换高度来源。固定高度只能通过微调进入，因此这里不接受 `.custom`。
    func select(_ newMode: NotchHeightMode) {
        guard newMode != .custom else { return }
        mode = newMode
        savePreferences()
    }

    /// 逐点微调高度：以当前生效高度为基准，并把来源切成「自定义」——此后不再跟随屏幕。
    func stepHeight(by delta: CGFloat, on screen: NSScreen?) {
        let base = mode == .custom ? customHeight : resolvedHeight(for: screen)
        customHeight = min(max(base + delta, Self.minimumHeight), Self.maximumHeight)
        mode = .custom
        savePreferences()
    }

    // MARK: - 面板高度

    /// 展开时面板需要多出来的高度：3 个来源选项 + 1 行微调。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        // 3 个来源选项 + 1 行微调
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 4)
    }

    // MARK: - 持久化

    private func loadPreferences() {
        if let raw = UserDefaults.standard.string(forKey: modeKey),
            let stored = NotchHeightMode(rawValue: raw)
        {
            mode = stored
        }

        let storedHeight = UserDefaults.standard.double(forKey: customHeightKey)
        if storedHeight > 0 {
            customHeight = min(max(CGFloat(storedHeight), Self.minimumHeight), Self.maximumHeight)
        }
    }

    private func savePreferences() {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        UserDefaults.standard.set(Double(customHeight), forKey: customHeightKey)
        // 高度变化不需要重建窗口，只要换掉关闭态矩形：面板可以一直开着，边调边看。
        NotificationCenter.default.post(name: .notchGeometryPreferenceChanged, object: nil)
    }
}

extension Notification.Name {
    /// 关闭态胶囊的几何设置（高度或宽度）变化：窗口控制器据此换掉关闭态矩形。
    static let notchGeometryPreferenceChanged = Notification.Name("NotchGeometryPreferenceChanged")
}
