//
//  ClaudeDirPickerRow.swift
//  AgentIsland
//
//  设置面板中的 Claude 配置目录选择行。自动解析顺序：CLAUDE_CONFIG_DIR →
//  ~/.config/claude/ → ~/.claude/；也可以手动指定一个目录。
//

import AppKit
import SwiftUI

struct ClaudeDirPickerRow: View {
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var selector = ClaudeDirSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var currentValue: String = AppSettings.claudeDirectoryName

    private var isExpanded: Bool { selector.isPickerExpanded }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(source: .symbol(name: "folder", tint: SettingsPalette.accent)),
            title: l10n.t("Claude Directory"),
            value: displayValue,
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    selector.isPickerExpanded.toggle()
                }
            }
        ) {
            SettingsOptionRow(
                label: l10n.t("Auto-detect"),
                detail: isCustom ? nil : resolvedAutoDetectPath,
                isSelected: !isCustom
            ) {
                applyChoice(path: "")
            }

            SettingsOptionRow(
                label: l10n.t("Choose folder…"),
                detail: isCustom ? displayValue : nil,
                isSelected: isCustom
            ) {
                openFolderPicker()
            }
        }
        .onAppear { currentValue = AppSettings.claudeDirectoryName }
    }

    // MARK: - 表现

    private var isCustom: Bool {
        !currentValue.isEmpty && currentValue != ".claude"
    }

    /// 主行右侧的短描述。
    private var displayValue: String {
        isCustom ? shortenedPath(currentValue) : l10n.t("Auto-detect")
    }

    /// 「自动」当前实际解析到哪，作为选项说明显示。
    private var resolvedAutoDetectPath: String {
        shortenedPath(ClaudePaths.claudeDir.path)
    }

    /// 首页目录下的路径压缩成 `~/…`。
    private func shortenedPath(_ raw: String) -> String {
        let path = raw.hasPrefix("/") ? raw : NSHomeDirectory() + "/" + raw
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - 动作

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = l10n.t("Choose Claude Config Directory")
        panel.message = l10n.t("Select the folder Claude Code uses (typically ~/.claude or ~/.config/claude).")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        panel.directoryURL = ClaudePaths.claudeDir

        // 刘海面板在 .mainMenu + 3，会盖住选择面板：弹窗期间把它降回普通层并让出鼠标，
        // 结束后还原。
        let notchWindow = NSApp.windows.first { $0 is NotchPanel }
        let originalLevel = notchWindow?.level ?? (.mainMenu + 3)
        let wasIgnoring = notchWindow?.ignoresMouseEvents ?? true
        notchWindow?.level = .normal
        notchWindow?.ignoresMouseEvents = true

        let response = panel.runModal()

        notchWindow?.level = originalLevel
        notchWindow?.ignoresMouseEvents = wasIgnoring

        if response == .OK, let url = panel.url {
            applyChoice(path: url.path)
        }
    }

    private func applyChoice(path: String) {
        currentValue = path
        AppSettings.claudeDirectoryName = path
        ClaudePaths.invalidateCache()
        HookInstaller.installIfNeeded()
    }
}
