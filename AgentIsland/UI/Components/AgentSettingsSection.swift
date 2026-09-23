//
//  AgentSettingsSection.swift
//  AgentIsland
//
//  设置面板中的 Agent 区段：卡片的第一行是批量动作条（全部启用并安装 / 全部关闭并卸载），
//  下面逐个列出受支持的 Agent CLI，提供配置目录、启用开关与实时集成的安装状态。
//  关闭某个 Agent 会卸载其集成，重新打开会安装集成；需要集成却安装失败时给出提示。
//
//  两处看着别扭、但都是版面约束逼出来的：
//  * 卡片**渲染全部行**，只把可视窗口按 `visibleAgentRows` 封顶（滚动交给卡内）——
//    曾经连渲染也截断，窗口外的 Agent 在设置里永远够不着（关不掉、也看不到状态）。
//  * 目录编辑器固定三行、未自定义时只置灰不隐藏（见 `AgentDirPickerRow`）——卡片窗口
//    高度按它算，行数随状态变化会让窗口比内容高一截。
//
//  闸门策略（问什么 / 应用未运行时 / 待批时自动展开）不在这里：它们是全局的，见
//  `ApprovalGateSettingsGroup`。这一区段只保留每行的闸门图标按钮，并把它引起的
//  「有没有开着的闸门」变化回调给页面。
//

import AppKit
import Combine
import Foundation
import SwiftUI

struct AgentSettingsSection: View {
    /// 闸门开关变化后的回调：闸门卡片的启用态由页面持有（兄弟视图不会因为这里改了
    /// `@State` 而重画），页面据此重算「有没有开着的闸门」。
    let onGateStateChanged: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var dirSelector = AgentDirSelector.shared

    /// 每个 Agent 当前是否启用，切换开关后重新读取。
    @State private var isEnabled = AgentSettingsSection.currentEnabledMap()
    /// 每个 Agent 的「在刘海上批准」闸门是否打开。
    @State private var isGateEnabled = AgentSettingsSection.currentGateMap()
    /// 每个 Agent 指定的配置目录；不在表里 = 自动检测。
    @State private var customDirectories = AgentSettingsSection.currentDirectoryMap()
    /// 卡片的显示顺序：已启用的排在前面（见 `enabledFirstOrder()`）。
    @State private var orderedAgents = AgentKind.allCases
    /// 卡片底部的提示行（行内开关的失败原因，或批量动作的汇总）。
    @State private var notice: String?
    /// 提示行是否是错误：成功与失败共用这一行，只有颜色不同。
    @State private var noticeIsError = false

    var body: some View {
        VStack(spacing: 0) {
            AgentBulkActionsRow(
                onEnableAll: enableAllAndInstall,
                onDisableAll: disableAllAndUninstall
            )

            // 受支持的 Agent 有十几个，整张卡片按 `visibleAgentRows` 封顶、超出的
            // 在卡内滚动（与音效选择器同一套做法）：面板高度因此由常量推得出，
            // 下面的「审批闸门」卡片也还在手边。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // 渲染**全部**行：只截断窗口高度（见 `agentCardLayout(total:directoryEditorHeight:)`），
                    // 否则窗口外的 Agent 在设置面板里永远够不着。
                    ForEach(Array(orderedAgents.enumerated()), id: \.element) { index, kind in
                        AgentSettingsRow(
                            kind: kind,
                            isEnabled: isEnabled[kind] ?? false,
                            isGateEnabled: isGateEnabled[kind] ?? false,
                            customDirectory: customDirectories[kind],
                            isDirectoryExpanded: dirSelector.expandedKind == kind,
                            // 最后一行只在下面真的跟着提示时画分隔线。
                            showsSeparator: index < orderedAgents.count - 1 || notice != nil,
                            onToggle: { toggle(kind) },
                            onToggleGate: { toggleGate(kind) },
                            onToggleDirectory: {
                                withAnimation(SettingsMotion.expand) { dirSelector.toggle(kind) }
                            },
                            onDirectoryChanged: refreshState
                        )
                    }
                }
            }
            // 可视窗口 = 页面上限的行数 × 两行行高 + 展开着的目录编辑器：编辑器在滚动
            // 内容里，窗口不跟着它长高就会落到可视区之外（用户点了文件夹按钮却看不到选项）。
            .frame(
                height: NotchMenuMetrics.agentCardLayout(
                    total: orderedAgents.count,
                    directoryEditorHeight: dirSelector.expandedPickerHeight).windowHeight
            )

