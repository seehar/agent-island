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
    /// 每个 Agent 的「在刘海上批准」闸门是否打开。
    @State private var isGateEnabled = AgentSettingsSection.currentGateMap()
    /// 集成安装 / 闸门开关失败时的提示文案。
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, kind in
                AgentSettingsRow(
                    kind: kind,
                    isEnabled: isEnabled[kind] ?? true,
                    isGateEnabled: isGateEnabled[kind] ?? false,
                    // 下面永远跟着降级档选择器行，因此每个 Agent 行都画分隔线。
                    showsSeparator: true,
                    onToggle: { toggle(kind) },
                    onToggleGate: { toggleGate(kind) }
                )
            }

            ApprovalDegradationPickerRow(
                isEnabled: hasEnabledGate,
                showsSeparator: installError != nil,
                onSelect: { _ in reinstallGateExtensions() }
            )

            if let installError {
                SettingsNotice(message: installError)
            }
        }
        .onAppear { refreshState() }
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

    /// 打开 / 关闭「在刘海上批准工具调用」。
    ///
    /// 顺序：开关先落盘，再安装扩展——扩展文件里写死了闸门策略（降级档、超时），
    /// 所以「变体 + 策略」是跟着安装一起生效的。任一步失败即回滚开关并提示。
    private func toggleGate(_ kind: AgentKind) {
        let willEnable = (isGateEnabled[kind] ?? true) == false
        AppSettings.setApprovalGate(kind, enabled: willEnable)

        if !willEnable {
            // 关闭：扩展换回只上报版，并还原 omp 配置（若开关时改过）。
            AgentIntegrationInstaller.install(kind)
            OmpConfigInstaller.restoreBackup()
            installError = nil
            refreshState()
            return
        }

        // 开启：① omp 的 handler 预算（失败即回滚并保持关闭）
        //       ② 重装闸门版扩展（失败即回滚并保持关闭）
        do {
            if kind == .ohMyPi {
                try OmpConfigInstaller.applyGateTimeout()
            }
        } catch {
            AppSettings.setApprovalGate(kind, enabled: false)
            refreshState()
            installError = error.localizedDescription
            return
        }

        guard AgentIntegrationInstaller.install(kind) else {
            AppSettings.setApprovalGate(kind, enabled: false)
            if kind == .ohMyPi {
                OmpConfigInstaller.restoreBackup()
            }
            refreshState()
            installError = l10n.t("Failed to install integration for %@", kind.displayName)
            return
        }

        installError = nil
        refreshState()
    }

    /// 是否有任何一个 Agent 开着闸门：没有的话降级档没有意义（整行禁用）。
    private var hasEnabledGate: Bool {
        AgentKind.allCases.contains { kind in
            AgentIntegrationInstaller.supportsApprovalGate(kind) && (isGateEnabled[kind] ?? false)
        }
    }

    /// 换档后的动作：只重装**已开启闸门**的 Agent 的扩展（档位值写在扩展文件里）。
    private func reinstallGateExtensions() {
        for kind in AgentKind.allCases
        where AgentIntegrationInstaller.supportsApprovalGate(kind)
            && AppSettings.isApprovalGateEnabled(kind)
        {
            AgentIntegrationInstaller.install(kind)
        }
    }

    /// 开关切换后重读两个状态表。
    private func refreshState() {
        isEnabled = AgentSettingsSection.currentEnabledMap()
        isGateEnabled = AgentSettingsSection.currentGateMap()
        // 闸门全关时选择行会被禁用；此时把它收起来，否则用户没法再收起展开的选项
        // （禁用的行点不动），面板会一直留着那份高度。
        if hasEnabledGate == false {
            ApprovalDegradationSelector.shared.isPickerExpanded = false
        }
    }

    private static func currentEnabledMap() -> [AgentKind: Bool] {
        Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map {
                ($0, AppSettings.isAgentEnabled($0))
            }
        )
    }

    private static func currentGateMap() -> [AgentKind: Bool] {
        Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map {
                ($0, AppSettings.isApprovalGateEnabled($0))
            }
        )
    }
}

// MARK: - Agent 行

