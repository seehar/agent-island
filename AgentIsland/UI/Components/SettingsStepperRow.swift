//
//  SettingsStepperRow.swift
//  AgentIsland
//
//  展开的选择器里的微调行：与选项行同一套几何，右侧换成「− 数值 +」。
//  胶囊高度与宽度两个选择器共用它，差别只是标签、上下限与步长。
//

import SwiftUI

struct SettingsStepperRow: View {
    /// 行标签。
    let label: String
    let value: CGFloat
    /// 微调范围（含）。到达边界时对应方向的按钮变灰。
    let minimum: CGFloat
    let maximum: CGFloat
    let isSelected: Bool
    let decrease: () -> Void
    let increase: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(
                    isSelected ? AppPalette.primaryText : AppPalette.secondaryText)

            Spacer(minLength: 8)

            StepperButton(
                systemName: "minus",
                label: l10n.t("Decrease"),
                isEnabled: value > minimum,
                action: decrease
            )

            Text(settingsLengthLabel(value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(AppPalette.secondaryText)
                .frame(width: 44)

            StepperButton(
                systemName: "plus",
                label: l10n.t("Increase"),
                isEnabled: value < maximum,
                action: increase
            )
        }
        .padding(.horizontal, NotchMenuMetrics.optionHorizontalPadding)
        .frame(height: NotchMenuMetrics.optionRowHeight)
        // 可调范围在界面上无处可见（上下限随屏幕变化，如胶囊宽度下限＝物理刘海宽度），
        // 提示里补上；辅助技术读到的是「标签 当前值 范围」。
        .help(
            l10n.t(
                "%@ · %@ to %@",
                label,
                settingsLengthLabel(minimum),
                settingsLengthLabel(maximum))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(
            Text("\(settingsLengthLabel(value)) (\(settingsLengthLabel(minimum))–\(settingsLengthLabel(maximum)))")
        )
    }
}

// MARK: - 微调按钮

private struct StepperButton: View {
    let systemName: String
    /// 无障碍与工具提示用的按钮名（「增加」/「减少」）：字形本身读不出语义。
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    Color.white.opacity(isEnabled ? (isHovered ? 1.0 : 0.75) : 0.25)
                )
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(Color.white.opacity(isHovered && isEnabled ? 0.16 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }
}