            if let notice {
                // 与 `SettingsNotice` 同一套排版，但颜色分「成功 / 失败」两档：`SettingsNotice`
                // 固定用 danger 色（它是按错误提示设计的），成功文案放进去会被读成出了错。
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(noticeIsError ? AppPalette.danger : AppPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            refreshState()
            orderedAgents = Self.enabledFirstOrder()
        }
    }

    /// 显示顺序：**已启用**的排最前，其次是在这台机器上检测到配置目录的，其余按枚举顺序。
    ///
    /// 默认关闭之后，「装了但没启用」不再是用户关心的那一组——他刚打开的那几个才是
    /// （空态里那枚「全部启用并安装」按钮跳过来时尤其如此）。卡片一次只显示
    /// `visibleAgentRows` 行，排在窗口外的行要滚动才看得到，顺序因此是功能性的。
    /// 排序键显式带上枚举下标：`sorted` 不保证稳定，同级的行会随实现漂移。
    /// 只在进入页面时算一次：开关切换不该让行往上跳。
    private static func enabledFirstOrder() -> [AgentKind] {
        let allCasesOrder = Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.enumerated().map { ($1, $0) })
        return AgentKind.allCases.sorted { lhs, rhs in
            let lhsRank = sortRank(lhs)
            let rhsRank = sortRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (allCasesOrder[lhs] ?? .max) < (allCasesOrder[rhs] ?? .max)
        }
    }

    /// 排序档位：0 = 已启用，1 = 检测到配置目录但没启用，2 = 这台机器上没装这个工具。
    private static func sortRank(_ kind: AgentKind) -> Int {
        if AppSettings.isAgentEnabled(kind) { return 0 }
        return AgentRegistry.provider(for: kind).isToolInstalled ? 1 : 2
    }

    // MARK: - 批量动作

    /// 全部启用并安装：对**这台机器上装了**（配置目录存在）的每个 Agent 启用并安装集成。
    ///
    /// 判据与行内开关完全一致：装不上时只有「需要集成」的 Agent 才算失败并**回滚成关闭**
    /// （避免「已启用但收不到实时事件」）；DSH 这类 `hookSpec == nil` 的 Agent 不需要集成，
    /// `install` 本就返回 false，不该被算成失败。没检测到（`paths() == nil`）的 Agent 直接
    /// 跳过——跳过不是失败。
    private func enableAllAndInstall() {
        var failures = 0
        for kind in AgentKind.allCases where AgentRegistry.provider(for: kind).isToolInstalled {
            AppSettings.setAgent(kind, enabled: true)
            if !AgentIntegrationInstaller.install(kind), kind.requiresIntegrationInstall {
                AppSettings.setAgent(kind, enabled: false)
                failures += 1
            }
        }

        refreshState()
        setNotice(
            failures == 0
                ? l10n.t("Enabled and installed every detected agent.")
                : l10n.t("Some integrations could not be installed."),
            isError: failures > 0
        )
    }

    /// 全部关闭并卸载：先确认（这一下会摘掉所有集成，误点代价不小），再逐个卸载并停用。
    private func disableAllAndUninstall() {
        guard confirmDisableAll() else { return }

        // 先取名单再改状态：循环里读的是会被自己改写的那份设置，边读边改会漏掉后面的。
        let enabled = AgentKind.allCases.filter { AppSettings.isAgentEnabled($0) }
        for kind in enabled {
            AgentIntegrationInstaller.uninstall(kind)
            AppSettings.setAgent(kind, enabled: false)
        }

        refreshState()
        setNotice(l10n.t("Disabled every agent and removed its integrations."), isError: false)
    }

    /// 关闭全部的确认弹窗。
    ///
    /// 「取消」放在第一个：`NSAlert` 的第一个按钮既是默认按钮（回车）也在最右，而破坏性
    /// 动作不该是回车与 Esc 的落点；「关闭全部」放第二个，用户必须点它才生效。
    private func confirmDisableAll() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n.t("Disable all agents and remove their integrations?")
        alert.informativeText = l10n.t(
            "Every enabled agent will be switched off and its integration removed. The tools themselves keep working in their terminals.")
        alert.addButton(withTitle: l10n.t("Cancel"))
        alert.addButton(withTitle: l10n.t("Disable All"))

        return withNotchPanelYielded { alert.runModal() } == .alertSecondButtonReturn
    }

    private func setNotice(_ message: String, isError: Bool) {
        notice = message
        noticeIsError = isError
    }

    // MARK: - Actions

    private func toggle(_ kind: AgentKind) {
        let willEnable = !(isEnabled[kind] ?? false)

        if !willEnable {
            // 关闭：卸载集成并停用该 Agent
            AgentIntegrationInstaller.uninstall(kind)
            AppSettings.setAgent(kind, enabled: false)
            notice = nil
        } else if AgentIntegrationInstaller.install(kind) || !kind.requiresIntegrationInstall {
            // 集成装不上时不阻塞启用：部分 Agent（如 OpenCode）不依赖集成，
            // 没有它也能靠记录文件推断状态。
            AppSettings.setAgent(kind, enabled: true)
            notice = nil
        } else {
            // 需要集成的 Agent 安装失败：回滚开关，避免「已启用但收不到实时事件」
            AppSettings.setAgent(kind, enabled: false)
            setNotice(
                l10n.t("Failed to install integration for %@", kind.displayName), isError: true)
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
            notice = nil
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
            setNotice(error.localizedDescription, isError: true)
            return
        }

        guard AgentIntegrationInstaller.install(kind) else {
            AppSettings.setApprovalGate(kind, enabled: false)
            if kind == .ohMyPi {
                OmpConfigInstaller.restoreBackup()
            }
            refreshState()
            setNotice(
                l10n.t("Failed to install integration for %@", kind.displayName), isError: true)
            return
        }

        notice = nil
        refreshState()
    }

    /// 开关切换后重读三张状态表，并让页面重算闸门卡片的启用态。
    private func refreshState() {
        isEnabled = AgentSettingsSection.currentEnabledMap()
        isGateEnabled = AgentSettingsSection.currentGateMap()
        customDirectories = AgentSettingsSection.currentDirectoryMap()
        onGateStateChanged()
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

    /// 用户指定了配置目录的 Agent。取值走 `AgentRootOverride`（解析 `~`、归一符号链接），
    /// 因此这里的路径与 Provider 实际读到的是同一个。
    private static func currentDirectoryMap() -> [AgentKind: String] {
        Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.compactMap { kind in
                AgentRootOverride.userOverride(for: kind).map { (kind, $0.path) }
            }
        )
    }
}

