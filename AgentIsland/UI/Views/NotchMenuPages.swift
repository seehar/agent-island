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

/// 「通用」页：语言、显示屏幕、胶囊高度、胶囊宽度、内容字号、面板尺寸，
/// 以及登录时启动与辅助功能授权。通知音效在「行为」页的「通知」组里（与提示音覆盖范围同组）。
struct GeneralSettingsPage: View {
    @ObservedObject var screenSelector: ScreenSelector
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
                // 「面板尺寸」与胶囊高度、宽度、字号同属「面板长什么样」，从行为页搬来：
                // 它同时是行为页高度的对价——行为页让出一行，音效那一行才装得下。
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(
                            name: "arrow.up.left.and.arrow.down.right", tint: AppPalette.accent)),
                    title: l10n.t("Panel Size"),
                    selector: PanelSizeSelector.shared,
                    label: panelSizeLabel,
                    detail: panelSizeDetail,
                    showsSeparator: false
                )
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

    // MARK: - 文案

    /// 面板尺寸档位文案（随那一行一起从行为页搬来，只被它使用）。
    private func panelSizeLabel(_ option: PanelSize) -> String {
        switch option {
        case .compact: return l10n.t("Compact")
        case .standard: return l10n.t("Standard")
        case .wide: return l10n.t("Wide")
        }
    }

    private func panelSizeDetail(_ option: PanelSize) -> String? {
        settingsPercentLabel(option.scale)
    }
}

// MARK: - 智能体

/// 「智能体」页：卡片第一行是批量动作（全部启用并安装 / 全部关闭并卸载），下面逐个列出
/// 各 Agent CLI 的监控开关、实时集成状态与各自的配置目录（文件夹按钮展开三行编辑器）；
/// 再往下是全局的审批闸门策略。
/// Claude Code 的配置目录也走同一套逐 Agent 编辑器，因此不再单独成卡；它一行同时负责
/// 其 hook 集成的安装与卸载，设置里也不再单独提供 Hooks 开关。
struct AgentsSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 有没有开着的闸门：闸门卡片的两行据此启用/禁用。由 Agent 行的闸门开关回调刷新
    /// （兄弟视图不会因为对方改了自己的 `@State` 而重画，所以这条得由页面来记）。
    @State private var hasEnabledGate = AgentIntegrationInstaller.hasEnabledGate

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(
                title: l10n.t("Monitored Agents"),
                footnote: l10n.t("Turning an agent off also uninstalls its live integration.")
            ) {
                AgentSettingsSection(
                    onGateStateChanged: {
                        hasEnabledGate = AgentIntegrationInstaller.hasEnabledGate
                    }
                )
            }

            // 闸门策略是**全局**的（问什么 / 应用未运行时 / 待批时自动展开），不属于任何
            // 单个 Agent，因此从 Agent 列表卡片里拎出来单独成卡。
            SettingsGroup(title: l10n.t("Approval Gate")) {
                ApprovalGateSettingsGroup(isEnabled: hasEnabledGate)
            }
        }
        .onAppear { hasEnabledGate = AgentIntegrationInstaller.hasEnabledGate }
    }
}

// MARK: - 行为

