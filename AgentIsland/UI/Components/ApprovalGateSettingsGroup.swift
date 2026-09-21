//
//  ApprovalGateSettingsGroup.swift
//  AgentIsland
//
//  设置面板「智能体」页的闸门策略卡片：三个**全局**档位——问什么、应用未运行时、
//  待批时自动展开。它们不属于任何单个 Agent，因此与 Agent 列表分成两张卡；
//  档位值烘焙在闸门版扩展文件里，换档 = 重装已开闸门的 Agent 的扩展。
//
//  需要闸门才能设置的档位（问什么 / 应用未运行时）由卡片统一禁用与置灰，
//  启用态由页面持有（见 `AgentsSettingsPage.hasEnabledGate`）。
//

import Combine
import SwiftUI

struct ApprovalGateSettingsGroup: View {
    /// 是否至少有一个 Agent 开着闸门，由页面给出。
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            ApprovalAskScopePickerRow(isEnabled: isEnabled, showsSeparator: true)
            ApprovalDegradationPickerRow(isEnabled: isEnabled, showsSeparator: true)
            // 「待批时自动展开」与闸门开关无关：关掉闸门也会有 Claude 的
            // `PermissionRequest`，因此这一行永远可用，放在最后——避免「禁用行后面
            // 跟一行可用行」的观感。
            ApprovalAutoExpandPickerRow(showsSeparator: false)
        }
        // 闸门全关时前两行会被禁用（点不动）：此时把展开的选项收起来，否则用户没法
        // 再收起它，面板会一直留着那份高度。
        .onChange(of: isEnabled) { _, newValue in
            guard newValue == false else { return }
            withAnimation(SettingsMotion.expand) {
                ApprovalAskScopeSelector.shared.isPickerExpanded = false
                ApprovalDegradationSelector.shared.isPickerExpanded = false
            }
        }
    }
}

// MARK: - 闸门问什么

/// 「闸门问哪些调用」选择行。
///
/// 档位是**全局**的（`ApprovalAskScope`）：它决定写档与执行档要不要阻塞等人点按。与降级档
/// 一样，换档 = 重装闸门版扩展（档位值烘焙进扩展文件头的标记与策略常量）。没有开启任何
/// 闸门时这一行没有意义，因此禁用并说明原因（禁用不影响面板高度：行仍占一行）。
private struct ApprovalAskScopePickerRow: View {
    /// 是否至少有一个 Agent 开着闸门。
    let isEnabled: Bool
    let showsSeparator: Bool
    @ObservedObject private var selector = ApprovalAskScopeSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "questionmark.circle", tint: AppPalette.accent)),
            title: l10n.t("Ask before running"),
            // 禁用时这一列改成原因，用户不必猜为什么点不动。
            value: isEnabled ? compactTitle(for: selector.option) : l10n.t("Requires an approval gate"),
            isExpanded: selector.isPickerExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    selector.isPickerExpanded.toggle()
                }
            }
        ) {
            ForEach(ApprovalAskScope.allCases, id: \.self) { option in
                SettingsOptionRow(
                    label: optionTitle(option),
                    isSelected: selector.option == option
                ) {
                    selector.select(option)
                    // 档位值烘焙在闸门版扩展文件里：换档必须重装已开闸门的 Agent 的扩展
                    AgentIntegrationInstaller.reinstallGateExtensions()
                    collapseAfterDelay()
                }
            }
        }
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : 0.5)
        .help(explanation)
    }

    /// 行内取值：短文案（完整文案在选项列表里，行内放不下）。
    private func compactTitle(for scope: ApprovalAskScope) -> String {
        switch scope {
        case .writesAndExec: return l10n.t("Writes and commands")
        case .criticalOnly: return l10n.t("Dangerous commands only")
        case .alwaysAllow: return l10n.t("Always allow")
        }
    }

    /// 档位文案。在视图里按字面量取键，本地化守卫才能审计到（与其它选择器同一约定）。
    private func optionTitle(_ scope: ApprovalAskScope) -> String {
        switch scope {
        case .writesAndExec: return l10n.t("Ask for every write and command (default)")
        case .criticalOnly: return l10n.t("Ask for dangerous commands only")
        case .alwaysAllow: return l10n.t("Always allow (never ask)")
        }
    }

    /// 选择后短暂延迟再收起，让用户看到选中态的变化（与其它选择行同一手感）。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                selector.isPickerExpanded = false
            }
        }
    }

    /// 悬停说明：说清两个会问的档位为什么不是「不问」，以及「始终允许」放弃了什么。
    private var explanation: String {
        l10n.t(
            "Always allow never asks — dangerous commands run too, even when AgentIsland cannot be reached. The two asking scopes always ask for dangerous commands."
        )
    }
}

