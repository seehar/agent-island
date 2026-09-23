//
//  ScreenPickerRow.swift
//  AgentIsland
//
//  设置面板中的「显示在哪个屏幕」选择行：自动（内置屏优先）、或指定某块屏幕。
//  每块屏幕把自己的「内置 / 主屏」身份写在选项的说明里，不再另起一行。
//

import SwiftUI

struct ScreenPickerRow: View {
    @ObservedObject var screenSelector: ScreenSelector
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared

    private var isExpanded: Bool { screenSelector.isPickerExpanded }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(source: .symbol(name: "display", tint: AppPalette.accent)),
            title: l10n.t("Screen"),
            value: currentSelectionLabel,
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起上一个展开块
                // （面板高度只按单个展开核对，见 `PickerExpansion`）。
                withAnimation(SettingsMotion.expand) {
                    screenSelector.toggleExpansion()
                }
            }
        ) {
            SettingsOptionRow(
                label: l10n.t("Automatic"),
                detail: l10n.t("Built-in or Main"),
                isSelected: screenSelector.selectionMode == .automatic
            ) {
                screenSelector.selectAutomatic()
                triggerWindowRecreation()
                collapseAfterDelay()
            }

            ForEach(screenSelector.availableScreens, id: \.self) { screen in
                SettingsOptionRow(
                    label: screen.localizedName,
                    detail: screenSublabel(for: screen),
                    isSelected: screenSelector.selectionMode == .specificScreen
                        && screenSelector.isSelected(screen)
                ) {
                    screenSelector.selectScreen(screen)
                    triggerWindowRecreation()
                    collapseAfterDelay()
                }
            }
        }
    }

    // MARK: - 表现

    private var currentSelectionLabel: String {
        switch screenSelector.selectionMode {
        case .automatic:
            return l10n.t("Auto")
        case .specificScreen:
            if let screen = screenSelector.selectedScreen {
                return screen.localizedName
            }
            return l10n.t("Auto")
        }
    }

    private func screenSublabel(for screen: NSScreen) -> String? {
        var parts: [String] = []
        if screen.isBuiltinDisplay {
            parts.append(l10n.t("Built-in"))
        }
        if screen == NSScreen.main {
            parts.append(l10n.t("Main"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - 动作

    private func triggerWindowRecreation() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                screenSelector.isPickerExpanded = false
            }
        }
    }
}
