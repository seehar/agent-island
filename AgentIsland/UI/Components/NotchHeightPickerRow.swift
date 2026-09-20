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
    @ObservedObject private var selector = NotchHeightSelector.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    private var isExpanded: Bool { selector.isPickerExpanded }

    /// 高度按当前选中的屏幕解析：同一份设置在内置屏与外接屏上可以是不同的数值。
    private var screen: NSScreen? { screenSelector.selectedScreen }

    private var effectiveHeight: CGFloat { selector.resolvedHeight(for: screen) }

    var body: some View {
        VStack(spacing: 0) {
            // 主行 —— 高度来源与实际生效的数值
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selector.isPickerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(l10n.t("Notch Height"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text("\(title(for: selector.mode)) · \(heightLabel(effectiveHeight))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                options
            }
        }
    }

    // MARK: - 展开的选项

    private var options: some View {
        VStack(spacing: 2) {
            ForEach([NotchHeightMode.automatic, .menuBar, .notch], id: \.self) { mode in
                NotchHeightOptionRow(
                    label: title(for: mode),
                    height: selector.height(for: mode, on: screen),
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
        .padding(.leading, 28)
        .padding(.top, 4)
    }

    // MARK: - 文案

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

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
            withAnimation(.easeInOut(duration: 0.2)) {
                selector.isPickerExpanded = false
            }
        }
    }
}

// MARK: - 来源选项行

private struct NotchHeightOptionRow: View {
    let label: String
    let height: CGFloat
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()

                Text(heightLabel(height))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.4))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 微调行

private struct NotchHeightStepperRow: View {
    let value: CGFloat
    let isSelected: Bool
    let decrease: () -> Void
    let increase: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                .frame(width: 6, height: 6)

            Text(l10n.t("Custom"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(isSelected ? 1.0 : 0.7))

            Spacer()

            StepperButton(
                systemName: "minus",
                isEnabled: value > NotchHeightSelector.minimumHeight,
                action: decrease
            )

            Text(heightLabel(value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 44)

            StepperButton(
                systemName: "plus",
                isEnabled: value < NotchHeightSelector.maximumHeight,
                action: increase
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(isEnabled ? (isHovered ? 1.0 : 0.75) : 0.25))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(isHovered && isEnabled ? 0.14 : 0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }
}
