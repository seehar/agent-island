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
                .font(.system(size: AppTypeScale.option))
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
                .font(.system(size: AppTypeScale.footnote).monospacedDigit())
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
                    isEnabled
                        ? (isHovered ? Color.white : AppPalette.hoverForeground)
                        : AppPalette.subtleText
                )
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        // 悬停底取滑块 token（同值 0.16）；静止底保持 0.08——`AppPalette` 里
                        // 同值的只有 `separator`，而按 token 文档它只画线、不当底色用。
                        .fill(
                            isHovered && isEnabled
                                ? AppPalette.segmentedThumb : Color.white.opacity(0.08))
                )
                // 命中区扩到 28×28（`NotchMenuMetrics.compactHitTarget`）：画出来的方块仍是
                // 20，但 20pt 见方的 ± 在光标下太容易落空（macOS 的舒适下限是 28）。
                .frame(
                    width: NotchMenuMetrics.compactHitTarget,
                    height: NotchMenuMetrics.compactHitTarget
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
