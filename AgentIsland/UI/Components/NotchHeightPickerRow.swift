//
//  NotchHeightPickerRow.swift
//  AgentIsland
//
//  设置面板里的胶囊高度选择行：自动跟随屏幕（有刘海用刘海高度，外接屏用菜单栏高度）、
//  固定的菜单栏高度、固定的刘海高度，以及逐点微调。微调会把来源切成「自定义」，
//  此后不再跟随屏幕。每个选项右侧标出它实际会得到的高度，便于对齐参照物。
//

import AppKit
import SwiftUI

struct NotchHeightPickerRow: View {
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var selector = NotchHeightSelector.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    private var isExpanded: Bool { selector.isPickerExpanded }

    /// 高度按当前选中的屏幕解析：同一份设置在内置屏与外接屏上可以是不同的数值。
    private var screen: NSScreen? { screenSelector.selectedScreen }

    private var effectiveHeight: CGFloat { selector.resolvedHeight(for: screen) }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "menubar.rectangle", tint: AppPalette.accent)),
            title: l10n.t("Notch Height"),
            value: "\(title(for: selector.mode)) · \(settingsLengthLabel(effectiveHeight))",
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起上一个展开块
                // （面板高度只按单个展开核对，见 `PickerExpansion`）。
                withAnimation(SettingsMotion.expand) {
                    selector.toggleExpansion()
                }
            }
        ) {
            ForEach([NotchHeightMode.automatic, .menuBar, .notch], id: \.self) { mode in
                SettingsOptionRow(
                    label: title(for: mode),
                    detail: settingsLengthLabel(selector.height(for: mode, on: screen)),
                    isSelected: selector.mode == mode
                ) {
                    selector.select(mode)
                    collapseAfterDelay()
                }
            }

            SettingsStepperRow(
                label: l10n.t("Custom"),
                // 未微调过时显示当前生效高度：第一下微调是从眼前的数值继续，
                // 而不是跳到一个存起来的旧值。
                value: selector.mode == .custom ? selector.customHeight : effectiveHeight,
                minimum: NotchHeightSelector.minimumHeight,
                maximum: NotchHeightSelector.maximumHeight,
                isSelected: selector.mode == .custom,
                decrease: { step(by: -NotchHeightSelector.step) },
                increase: { step(by: NotchHeightSelector.step) }
            )
        }
    }

    // MARK: - 文案

    /// 选项标题。在视图里按字面量取键，本地化守卫才能审计到。
    private func title(for mode: NotchHeightMode) -> String {
        switch mode {
        case .automatic: return l10n.t("Automatic")
        case .menuBar: return l10n.t("Menu bar")
        case .notch: return l10n.t("Notch")
        case .custom: return l10n.t("Custom")
        }
    }

    // MARK: - 交互

    private func step(by delta: CGFloat) {
        selector.stepHeight(by: delta, on: screen)
    }

    /// 选择后短暂延迟再收起，让用户看到选中态的变化。微调行不收，方便连按。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                selector.isPickerExpanded = false
            }
        }
    }
}
