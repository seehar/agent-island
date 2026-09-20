//
//  NotchMenuPages.swift
//  AgentIsland
//
//  设置面板各分组的内容页。每页按用途把设置项分成若干「卡片」，卡片之间用一行
//  小号标题分隔；分组顺序与 NotchMenuMetrics.blocks(for:) 的版面表一一对应，
//  面板高度因此仍可由常量推出。
//

import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

// MARK: - 通用

/// 「通用」页：语言、显示屏幕、胶囊高度、通知音效，以及登录时启动与辅助功能授权。
struct GeneralSettingsPage: View {
    @ObservedObject var screenSelector: ScreenSelector
    @ObservedObject var soundSelector: SoundSelector
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 登录时启动的实时状态，进入页面与回到应用时按系统状态刷新。
    @State private var launchAtLogin = false
    /// 登录项改动失败的原因；直接写在开关行的副标题里，不再只留一行控制台日志。
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(title: l10n.t("Appearance")) {
                LanguagePickerRow()
                ScreenPickerRow(screenSelector: screenSelector)
                NotchHeightPickerRow()
                NotchWidthPickerRow()
                TextSizePickerRow()
                SoundPickerRow(soundSelector: soundSelector, showsSeparator: false)
            }

            SettingsGroup(title: l10n.t("System")) {
                SettingsToggleRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "power", tint: AppPalette.accent)),
                    title: l10n.t("Launch at Login"),
                    // 正常时这行解释开关的作用，失败时换成原因：不占额外高度，
                    // 面板高度因此不必为偶发错误预留空间
                    subtitle: launchAtLoginError ?? l10n.t("Opens AgentIsland when you log in"),
                    subtitleColor: launchAtLoginError == nil
                        ? AppPalette.secondaryText : AppPalette.danger,
                    isOn: launchAtLogin,
                    onToggle: toggleLaunchAtLogin
                )
                .frame(height: NotchMenuMetrics.twoLineRowHeight)
                AccessibilityRow(isEnabled: AXIsProcessTrusted())
            }
        }
        .onAppear(perform: refresh)
        // 用户可能刚在系统设置里改过授权，回到应用时重新取一次状态。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    // MARK: - Actions

    private func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
            launchAtLoginError = nil
        } catch {
            // 最常见的两种失败：用户在系统设置里关掉了登录项、应用不在 /Applications。
            // 原因写在行内，用户不必去翻控制台。
            launchAtLoginError = l10n.t("Failed to update login item")
        }
    }
}

// MARK: - 智能体

/// 「智能体」页：各 Agent CLI 的监控开关与实时集成状态，以及 Claude Code 的
/// 配置目录。Claude Code 一行同时负责其 hook 集成的安装与卸载，因此设置里
/// 不再单独提供 Hooks 开关。
struct AgentsSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(
                title: l10n.t("Monitored Agents"),
                footnote: l10n.t("Turning an agent off also uninstalls its live integration.")
            ) {
                AgentSettingsSection()
            }

            SettingsGroup(title: l10n.t("Claude Code")) {
                ClaudeDirPickerRow(showsSeparator: false)
            }
        }
    }
}

// MARK: - 关于

/// 「关于」页：应用标识、版本与更新、GitHub、退出。
struct AboutSettingsPage: View {
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            appIdentity

            // 更新与链接是同一类「关于这个应用」的条目
            SettingsGroup {
                UpdateRow(updateManager: updateManager)

                SettingsButtonRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "star", tint: AppPalette.accent)),
                    title: l10n.t("Star on GitHub"),
                    showsSeparator: false,
                    action: openRepository
                )
            }

            // 退出是破坏性操作：单独一张卡片，不与上面混在一起
            SettingsGroup {
                SettingsButtonRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "xmark.circle", tint: AppPalette.danger)),
                    title: l10n.t("Quit"),
                    titleColor: AppPalette.danger,
                    showsSeparator: false,
                    action: quit
                )
            }
        }
    }

    // MARK: - 标识块

    /// 应用标识块：图标 + 名称 + 版本，居中——macOS「关于」面板的排版。
    /// 高度固定，面板高度不随名称或版本号的长度变化。
    private var appIdentity: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            Text(appName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppPalette.primaryText)

            Text(l10n.t("Version %@", appVersion))
                .font(.system(size: 11))
                .foregroundColor(AppPalette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotchMenuMetrics.appIdentityHeight)
    }

    private var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "AgentIsland"
    }

    /// 「1.3.2 (6)」：版本号 + 构建号。
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - 动作

    private func openRepository() {
        if let url = URL(string: "https://github.com/seehar/agent-island") {
            NSWorkspace.shared.open(url)
        }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
