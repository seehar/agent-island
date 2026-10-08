//
//  NotchWidthSelector.swift
//  AgentIsland
//
//  关闭态胶囊（「灵动岛」）的宽度设置。宽度默认跟随屏幕：有物理刘海时取两侧辅助区
//  之间的空隙，没有刘海的外接屏退回典型 MacBook 刘海宽度。用户也可以逐点微调，
//  微调之后就不再跟随屏幕。
//
//  微调下限不越过屏幕的物理刘海宽度：胶囊比刘海挖孔还窄时，挖孔会露出胶囊两侧，
//  顶部出现一个「台阶」——因此有刘海的屏幕上只能把胶囊调宽，外接屏两个方向都开放。
//

import AppKit
import Combine
import Foundation

/// 关闭态胶囊宽度的来源。
nonisolated enum NotchWidthMode: String, Codable, Sendable, CaseIterable {
    /// 自动：跟随屏幕——有物理刘海用刘海宽度，没有用典型刘海宽度。
    case automatic
    /// 固定宽度：用户逐点微调过，不再跟随屏幕。
    case custom
}

/// 胶囊宽度设置的持久化与行内展开状态（与 NotchHeightSelector / LanguageSelector 同族）。
@MainActor
final class NotchWidthSelector: ObservableObject {
    static let shared = NotchWidthSelector()

    // MARK: - 常量

    /// 微调范围：典型刘海宽度 180~240、外接屏回退 224 都落在区间内。
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 520
    /// 微调步长。
    static let step: CGFloat = 2
    /// 拿不到屏幕时退回的宽度（典型 MacBook 刘海宽度）。
    static let fallbackNotchWidth: CGFloat = 224

    // MARK: - 状态

    @Published private(set) var mode: NotchWidthMode = .automatic
    /// 「自定义」来源的宽度；尚未微调过时只是一个起点，不参与解析。
    @Published private(set) var customWidth: CGFloat = NotchWidthSelector.fallbackNotchWidth
    @Published var isPickerExpanded: Bool = false

    // MARK: - 持久化键

    private let modeKey = "notchWidthMode"
    private let customWidthKey = "notchWidthCustom"

    private let defaults: UserDefaults

    /// 默认读写标准偏好域；测试传独立域，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPreferences()
    }

    // MARK: - 解析

    /// 某个来源在某个屏幕上会得到的宽度。
    func width(for mode: NotchWidthMode, on screen: NSScreen?) -> CGFloat {
        switch mode {
        case .automatic:
            return screen?.notchWidth ?? Self.fallbackNotchWidth
        case .custom:
            return Self.clamped(customWidth, lowerBound: Self.lowerBound(on: screen))
        }
    }

    /// 当前设置在该屏幕上实际生效的宽度。
    func resolvedWidth(for screen: NSScreen?) -> CGFloat {
        width(for: mode, on: screen)
    }

    /// 本屏幕上微调的下限：微调范围下限与物理刘海宽度里更大的那个。
    static func lowerBound(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return minimumWidth }
        return lowerBound(
            notchHeight: screen.physicalNotchHeight, notchWidth: screen.notchWidth)
    }

    /// 下限的纯函数形态（可单测）：没有物理刘海（高度 0）时就是微调范围下限，
    /// 有刘海时不得窄于挖孔宽度。
    static func lowerBound(notchHeight: CGFloat, notchWidth: CGFloat) -> CGFloat {
        notchHeight > 0 ? max(minimumWidth, notchWidth) : minimumWidth
    }

    /// 夹紧的纯函数形态（可单测）：落进 [lowerBound, maximumWidth]。
    /// 下限由调用方给出——它随屏幕变化（见 `lowerBound(on:)`），不做默认值。
    static func clamped(_ width: CGFloat, lowerBound: CGFloat) -> CGFloat {
        min(max(width, lowerBound), maximumWidth)
    }

    // MARK: - 修改

    /// 回到「自动」。固定宽度只能通过微调进入，因此这里不接受 `.custom`。
    func selectAutomatic() {
        guard mode != .automatic else { return }
        mode = .automatic
        savePreferences()
    }

    /// 逐点微调宽度：以当前生效宽度为基准，并把来源切成「自定义」——此后不再跟随屏幕。
    func stepWidth(by delta: CGFloat, on screen: NSScreen?) {
        let base = mode == .custom ? customWidth : resolvedWidth(for: screen)
        customWidth = Self.clamped(base + delta, lowerBound: Self.lowerBound(on: screen))
        mode = .custom
        savePreferences()
    }

    // MARK: - 面板高度

    /// 展开后可见的选项行数：1 个「自动」选项 + 1 行微调。
    /// 面板高度按它算，预算核对（`NotchMenuMetricsTests`）也读它，不要再写数字。
    nonisolated static let visibleOptions = 2

    /// 展开时面板需要多出来的高度。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: Self.visibleOptions)
    }

    // MARK: - 持久化

    private func loadPreferences() {
        if let raw = defaults.string(forKey: modeKey),
            let stored = NotchWidthMode(rawValue: raw)
        {
            mode = stored
        }

        let storedWidth = defaults.double(forKey: customWidthKey)
        if storedWidth > 0 {
            customWidth = Self.clamped(CGFloat(storedWidth), lowerBound: Self.minimumWidth)
        }
    }

    private func savePreferences() {
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.set(Double(customWidth), forKey: customWidthKey)
        // 宽度变化不需要重建窗口，只要换掉关闭态矩形：面板可以一直开着，边调边看。
        NotificationCenter.default.post(name: .notchGeometryPreferenceChanged, object: nil)
    }
}
