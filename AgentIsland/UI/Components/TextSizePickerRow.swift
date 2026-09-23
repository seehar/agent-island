//
//  TextSizePickerRow.swift
//  AgentIsland
//
//  设置面板里的内容字号选择行：会话列表、对话与工具结果按这一档缩放。
//  每个选项右侧标出它对应的比例，便于对照；设置面板本身不随档位变化。
//

import SwiftUI

struct TextSizePickerRow: View {
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var selector = TextSizeSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(source: .symbol(name: "textformat.size", tint: AppPalette.accent)),
            title: l10n.t("Text Size"),
            value: title(for: selector.option),
            isExpanded: selector.isPickerExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起上一个展开块
                // （面板高度只按单个展开核对，见 `PickerExpansion`）。
                withAnimation(SettingsMotion.expand) {
                    selector.toggleExpansion()
                }
            }
        ) {
            ForEach(TextSizeOption.allCases) { option in
                SettingsOptionRow(
                    label: title(for: option),
                    detail: percentLabel(option),
                    isSelected: selector.option == option
                ) {
                    selector.select(option)
                    collapseAfterDelay()
                }
            }
        }
    }

    // MARK: - 文案

    /// 选项标题。在视图里按字面量取键，本地化守卫才能审计到。
    private func title(for option: TextSizeOption) -> String {
        switch option {
        case .small: return l10n.t("Small")
        case .standard: return l10n.t("Default")
        case .large: return l10n.t("Large")
        case .extraLarge: return l10n.t("Extra Large")
        }
    }

    /// 档位对应的比例。
    private func percentLabel(_ option: TextSizeOption) -> String {
        settingsPercentLabel(option.scale)
    }

    // MARK: - 交互

    /// 选择后短暂延迟再收起，让用户看到选中态的变化。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                selector.isPickerExpanded = false
            }
        }
    }
}