// MARK: - 批量动作条

/// 卡片第一行的批量动作条：左「全部启用并安装」、右「全部关闭并卸载」。
///
/// 它是卡片里的第一行，高度就是 `NotchMenuMetrics.rowHeight`（见
/// `blocks(for: .agents)`），因此按钮只能是 11 号字的小胶囊——那一行的高度是算进
/// 面板高度解析式的，加高按钮就等于改版面表。
private struct AgentBulkActionsRow: View {
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onEnableAll) {
                Text(l10n.t("Enable All and Install"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppPalette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(SettingsCompactButtonStyle())

            Spacer(minLength: 8)

            // 破坏性操作放最右：离主操作最远，不在「顺手点一下」的位置上（它还会再弹确认）。
            Button(action: onDisableAll) {
                Text(l10n.t("Disable All and Uninstall"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppPalette.danger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(SettingsCompactButtonStyle())
        }
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(true)
    }
}

// MARK: - Agent 行

/// 单个 Agent 的设置行：品牌标记 + 名称（副标题是自定义目录或集成状态）+ 尾部控件
/// （可选的「在刘海上批准」闸门按钮 + 配置目录按钮 + 启用开关）。被关闭的 Agent 整行
/// 降透明度，但开关仍可点回来。展开时目录编辑器跟在主行下面（同一张卡片里）。
///
/// 三个尾部控件都做在行内而不是另起一行：面板高度由 `NotchMenuMetrics` 的解析式给出，
/// 加行必须同步改那张高度表；行内多一个 22pt 的图标按钮不改变行高。
/// 启用开关的写法与 `SettingsToggleRow` 保持一致（同一套视觉配方）。
private struct AgentSettingsRow: View {
    let kind: AgentKind
    let isEnabled: Bool
    let isGateEnabled: Bool
    /// 用户指定的配置目录；nil = 自动检测。
    let customDirectory: String?
    /// 这一行的目录编辑器是否展开（同时只有一行能展开，见 `AgentDirSelector`）。
    let isDirectoryExpanded: Bool
    let showsSeparator: Bool
    let onToggle: () -> Void
    let onToggleGate: () -> Void
    let onToggleDirectory: () -> Void
    let onDirectoryChanged: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRowLabel(
                badge: SettingsBadge(source: .agent(kind)),
                title: kind.displayName,
                subtitle: summary?.text,
                subtitleColor: summary?.isWarning == true
                    ? AppPalette.warning : AppPalette.secondaryText
            ) {
                HStack(spacing: 10) {
                    // 闸门按钮的槽位**恒定占位**：只有 omp/pi 有闸门，但空着也要留出同样的
                    // 宽度，否则文件夹按钮与开关会在行与行之间左右错开（渲染出来一眼就看出歪）。
                    Group {
                        if AgentIntegrationInstaller.supportsApprovalGate(kind) {
                            gateButton
                        } else {
                            Color.clear.frame(width: 22, height: 22)
                        }
                    }

                    directoryButton

                    Toggle("", isOn: Binding(get: { isEnabled }, set: { _ in onToggle() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(AppPalette.accent)
                        .accessibilityLabel(Text(kind.displayName))
                }
            }
            // 主行固定为两行的高度：有没有副标题、目录是否自定义都不改变行高，
            // 面板高度才不会随某个 Agent 的状态漂移。
            .frame(height: NotchMenuMetrics.twoLineRowHeight)

            // 展开的目录编辑器紧跟在这一行下面（与 `SettingsPickerRow` 的展开同一套几何）：
            // 它属于这一行，所以不另起一张卡片。
            if isDirectoryExpanded {
                AgentDirPickerRow(
                    kind: kind,
                    customDirectory: customDirectory,
                    onChange: onDirectoryChanged
                )
            }
        }
        .settingsRowSeparator(showsSeparator)
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    // MARK: - 配置目录按钮

    /// 「配置目录」按钮：点开 / 收起这一行的目录编辑器。
    ///
    /// 已自定义时用强调色——那是「这一行读的不是默认目录」在行上唯一不占字的提示
    /// （副标题里的 `Custom directory:` 会被截断）。弱色表示一切按自动检测来。
    private var directoryButton: some View {
        Button(action: onToggleDirectory) {
            Image(systemName: isCustom ? "folder.fill" : "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isCustom ? AppPalette.accent : AppPalette.tertiaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .help(l10n.t("Choose Config Directory"))
        .accessibilityLabel(Text(l10n.t("Choose Config Directory")))
        .accessibilityValue(Text(directorySummaryText))
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
    /// 这里必须说清「关闭 = 没有任何闸门」：`omp` / `pi` 生效的 `approvalMode` 已是 yolo，
    /// 关闭本开关不会恢复它们自己的提示，而是把它变成完全没有闸门的 agent。
    private var gateHelp: String {
        guard isEnabled else {
            return l10n.t("Enable %@ first", kind.displayName)
        }
        if isGateEnabled {
            return l10n.t("On: %@ no longer prompts on its own. Turning this off leaves it with no approval gate at all.", kind.displayName)
        }
        return l10n.t(
            "Approve %@ tool calls on the notch. Its own approval mode is already yolo, so it never prompts by itself.",
            kind.displayName)
    }

    // MARK: - Presentation

    private var isCustom: Bool {
        !(customDirectory ?? "").isEmpty
    }

    /// 副标题：自定义了配置目录就先说清「读的是哪个目录」（那通常比集成状态更是用户
    /// 刚做完的动作，也正是会被截断的那半句），否则维持集成状态。
    private var summary: (text: String, isWarning: Bool)? {
        if isCustom {
            return (directorySummaryText, false)
        }
        return integrationSummary
    }

    /// 这一行读的是哪个目录：自定义时是它，否则是「自动检测」。
    /// 副标题（自定义时）与文件夹按钮的无障碍取值共用同一句——VoiceOver 用户看不到
    /// 那个按钮的强调色，也看不到被截断的副标题。
    private var directorySummaryText: String {
        guard let customDirectory, !customDirectory.isEmpty else { return l10n.t("Auto-detect") }
        return l10n.t("Custom directory: %@", shortenedPath(customDirectory))
    }

    /// 副标题：集成状态，已安装时在后面补上写在哪（长路径交给截断）。
    /// 不可用是唯一需要引人注意的状态，因此只有它用警告色，且不必再报路径。
    private var integrationSummary: (text: String, isWarning: Bool)? {
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

// MARK: - 模态面板

/// 弹 AppKit 的模态窗口（`NSAlert` / `NSOpenPanel`）期间，把刘海面板降回普通层并让出鼠标。
///
/// 刘海面板在 `.mainMenu + 3`，会盖住模态窗口；结束后原样还原。批量动作的确认弹窗与
/// 目录编辑器里的选择面板都要走这一步，因此抽在一起、而不是各抄一份。
func withNotchPanelYielded<T>(_ body: () -> T) -> T {
    let notchWindow = NSApp.windows.first { $0 is NotchPanel }
    let originalLevel = notchWindow?.level ?? (.mainMenu + 3)
    let wasIgnoring = notchWindow?.ignoresMouseEvents ?? true
    notchWindow?.level = .normal
    notchWindow?.ignoresMouseEvents = true

    let result = body()

    notchWindow?.level = originalLevel
    notchWindow?.ignoresMouseEvents = wasIgnoring
    return result
}