// MARK: - 审批降级档

/// 「应用未运行时的审批策略」选择行。
///
/// 档位是**全局**的（`AppSettings.approvalDegradation`）：它决定闸门在应用不可达时怎么做，
/// 换档 = 重装闸门版扩展（档位值烘焙进扩展文件头与策略常量）。没有开启任何闸门时这一行
/// 没有意义，因此禁用并说明原因（禁用不影响面板高度：行仍占一行，只是不可交互）。
private struct ApprovalDegradationPickerRow: View {
    /// 是否至少有一个 Agent 开着闸门。
    let isEnabled: Bool
    let showsSeparator: Bool
    @ObservedObject private var selector = ApprovalDegradationSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "shield.lefthalf.filled", tint: AppPalette.accent)),
            title: l10n.t("When AgentIsland is not running"),
            // 禁用时这一列改成原因，用户不必猜为什么点不动。
            value: isEnabled ? compactTitle(for: selector.option) : l10n.t("Requires an approval gate"),
            isExpanded: selector.isPickerExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    selector.isPickerExpanded.toggle()
                }
            }
        ) {
            ForEach(ApprovalDegradation.allCases, id: \.self) { option in
                SettingsOptionRow(
                    label: optionTitle(option),
                    isSelected: selector.option == option
                ) {
                    selector.select(option)
                    // 档位值烘焙在闸门版扩展文件里：换档必须重装已开闸门的 Agent 的扩展
                    AgentIntegrationInstaller.reinstallGateExtensions()
                    collapseAfterDelay()
                }
            }
        }
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : 0.5)
        .help(explanation)
    }

    /// 行内取值：短文案（完整文案在选项列表里，行内放不下）。
    private func compactTitle(for degradation: ApprovalDegradation) -> String {
        switch degradation {
        case .strict: return l10n.t("Reject all")
        case .notifyOnly: return l10n.t("Allow, show later")
        case .readOnlyAllow: return l10n.t("Read-only tools")
        }
    }

    /// 档位文案。在视图里按字面量取键，本地化守卫才能审计到（与其它选择器同一约定）。
    private func optionTitle(_ degradation: ApprovalDegradation) -> String {
        switch degradation {
        case .strict: return l10n.t("Reject everything (strict)")
        case .notifyOnly: return l10n.t("Allow, show afterwards (notify-only, default)")
        case .readOnlyAllow: return l10n.t("Allow read-only tools only (read-only-allow)")
        }
    }

    /// 选择后短暂延迟再收起，让用户看到选中态的变化（与其它选择行同一手感）。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                selector.isPickerExpanded = false
            }
        }
    }

    /// 悬停说明：说清「降级时终端会打出 gate offline」与「会问的那两档仍拒危险命令」。
    private var explanation: String {
        l10n.t(
            "When AgentIsland is not running the agent prints “gate offline” in the terminal; the two asking scopes still reject known-dangerous commands."
        )
    }
}

// MARK: - 待批时自动展开

/// 「新的待批许可到来时刘海要不要自己展开」选择行。从「行为」页的「胶囊」组搬来：
/// 它管的是审批怎么呈现，与闸门策略是一件事。
private struct ApprovalAutoExpandPickerRow: View {
    let showsSeparator: Bool

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        PreferencePickerRow(
            badge: SettingsBadge(
                source: .symbol(
                    name: "exclamationmark.circle", tint: AppPalette.accent)),
            title: l10n.t("Approval Auto Expand"),
            selector: ApprovalAutoExpandSelector.shared,
            label: label,
            showsSeparator: showsSeparator
        )
    }

    /// 档位文案。在视图里按字面量取键，本地化守卫才能审计到。
    private func label(_ option: ApprovalAutoExpand) -> String {
        switch option {
        // 不复用空闲胶囊那行的 "Always" / "Never"：键就是英文原文，复用会让中文渲染成
        // 「一直显示 / 从不」，与「自动展开」这件事不是一回事。
        case .whenTerminalIsSilent: return l10n.t("Only When the Notch Decides")
        case .always: return l10n.t("Always Expand")
        case .never: return l10n.t("Never Expand")
        }
    }
}
