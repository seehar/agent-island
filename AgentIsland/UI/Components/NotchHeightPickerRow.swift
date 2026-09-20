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

/// 把高度写成界面上的短标签（整数 + pt）。数值与单位都不需要翻译。
private func heightLabel(_ height: CGFloat) -> String {
    "\(Int(height.rounded())) pt"
}

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
            value: "\(title(for: selector.mode)) · \(heightLabel(effectiveHeight))",
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    selector.isPickerExpanded.toggle()
                }
            }
        ) {
            ForEach([NotchHeightMode.automatic, .menuBar, .notch], id: \.self) { mode in
                SettingsOptionRow(
                    label: title(for: mode),
                    detail: heightLabel(selector.height(for: mode, on: screen)),
                    isSelected: selector.mode == mode
                ) {
                    selector.select(mode)
                    collapseAfterDelay()
                }
            }

            NotchHeightStepperRow(
                // 未微调过时显示当前生效高度：第一下微调是从眼前的数值继续，
                // 而不是跳到一个存起来的旧值。
                value: selector.mode == .custom ? selector.customHeight : effectiveHeight,
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

// MARK: - 微调行

/// 微调行：与选项行同一套几何，右侧换成「− 数值 +」。
private struct NotchHeightStepperRow: View {
    let value: CGFloat
    let isSelected: Bool
    let decrease: () -> Void
    let increase: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(l10n.t("Custom"))
                .font(.system(size: 12))
                .foregroundColor(
                    isSelected ? AppPalette.primaryText : AppPalette.secondaryText)

            Spacer(minLength: 8)

            StepperButton(
                systemName: "minus",
                isEnabled: value > NotchHeightSelector.minimumHeight,
                action: decrease
            )

            Text(heightLabel(value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(AppPalette.secondaryText)
                .frame(width: 44)

            StepperButton(
                systemName: "plus",
                isEnabled: value < NotchHeightSelector.maximumHeight,
                action: increase
            )
        }
        .padding(.horizontal, NotchMenuMetrics.optionHorizontalPadding)
        .frame(height: NotchMenuMetrics.optionRowHeight)
    }
}

// MARK: - 微调按钮

private struct StepperButton: View {
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    Color.white.opacity(isEnabled ? (isHovered ? 1.0 : 0.75) : 0.25))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHovered && isEnabled ? 0.16 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }
}
