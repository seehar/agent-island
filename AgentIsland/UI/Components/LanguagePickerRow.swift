//
//  LanguagePickerRow.swift
//  AgentIsland
//
//  设置面板中的语言选择行。语言名称始终以其自身语言书写，便于辨认；
//  「跟随系统」选项则使用 macOS 的语言偏好。
//

import SwiftUI

struct LanguagePickerRow: View {
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var selector = LanguageSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(source: .symbol(name: "globe", tint: AppPalette.accent)),
            title: l10n.t("Language"),
            value: l10n.displayName(for: l10n.language),
            isExpanded: selector.isPickerExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    selector.isPickerExpanded.toggle()
                }
            }
        ) {
            ForEach(AppLanguage.allCases) { language in
                SettingsOptionRow(
                    label: l10n.displayName(for: language),
                    isSelected: l10n.language == language
                ) {
                    l10n.select(language)
                    collapseAfterDelay()
                }
            }
        }
    }

    /// 选择后短暂延迟再收起，让用户看到选中态的变化。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                selector.isPickerExpanded = false
            }
        }
    }
}