/// 「行为」页：胶囊的交互与空闲表现、会话列表的内容与刷新频率、通知（音效与覆盖范围）。
/// 每行都是一个枚举档位；选项文案在本文件里按字面量取键，本地化守卫才能审计到。
/// 「待批时自动展开」是审批策略，在「智能体」页的「审批闸门」卡片里（见 `ApprovalGateSettingsGroup`）。
struct BehaviorSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 通知音效行（在「通知」组里，与提示音覆盖范围同组）。
    @ObservedObject private var soundSelector = SoundSelector.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(title: l10n.t("Notch")) {
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "cursorarrow.motionlines", tint: AppPalette.accent)),
                    title: l10n.t("Hover Expand"),
                    selector: HoverExpandSelector.shared,
                    label: hoverExpandLabel,
                    detail: hoverExpandDetail
                )
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "eye", tint: AppPalette.accent)),
                    title: l10n.t("Idle Notch"),
                    selector: IdleNotchVisibilitySelector.shared,
                    label: idleNotchLabel
                )
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "checkmark.circle", tint: AppPalette.accent)),
                    title: l10n.t("Completion Badge"),
                    selector: CompletionBadgeSelector.shared,
                    label: completionBadgeLabel,
                    showsSeparator: false
                )
            }

            SettingsGroup(title: l10n.t("Sessions")) {
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "archivebox", tint: AppPalette.accent)),
                    title: l10n.t("Ended Sessions"),
                    selector: SessionRetentionSelector.shared,
                    label: sessionRetentionLabel
                )
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "list.bullet", tint: AppPalette.accent)),
                    title: l10n.t("Row Density"),
                    selector: SessionRowDensitySelector.shared,
                    label: rowDensityLabel
                )
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "cursorarrow.click", tint: AppPalette.accent)),
                    title: l10n.t("Click Action"),
                    selector: SessionRowClickActionSelector.shared,
                    label: clickActionLabel
                )
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "clock.arrow.circlepath", tint: AppPalette.accent)),
                    title: l10n.t("Refresh Rate"),
                    selector: RefreshCadenceSelector.shared,
                    label: refreshCadenceLabel,
                    detail: refreshCadenceDetail,
                    showsSeparator: false
                )
            }

            SettingsGroup(title: l10n.t("Notifications")) {
                // 音效与「提示音覆盖哪些事件」是同一件事的两半，放在同一组里
                SoundPickerRow(soundSelector: soundSelector)
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "bell", tint: AppPalette.accent)),
                    title: l10n.t("Sound Scope"),
                    selector: NotificationScopeSelector.shared,
                    label: notificationScopeLabel,
                    showsSeparator: false
                )
            }
        }
    }

    // MARK: - 文案

    private func hoverExpandLabel(_ option: HoverExpand) -> String {
        switch option {
        case .off: return l10n.t("Never")
        case .fast: return l10n.t("Fast")
        case .standard: return l10n.t("Standard")
        case .slow: return l10n.t("Slow")
        }
    }

    private func hoverExpandDetail(_ option: HoverExpand) -> String? {
        option.delay.map(settingsSecondsLabel)
    }

    private func idleNotchLabel(_ option: IdleNotchVisibility) -> String {
        switch option {
        case .always: return l10n.t("Always")
        case .whenActive: return l10n.t("When Active")
        case .linger: return l10n.t("Keep 3 Seconds")
        }
    }

    private func completionBadgeLabel(_ option: CompletionBadge) -> String {
        switch option {
        case .short: return l10n.t("10 Seconds")
        case .standard: return l10n.t("30 Seconds")
        case .long: return l10n.t("1 Minute")
        case .persistent: return l10n.t("Always")
        }
    }

    private func sessionRetentionLabel(_ option: SessionRetention) -> String {
        switch option {
        case .immediate: return l10n.t("Immediately")
        case .minute: return l10n.t("1 Minute")
        case .tenMinutes: return l10n.t("10 Minutes")
        case .hour: return l10n.t("1 Hour")
        }
    }

    private func rowDensityLabel(_ option: SessionRowDensity) -> String {
        switch option {
        case .compact: return l10n.t("Compact")
        case .standard: return l10n.t("Standard")
        case .detailed: return l10n.t("Detailed")
        }
    }

    private func clickActionLabel(_ option: SessionRowClickAction) -> String {
        switch option {
        case .none: return l10n.t("None")
        case .openChat: return l10n.t("Open Chat")
        case .focusTerminal: return l10n.t("Focus Terminal")
        }
    }

    private func refreshCadenceLabel(_ option: RefreshCadence) -> String {
        switch option {
        case .fast: return l10n.t("Fast")
        case .standard: return l10n.t("Standard")
        case .relaxed: return l10n.t("Relaxed")
        }
    }

    private func refreshCadenceDetail(_ option: RefreshCadence) -> String? {
        settingsSecondsLabel(TimeInterval(option.statusSeconds))
    }

    private func notificationScopeLabel(_ option: NotificationScope) -> String {
        switch option {
        case .readyOnly: return l10n.t("Ready Only")
        case .readyAndApprovals: return l10n.t("Ready and Approvals")
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

                SettingsToggleRow(
                    badge: SettingsBadge(
                        source: .symbol(
                            name: "arrow.triangle.2.circlepath", tint: AppPalette.accent)),
                    title: l10n.t("Automatically Check for Updates"),
                    isOn: updateManager.automaticallyChecksForUpdates,
                    onToggle: {
                        let isOn = updateManager.automaticallyChecksForUpdates
                        updateManager.setAutomaticallyChecksForUpdates(isOn ? false : true)
                    }
                )
                .frame(height: NotchMenuMetrics.toggleRowHeight)

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
        // Sparkle 在应用启动之后才就位，进入这一页时重新读一次自动检查开关
        .onAppear { updateManager.refreshAutomaticChecks() }
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
