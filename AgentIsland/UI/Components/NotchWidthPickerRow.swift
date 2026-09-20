//
//  NotchWidthPickerRow.swift
//  AgentIsland
//
//  设置面板里的胶囊宽度选择行：默认跟随屏幕（有物理刘海取刘海宽度，外接屏取典型
//  MacBook 刘海宽度），也可以逐点微调；微调会把来源切成「自定义」，此后不再跟随屏幕。
//  有物理刘海的屏幕上微调下限就是刘海宽度——比挖孔还窄时胶囊两侧会露出挖孔、顶部出现
//  台阶，因此那里只能把胶囊调宽；外接屏两个方向都开放。
//

import AppKit
import SwiftUI

struct NotchWidthPickerRow: View {
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var selector = NotchWidthSelector.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    private var isExpanded: Bool { selector.isPickerExpanded }

    /// 宽度按当前选中的屏幕解析：同一份设置在内置屏与外接屏上可以是不同的数值。
    private var screen: NSScreen? { screenSelector.selectedScreen }

    private var effectiveWidth: CGFloat { selector.resolvedWidth(for: screen) }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "arrow.left.and.right", tint: AppPalette.accent)),
            title: l10n.t("Notch Width"),
            value: "\(title(for: selector.mode)) · \(settingsLengthLabel(effectiveWidth))",
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    selector.isPickerExpanded.toggle()
                }
            }
        ) {
            SettingsOptionRow(
                label: l10n.t("Automatic"),
                detail: settingsLengthLabel(selector.width(for: .automatic, on: screen)),
                isSelected: selector.mode == .automatic
            ) {
                selector.selectAutomatic()
                collapseAfterDelay()
            }

            SettingsStepperRow(
                label: l10n.t("Custom"),
                // 未微调过时显示当前生效宽度：第一下微调是从眼前的数值继续，
                // 而不是跳到一个存起来的旧值。
                value: selector.mode == .custom ? selector.customWidth : effectiveWidth,
                minimum: NotchWidthSelector.lowerBound(on: screen),
                maximum: NotchWidthSelector.maximumWidth,
                isSelected: selector.mode == .custom,
                decrease: { step(by: -NotchWidthSelector.step) },
                increase: { step(by: NotchWidthSelector.step) }
            )
        }
    }

    // MARK: - 文案

    /// 选项标题。在视图里按字面量取键，本地化守卫才能审计到。
    private func title(for mode: NotchWidthMode) -> String {
        switch mode {
        case .automatic: return l10n.t("Automatic")
        case .custom: return l10n.t("Custom")
        }
    }

    // MARK: - 交互

    private func step(by delta: CGFloat) {
        selector.stepWidth(by: delta, on: screen)
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
