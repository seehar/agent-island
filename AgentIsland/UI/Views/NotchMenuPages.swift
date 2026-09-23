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
    /// 面板展开时是否接管键盘焦点（偏好域里的布尔档，进页面与回到应用时重读）。
    @State private var panelTakesFocus = AppSettings.panelTakesFocus

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
                SettingsToggleRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "keyboard", tint: AppPalette.accent)),
                    title: l10n.t("Take Keyboard Focus"),
                    isOn: panelTakesFocus,
                    // 单行开关行：版面表按 `toggleRowHeight` 计高（加副标题会多 6pt，
                    // 而通用页在最大 chrome 那一档已经没有余量，见 `NotchMenuMetrics`），
                    // 因此解释走提示而不是副标题。
                    helpText: l10n.t(
                        "Move keyboard focus to the panel when it opens. Turn this off to keep typing in your editor while the notch is open."
                    ),
                    onToggle: togglePanelFocus
                )
                .frame(height: NotchMenuMetrics.toggleRowHeight)
            }
        }
        .onAppear(perform: refresh)
        // 用户可能刚在系统设置里改过授权，回到应用时重新取一次状态。
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
    }

    // MARK: - Actions

    private func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        panelTakesFocus = AppSettings.panelTakesFocus
    }

    private func togglePanelFocus() {
        panelTakesFocus.toggle()
        AppSettings.panelTakesFocus = panelTakesFocus
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
/// 再往下是全局的工具调用保护档位（omp / pi 的闸门随启用而来，页面里没有审批开关）。
/// Claude Code 的配置目录也走同一套逐 Agent 编辑器，因此不再单独成卡；它一行同时负责
/// 其 hook 集成的安装与卸载，设置里也不再单独提供 Hooks 开关。
struct AgentsSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 有没有生效的闸门：保护卡片的两行据此启用/禁用。
    @State private var hasEnabledGate = AgentIntegrationInstaller.hasEnabledGate
    /// Agent 卡片操作回执；与脚注同占一行，不能改变高度预算。
    @State private var agentNotice: String?
    @State private var agentNoticeIsError = false
    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(
                title: l10n.t("Monitored Agents"),
                footnote: agentNotice
                    ?? l10n.t("Scroll the list to see all supported agents."),
                footnoteColor: agentNotice == nil
                    ? AppPalette.tertiaryText
                    : (agentNoticeIsError ? AppPalette.danger : AppPalette.secondaryText)
            ) {
                AgentSettingsSection(
                    onGateStateChanged: {
                        hasEnabledGate = AgentIntegrationInstaller.hasEnabledGate
                    },
                    notice: $agentNotice,
                    noticeIsError: $agentNoticeIsError
                )
            }

            SettingsGroup(title: l10n.t("Tool Call Guard")) {
                ApprovalGateSettingsGroup(isEnabled: hasEnabledGate)
            }
        }
        .onAppear {
            hasEnabledGate = AgentIntegrationInstaller.hasEnabledGate
        }
    }
}

// MARK: - 行为

