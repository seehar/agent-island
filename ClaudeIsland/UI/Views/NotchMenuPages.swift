//
//  NotchMenuPages.swift
//  ClaudeIsland
//
//  设置面板各分组的内容页。每页只放该分组自己的设置行，行距与容器一致，
//  因此高度可以直接由 NotchMenuMetrics 推出。原先堆在一个长列表里的
//  设置项按用途拆到三页，面板不再需要 744pt 才放得下。
//

import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

// MARK: - 通用

/// 「通用」页：语言、notch 显示屏幕、通知音效、登录时启动与辅助功能授权。
struct GeneralSettingsPage: View {
    @ObservedObject var screenSelector: ScreenSelector
    @ObservedObject var soundSelector: SoundSelector
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 登录时启动的实时状态，进入页面与回到应用时按系统状态刷新。
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            LanguagePickerRow()
            ScreenPickerRow(screenSelector: screenSelector)
            SoundPickerRow(soundSelector: soundSelector)

            MenuToggleRow(
                icon: "power",
                label: l10n.t("Launch at Login"),
                isOn: launchAtLogin
            ) {
                toggleLaunchAtLogin()
            }

            AccessibilityRow(isEnabled: AXIsProcessTrusted())
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
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }
}

// MARK: - 智能体

/// 「智能体」页：各 Agent CLI 的监控开关、实时集成状态，以及 Claude Code 的
/// 配置目录。Claude Code 一行同时负责其 hook 集成的安装与卸载，因此设置里
/// 不再单独提供 Hooks 开关。
struct AgentsSettingsPage: View {
    var body: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            AgentSettingsSection()
            ClaudeDirPickerRow()
        }
    }
}

// MARK: - 关于

/// 「关于」页：版本与更新、GitHub、退出。
struct AboutSettingsPage: View {
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            UpdateRow(updateManager: updateManager)

            MenuRow(
                icon: "star",
                label: l10n.t("Star on GitHub")
            ) {
                if let url = URL(string: "https://github.com/farouqaldori/vibe-notch") {
                    NSWorkspace.shared.open(url)
                }
            }

            MenuRow(
                icon: "xmark.circle",
                label: l10n.t("Quit"),
                isDestructive: true
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
