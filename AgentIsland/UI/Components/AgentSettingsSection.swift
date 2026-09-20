//
//  AgentSettingsSection.swift
//  AgentIsland
//
//  设置面板中的 Agent 区段：逐个列出受支持的 Agent CLI，提供启用开关与实时集成的
//  安装状态。关闭某个 Agent 会卸载其集成，重新打开会安装集成；需要集成却安装失败
//  时回滚开关并给出提示。
//

import Combine
import Foundation
import SwiftUI

struct AgentSettingsSection: View {
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 每个 Agent 当前是否启用，切换开关后重新读取。
    @State private var isEnabled = AgentSettingsSection.currentEnabledMap()
    /// 集成安装失败时的提示文案。
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, kind in
                AgentSettingsRow(
                    kind: kind,
                    isEnabled: isEnabled[kind] ?? true,
                    showsSeparator: index < AgentKind.allCases.count - 1
                        || installError != nil,
                    onToggle: { toggle(kind) }
                )
            }

            if let installError {
                SettingsNotice(message: installError)
            }
        }
        .onAppear { isEnabled = AgentSettingsSection.currentEnabledMap() }
    }

    // MARK: - Actions

    private func toggle(_ kind: AgentKind) {
        let willEnable = !(isEnabled[kind] ?? true)

        if !willEnable {
            // 关闭：卸载集成并停用该 Agent
            AgentIntegrationInstaller.uninstall(kind)
            AppSettings.setAgent(kind, enabled: false)
            installError = nil
        } else if AgentIntegrationInstaller.install(kind) || !kind.requiresIntegrationInstall {
            // 集成装不上时不阻塞启用：部分 Agent（如 OpenCode）不依赖集成，
            // 没有它也能靠记录文件推断状态。
            AppSettings.setAgent(kind, enabled: true)
            installError = nil
        } else {
            // 需要集成的 Agent 安装失败：回滚开关，避免「已启用但收不到实时事件」
            AppSettings.setAgent(kind, enabled: false)
            installError = l10n.t("Failed to install integration for %@", kind.displayName)
        }

        isEnabled = AgentSettingsSection.currentEnabledMap()
    }

    private static func currentEnabledMap() -> [AgentKind: Bool] {
        Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map {
                ($0, AppSettings.isAgentEnabled($0))
            }
        )
    }
}

// MARK: - Agent 行

/// 单个 Agent 的设置行：品牌标记 + 名称（副标题是集成状态与它写在哪）+ 启用开关。
/// 被关闭的 Agent 整行降透明度，但开关仍可点回来。
private struct AgentSettingsRow: View {
    let kind: AgentKind
    let isEnabled: Bool
    let showsSeparator: Bool
    let onToggle: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsToggleRow(
            badge: SettingsBadge(source: .agent(kind)),
            title: kind.displayName,
            subtitle: summary?.text,
            subtitleColor: summary?.isWarning == true
                ? AppPalette.warning : AppPalette.secondaryText,
            isOn: isEnabled,
            showsSeparator: showsSeparator,
            onToggle: onToggle
        )
        // 行高固定为两行的高度：没有集成信息的 Agent 也占同样的高度，
        // 面板高度才不会随某个 Agent 的状态漂移。
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Presentation

    /// 副标题：集成状态，已安装时在后面补上写在哪（长路径交给截断）。
    /// 不可用是唯一需要引人注意的状态，因此只有它用警告色，且不必再报路径。
    private var summary: (text: String, isWarning: Bool)? {
        guard let status = AgentRegistry.provider(for: kind).integrationStatus() else {
            return nil
        }

        let health = healthText(status.health)
        if status.health == .unavailable {
            return (health, true)
        }
        guard let file = status.installedFiles.first else { return (health, false) }
        return ("\(health) · \(shortenedPath(file.path))", false)
    }

    private func healthText(_ health: AgentIntegrationStatus.Health) -> String {
        switch health {
        case .installed: return l10n.t("Installed")
        case .missing: return l10n.t("Not installed")
        case .unavailable: return l10n.t("Unavailable")
        }
    }

    /// 首页目录下的路径压缩成 `~/…`，避免长路径撑开设置面板。
    private func shortenedPath(_ raw: String) -> String {
        let home = NSHomeDirectory()
        guard raw.hasPrefix(home) else { return raw }
        return "~" + raw.dropFirst(home.count)
    }
}
