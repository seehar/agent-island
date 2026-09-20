//
//  AgentSettingsSection.swift
//  ClaudeIsland
//
//  设置面板中的 Agent 区段：逐个列出受支持的 Agent CLI，提供启用开关与实时
//  集成的安装状态。关闭某个 Agent 会卸载其集成，重新打开会安装集成；需要
//  集成却安装失败时回滚开关并给出提示。
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
            ForEach(AgentKind.allCases) { kind in
                AgentSettingsRow(
                    kind: kind,
                    isEnabled: isEnabled[kind] ?? true,
                    onToggle: { toggle(kind) }
                )
            }

            if let installError {
                // 安装失败的内联提示：不弹窗，保持与设置面板其它行一致
                Text(installError)
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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

/// 单个 Agent 的设置行：名称 + 集成状态 + 启用开关。
private struct AgentSettingsRow: View {
    let kind: AgentKind
    let isEnabled: Bool
    let onToggle: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentLogo(agent: kind, size: 12)
                .frame(width: 16)

            Text(kind.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer(minLength: 8)

            // 集成状态：provider 不提供集成信息时整块隐藏
            if let status = integrationStatus {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(healthText(status.health))
                        .font(.system(size: 11))
                        .foregroundColor(healthColor(status.health))
                    if let file = status.installedFiles.first {
                        Text(shortenedPath(file.path))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: 170, alignment: .trailing)
            }

            Toggle("", isOn: Binding(get: { isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(TerminalColors.green)
                .accessibilityLabel(Text(kind.displayName))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        // 被禁用的 Agent 行整体降透明度
        .opacity(isEnabled ? 1.0 : 0.5)
        .onHover { isHovered = $0 }
    }

    // MARK: - Presentation

    private var integrationStatus: AgentIntegrationStatus? {
        AgentRegistry.provider(for: kind).integrationStatus()
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func healthText(_ health: AgentIntegrationStatus.Health) -> String {
        switch health {
        case .installed: return l10n.t("Installed")
        case .missing: return l10n.t("Not installed")
        case .unavailable: return l10n.t("Unavailable")
        }
    }

    private func healthColor(_ health: AgentIntegrationStatus.Health) -> Color {
        switch health {
        case .installed: return TerminalColors.green
        case .missing: return .white.opacity(0.4)
        case .unavailable: return TerminalColors.amber
        }
    }

    /// 首页目录下的路径压缩成 `~/…`，避免长路径撑开设置面板。
    private func shortenedPath(_ raw: String) -> String {
        let home = NSHomeDirectory()
        guard raw.hasPrefix(home) else { return raw }
        return "~" + raw.dropFirst(home.count)
    }
}