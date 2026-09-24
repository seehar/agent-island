//
//  ShortcutsSettingsPage.swift
//  AgentIsland
//
//  设置面板的「键盘快捷键」页：全局一条 + 面板内十条，点按键块即录制。
//

import SwiftUI

/// 快捷键设置页。
///
/// 版面与 `NotchMenuMetrics.blocks(for: .shortcuts)` 一一对应：两张卡片，各自带一个脚注槽。
/// 脚注槽**始终给字符串**（槽高固定 20pt，空着会让面板比解析式高出一截）。
struct ShortcutsSettingsPage: View {
    @ObservedObject private var controller = ShortcutController.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(
                title: l10n.t("Global"),
                footnote: globalFootnote,
                footnoteColor: AppPalette.tertiaryText
            ) {
                ShortcutRecorderRow(
                    action: .summon, showsSeparator: false, bindings: ShortcutBindings.shared)
            }

            SettingsGroup(
                title: l10n.t("In the Panel"),
                footnote: panelFootnote,
                footnoteColor: panelFootnoteColor
            ) {
                ForEach(panelActions) { action in
                    ShortcutRecorderRow(
                        action: action,
                        showsSeparator: action != panelActions.last,
                        bindings: ShortcutBindings.shared)
                }
            }
        }
    }

    // MARK: - 内容

    /// 面板内的动作（顺序即 `ShortcutAction.allCases` 的声明顺序，与行表一致）。
    private var panelActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.scope == .panel }
    }

    /// 全局热键注册失败时把原因说出来——静默的「按了没反应」最难查。
    private var globalFootnote: String {
        guard controller.globalHotKeyAvailable else {
            return l10n.t("This shortcut could not be registered — another app may own it.")
        }
        return l10n.t("Works anywhere, even when the panel is closed.")
    }

    /// 录制被拒的原因优先于常驻说明。
    private var panelFootnote: String {
        if let rejection = controller.rejection {
            switch rejection {
            case .conflicting(let action):
                return l10n.t("That key is already used by “%@”.", ShortcutText.title(action, l10n))
            case .needsModifier:
                return l10n.t("This key needs a modifier key.")
            case .unsupportedKey:
                return l10n.t("This key can't be used.")
            case .globalNeedsOptionOrControl:
                return l10n.t("A global shortcut needs ⌥ or ⌃.")
            }
        }
        // 面板不接管键盘焦点时，面板内的键根本收不到——这比文本编辑规则更需要先说。
        guard AppSettings.panelTakesFocus else {
            return l10n.t(
                "Shortcuts inside the panel need the panel to take keyboard focus (General → Take Keyboard Focus)."
            )
        }
        return l10n.t(
            "While typing in the chat input, only Close or go back and Allow the pending request still work."
        )
    }

    private var panelFootnoteColor: Color {
        controller.rejection == nil ? AppPalette.tertiaryText : AppPalette.danger
    }
}

/// 页眉的「恢复默认」按钮：与统计页的重扫按钮同一格、同一档尺寸。
///
/// 放在页眉而不是页面里，是为了不占版面：页面里只有动作行，`blocks(for: .shortcuts)` 的
/// 行表与高度解析式保持一一对应。
struct ShortcutResetButton: View {
    @ObservedObject private var bindings = ShortcutBindings.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    var body: some View {
        Button {
            bindings.resetToDefaults()
        } label: {
            Text(l10n.t("Restore Defaults"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: UsageStatsMetrics.headerActionSize)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovered ? AppPalette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(l10n.t("Restore Defaults")))
    }
}