/// 「行为」页：刘海的交互与空闲表现、会话列表的内容与刷新频率、以及两个列表开关。
/// 每行都是一个枚举档位；选项文案在本文件里按字面量取键，本地化守卫才能审计到。
/// 通知相关的行（音效、音量、安静时段、范围、完成提示）在「通知」页；
/// 「有待处理请求时自动展开」是工具调用保护档位，在「智能体」页的那张卡片里。
struct BehaviorSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 会话列表的两个开关：与列表视图共用同一实例，改完立刻重画。
    @ObservedObject private var subagentDetails = SessionDisplayPreferences.showSubagentDetails
    @ObservedObject private var hideIdleSessions = SessionDisplayPreferences.hideIdleSessions

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
                    label: idleNotchLabel,
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
                    label: clickActionLabel,
                    detail: clickActionDetail
                )
                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "clock.arrow.circlepath", tint: AppPalette.accent)),
                    title: l10n.t("Refresh Rate"),
                    selector: RefreshCadenceSelector.shared,
                    label: refreshCadenceLabel,
                    detail: refreshCadenceDetail
                )
                // 两个列表开关：都是两行行高（标题 + 一句说明），见 `NotchMenuMetrics`。
                SettingsToggleRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "person.2", tint: AppPalette.accent)),
                    title: l10n.t("Subagent Details"),
                    subtitle: l10n.t("List the tools subagents ran in the chat view."),
                    isOn: subagentDetails.isOn,
                    helpText: l10n.t("Turn this off to keep only the subagent summary line."),
                    onToggle: { subagentDetails.toggle() }
                )
                .frame(height: NotchMenuMetrics.twoLineRowHeight)

                SettingsToggleRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "eye.slash", tint: AppPalette.accent)),
                    title: l10n.t("Hide Idle Sessions"),
                    subtitle: l10n.t("Hide sessions that are not doing anything right now."),
                    isOn: hideIdleSessions.isOn,
                    showsSeparator: false,
                    helpText: l10n.t("Waiting, running and approval sessions always stay visible."),
                    onToggle: { hideIdleSessions.toggle() }
                )
                .frame(height: NotchMenuMetrics.twoLineRowHeight)
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

    private func clickActionDetail(_ option: SessionRowClickAction) -> String? {
        guard option == .focusTerminal else { return nil }
        return l10n.t("Requires a tmux session and yabai; otherwise opens chat.")
    }

    private func refreshCadenceLabel(_ option: RefreshCadence) -> String {
        switch option {
        case .fast: return l10n.t("Fast")
        case .standard: return l10n.t("Standard")
        case .relaxed: return l10n.t("Relaxed")
        }
    }

    private func refreshCadenceDetail(_ option: RefreshCadence) -> String? {
        l10n.t(
            "Status check %@ · session scan %@",
            settingsSecondsLabel(TimeInterval(option.statusSeconds)),
            settingsSecondsLabel(TimeInterval(option.discoverySeconds))
        )
    }

}

// MARK: - 通知

/// 「通知」页：音效与试听、音量、安静时段、提示音覆盖范围与完成提示。
///
/// 从行为页分出来是因为行为页的行数已经顶到面板高度的预算（判据见 `NotchMenuMetrics`）：
/// 把通知相关的行搬进来单独成页，两边都留出余量；统计页仍由页眉的图表按钮进入。
struct NotificationsSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var soundSelector = SoundSelector.shared

    /// 音量是连续值（不是枚举档位），因此用滑杆行 + 偏好域里的 Double。
    @State private var volume = AppSettings.notificationVolume()

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(title: l10n.t("Notifications")) {
                SoundPickerRow(soundSelector: soundSelector)

                SettingsSliderRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "speaker.wave.1", tint: AppPalette.accent)),
                    title: l10n.t("Notification Volume"),
                    value: $volume,
                    helpText: l10n.t("Applies to notification sounds and to previews."),
                    onChange: { AppSettings.setNotificationVolume($0) },
                    onEditingEnded: {
                        // 松手时播一次：音量调到哪儿，听一下就知道（试听不受安静时段限制）。
                        NotificationSoundPlayer.play(
                            AppSettings.notificationSound, ignoresQuietHours: true)
                    }
                )

                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "moon.zzz", tint: AppPalette.accent)),
                    title: l10n.t("Quiet Hours"),
                    selector: QuietHoursSelector.shared,
                    label: quietHoursLabel
                )

                PreferencePickerRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "bell", tint: AppPalette.accent)),
                    title: l10n.t("Sound Scope"),
                    selector: NotificationScopeSelector.shared,
                    label: notificationScopeLabel
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
        }
        .onAppear {
            // 回到这一页时重读一次：音量也可能被别的入口改过。
            volume = AppSettings.notificationVolume()
        }
    }

    // MARK: - 文案

    /// 档位文案：关闭档给文字，其余档直接把时间范围写在取值列上（不必点开才知道是哪一段）。
    /// 逐个 case 列出而不写 `default`：以后加档位时编译器会提醒这里要一起改。
    private func quietHoursLabel(_ option: QuietHours) -> String {
        switch option {
        case .off:
            return l10n.t("Off")
        case .eveningToMorning, .nightToMorning, .midnightToMorning:
            guard let span = option.minutes else { return l10n.t("Off") }
            return settingsTimeRangeLabel(startMinute: span.start, endMinute: span.end)
        }
    }

    private func notificationScopeLabel(_ option: NotificationScope) -> String {
        switch option {
        case .readyOnly: return l10n.t("Ready Only")
        case .readyAndApprovals: return l10n.t("Ready and Approvals")
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
