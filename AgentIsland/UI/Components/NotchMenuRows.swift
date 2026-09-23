//
//  NotchMenuRows.swift
//  AgentIsland
//
//  设置面板里两个自成一体、状态较多的行：更新行与辅助功能授权行。
//  普通行、开关行与可展开的选择行都在 SettingsKit 里，这两行只写自己的状态。
//

import Combine
import SwiftUI

// MARK: - 更新行

/// 「关于」页的更新行：一行表达「检查 / 下载 / 安装」的全过程，状态与进度在右侧，
/// 失败时把原因写在副标题里（一行读不下就交给尾部的重试）。
struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsButtonRow(
            badge: SettingsBadge(source: .symbol(name: symbolName, tint: tint)),
            title: title,
            subtitle: subtitle,
            subtitleColor: subtitleColor,
            // 更新行是本卡第一行（下面还有「自动检查更新」与 GitHub）：照「非末行画线」
            // 的约定画分隔线，否则这张三行卡只有一条线，与其它卡片不同形。
            showsSeparator: true,
            trailing: { status },
            action: handleTap
        )
        // 行高固定为两行的高度：状态文案一行还是两行，面板高度都不变。
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .disabled(!isInteractive)
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - 尾部状态

    @ViewBuilder
    private var status: some View {
        switch updateManager.state {
        case .idle, .upToDate:
            EmptyView()

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _), .readyToInstall(let version):
            SettingsStatusValue(
                text: "v\(version)",
                color: AppPalette.success,
                dotColor: AppPalette.success
            )

        case .downloading(let progress), .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(progressTint)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(progressTint)
                    .frame(width: 32, alignment: .trailing)
            }

        case .error:
            SettingsStatusValue(text: l10n.t("Retry"), color: AppPalette.danger)
        }
    }

    // MARK: - 文案与配色

    private var symbolName: String {
        switch updateManager.state {
        case .idle, .checking, .downloading:
            return "arrow.down.circle"
        case .upToDate, .found, .readyToInstall:
            return "checkmark.circle.fill"
        case .extracting:
            return "doc.zipper"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch updateManager.state {
        case .idle:
            return AppPalette.accent
        case .checking, .downloading, .installing:
            return AppPalette.accent
        case .upToDate, .found, .readyToInstall:
            return AppPalette.success
        case .extracting:
            return AppPalette.warning
        case .error:
            return AppPalette.danger
        }
    }

    private var progressTint: Color {
        if case .extracting = updateManager.state { return AppPalette.warning }
        return AppPalette.accent
    }

    private var title: String {
        switch updateManager.state {
        case .idle, .upToDate:
            return l10n.t("Check for Updates")
        case .checking:
            return l10n.t("Checking...")
        case .found:
            return l10n.t("Download Update")
        case .downloading:
            return l10n.t("Downloading...")
        case .extracting:
            return l10n.t("Extracting...")
        case .readyToInstall:
            return l10n.t("Install & Relaunch")
        case .installing:
            return l10n.t("Installing...")
        case .error:
            return l10n.t("Update failed")
        }
    }

    /// 副标题：说明当前状态；失败时把原因写在这里，用户不必去翻日志。
    /// 版本号在「关于」页的标识块里，这里不重复。
    private var subtitle: String? {
        switch updateManager.state {
        case .upToDate:
            return l10n.t("Up to date")
        case .error(let message):
            return message
        default:
            return nil
        }
    }

    private var subtitleColor: Color {
        if case .error = updateManager.state { return AppPalette.danger }
        if case .upToDate = updateManager.state { return AppPalette.success }
        return AppPalette.secondaryText
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - 交互

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - 辅助功能授权行

/// 「通用」页的辅助功能授权行：已授权时只是状态，未授权时右侧给一个直接跳转系统
/// 设置的按钮，不让用户自己去翻「隐私与安全性」。
struct AccessibilityRow: View {
    let isEnabled: Bool
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 回到应用时重新取一次授权状态：用户可能刚在系统设置里改过。
    @State private var refreshTrigger = false

    private var granted: Bool {
        _ = refreshTrigger
        return isEnabled
    }

    var body: some View {
        SettingsRowLabel(
            badge: SettingsBadge(
                source: .symbol(
                    name: "hand.raised",
                    tint: granted ? AppPalette.accent : AppPalette.warning
                )
            ),
            title: l10n.t("Accessibility")
        ) {
            if granted {
                SettingsStatusValue(
                    text: l10n.t("On"),
                    color: AppPalette.secondaryText,
                    dotColor: AppPalette.success
                )
            } else {
                enableButton
            }
        }
        .settingsRowSeparator(false)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var enableButton: some View {
        Button(action: openAccessibilitySettings) {
            Text(l10n.t("Enable"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppPalette.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(SettingsCompactButtonStyle())
    }

    private func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
