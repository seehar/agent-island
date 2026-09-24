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

    @ObservedObject private var bindings: ShortcutBindings
    @ObservedObject private var controller = ShortcutController.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    /// 绑定表可注入：设置页传共享实例，渲染用例传独立偏好域（避免动用户真实设置）。
    init(action: ShortcutAction, showsSeparator: Bool, bindings: ShortcutBindings) {
        self.action = action
        self.showsSeparator = showsSeparator
        self._bindings = ObservedObject(wrappedValue: bindings)
    }

    private var isRecording: Bool { controller.recording == action }
    private var isBound: Bool { bindings.chord(for: action) != nil }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧按钮专门负责录制；清空按钮是它的兄弟节点，不嵌套按钮。
            Button(action: { controller.beginRecording(action) }) {
                SettingsRowLabel(
                    badge: SettingsBadge(
                        source: .symbol(name: action.symbolName, tint: AppPalette.accent)),
                    title: ShortcutText.title(action, l10n)
                ) {
                    chordLabel
                }
                .background(isHovered ? AppPalette.rowHover : Color.clear)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }

            if isBound && !isRecording {
                Button {
                    bindings.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppPalette.tertiaryText)
                        .frame(width: 28, height: NotchMenuMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsCompactButtonStyle())
                .help(l10n.t("Clear shortcut"))
                .accessibilityLabel(Text(l10n.t("Clear shortcut")))
            }
        }
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(showsSeparator)
    }

    /// 三种状态：正在录这一行、已绑定、未绑定。录制的按键块用强调色，与选中的选项同一口径。
    @ViewBuilder
    private var chordLabel: some View {
        if isRecording {
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