/// 单个 Agent 的设置行：品牌标记 + 名称（副标题是集成状态与它写在哪）+ 尾部控件
/// （可选的「在刘海上批准」闸门按钮 + 启用开关）。被关闭的 Agent 整行降透明度，
/// 但开关仍可点回来。
///
/// 闸门按钮做在行内而不是另起一行：面板高度由 `NotchMenuMetrics` 的解析式给出，
/// 加行必须同步改那张高度表；行内加一个 22pt 的图标按钮不改变行高。
/// 启用开关的写法与 `SettingsToggleRow` 保持一致（同一套视觉配方）。
private struct AgentSettingsRow: View {
    let kind: AgentKind
    let isEnabled: Bool
    let isGateEnabled: Bool
    let showsSeparator: Bool
    let onToggle: () -> Void
    let onToggleGate: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .agent(kind)),
            title: kind.displayName,
            subtitle: summary?.text,
            subtitleColor: summary?.isWarning == true
                ? AppPalette.warning : AppPalette.secondaryText
        ) {
            HStack(spacing: 10) {
                if AgentIntegrationInstaller.supportsApprovalGate(kind) {
                    gateButton
                }

                Toggle("", isOn: Binding(get: { isEnabled }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(AppPalette.accent)
                    .accessibilityLabel(Text(kind.displayName))
            }
        }
        .settingsRowSeparator(showsSeparator)
        // 行高固定为两行的高度：没有集成信息的 Agent 也占同样的高度，
        // 面板高度才不会随某个 Agent 的状态漂移。
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    // MARK: - 闸门开关

    /// 「在刘海上批准工具调用」开关：一个图标按钮（盾牌 = 开，盾牌斜杠 = 关）。
    ///
    /// 用图标而不是文字开关，是为了在 48pt 的两行行里与启用开关并排、且不挤掉
    /// 标题与集成状态。关闭状态没有任何审批闸门，所以关态用弱色、开态用强调色。
    private var gateButton: some View {
        Button(action: onToggleGate) {
            Image(systemName: isGateEnabled ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isGateEnabled ? AppPalette.accent : AppPalette.tertiaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .disabled(!isEnabled)
        .help(gateHelp)
        .accessibilityLabel(Text(l10n.t("Approve tool calls on the notch")))
        .accessibilityValue(Text(isGateEnabled ? l10n.t("On") : l10n.t("Off")))
    }

    /// 悬停说明。
    ///
    /// 这里必须说清「关闭 = 没有任何闸门」：omp 生效的 `approvalMode` 已是 yolo，
    /// 关闭本开关不会恢复 omp 自己的提示，而是把它变成完全没有闸门的 agent。
    private var gateHelp: String {
        guard isEnabled else {
            return l10n.t("Enable %@ first", kind.displayName)
        }
        if isGateEnabled {
            return l10n.t("On: %@ no longer prompts on its own. Turning this off leaves it with no approval gate at all.", kind.displayName)
        }
        return l10n.t("Approve %@ tool calls on the notch. Its default approvalMode is already yolo, so omp never prompts on its own.", kind.displayName)
    }

    // MARK: - Presentation

    /// 副标题：集成状态，已安装时在后面补上写在哪（长路径交给截断）。
    /// 不可用是唯一需要引人注意的状态，因此只有它用警告色，且不必再报路径。
    private var summary: (text: String, isWarning: Bool)? {
        guard let status = AgentRegistry.provider(for: kind).integrationStatus() else {
            return nil
        }

        if status.health == .unavailable {
            return (healthText(status.health), true)
        }
        // 版本戳 / 变体 / 降级档与当前设置对不上：界面必须说出来。
        // 「文件在、但不是这一份」正是「看着已安装、闸门其实没在用」的来源。
        if status.health == .installed,
            AgentIntegrationInstaller.hasVersionedIntegration(kind),
            AgentIntegrationInstaller.isInstalled(kind) == false
        {
            return (l10n.t("Outdated — reinstall"), true)
        }
        let health = healthText(status.health)
        guard let file = status.installedFiles.first else { return (health, false) }
        return ("\(health)\(gateSuffix) · \(shortenedPath(file.path))", false)
    }

    /// 闸门打开时把状态写进副标题（闸门开关本身只是个图标，状态得有个文字落点）。
    private var gateSuffix: String {
        guard AgentIntegrationInstaller.supportsApprovalGate(kind), isGateEnabled else { return "" }
        return " · " + l10n.t("Notch approval on")
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
    /// 选中某个档位后的回调（区段用它重装闸门版扩展）。
    let onSelect: (ApprovalDegradation) -> Void

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
                    onSelect(option)
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

    /// 悬停说明：说清「降级时终端会打出 gate offline」与「危险命令在任何档都被拒」。
    private var explanation: String {
        l10n.t(
            "When AgentIsland is not running the agent prints “gate offline” in the terminal; known-dangerous commands are rejected in every mode."
        )
    }
}
