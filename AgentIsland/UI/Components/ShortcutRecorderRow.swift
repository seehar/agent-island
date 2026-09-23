//
//  ShortcutRecorderRow.swift
//  AgentIsland
//
//  快捷键设置行：动作名 + 当前按键块（点一下进入录制）。
//

import SwiftUI

/// 动作名与录制提示的文案映射。
///
/// 放在视图层而不是 `ShortcutAction` 里：key 必须保持字面量，本地化守卫才能审计到
/// （与 `ApprovalGateSettingsGroup.label(_:)` 同一套做法）。
enum ShortcutText {
    /// 动作名。
    static func title(_ action: ShortcutAction, _ l10n: LocalizationManager) -> String {
        switch action {
        case .summon: return l10n.t("Show or hide the panel")
        case .dismiss: return l10n.t("Close or go back")
        case .approve: return l10n.t("Allow the pending request")
        case .deny: return l10n.t("Deny the pending request")
        case .moveSelectionUp: return l10n.t("Move selection up")
        case .moveSelectionDown: return l10n.t("Move selection down")
        case .openChat: return l10n.t("Open the selected session's chat")
        case .focusTerminal: return l10n.t("Focus the selected session's terminal")
        case .openSettings: return l10n.t("Open or close settings")
        case .toggleStatistics: return l10n.t("Open or close usage statistics")
        case .rescan: return l10n.t("Rescan usage data")
        }
    }
}

/// 一行快捷键：左侧动作名，右侧按键块。
struct ShortcutRecorderRow: View {
    let action: ShortcutAction
    let showsSeparator: Bool

    @ObservedObject private var bindings = ShortcutBindings.shared
    @ObservedObject private var controller = ShortcutController.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsButtonRow(
            badge: SettingsBadge(source: .symbol(name: action.symbolName, tint: AppPalette.accent)),
            title: ShortcutText.title(action, l10n),
            showsSeparator: showsSeparator,
            trailing: { chordLabel },
            action: { controller.beginRecording(action) }
        )
    }

    /// 三种状态：正在录这一行、已绑定、未绑定。录制的按键块用强调色，与选中的选项同一口径。
    @ViewBuilder
    private var chordLabel: some View {
        if controller.recording == action {
            Text(l10n.t("Press a key…"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppPalette.accent)
        } else if let chord = bindings.chord(for: action) {
            Text(chord.displayLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(AppPalette.secondaryText)
        } else {
            Text(l10n.t("Not Set"))
                .font(.system(size: 11))
                .foregroundColor(AppPalette.tertiaryText)
        }
    }
}
