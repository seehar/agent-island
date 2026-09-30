//
//  AgentSettingsSection.swift
//  AgentIsland
//
//  设置面板中的 Agent 区段：卡片的第一行是批量动作条（全部启用并安装 / 全部关闭并卸载），
//  下面逐个列出受支持的 Agent CLI，提供配置目录、启用开关与实时集成的安装状态。
//  关闭某个 Agent 会卸载其集成，重新打开会安装集成；需要集成却安装失败时给出提示。
//  只要有启用的 Agent，卡片脚注就提示「重启 CLI」——运行中的 CLI 不会因为我们改了它的
//  配置就加载 hook，提示只出现在脚注这一处（不在每个 Agent 行里重复）。
//
//  两处看着别扭、但都是版面约束逼出来的：
//  * 卡片**渲染全部行**，只把可视窗口按 `visibleAgentRows` 封顶（滚动交给卡内）——
//    曾经连渲染也截断，窗口外的 Agent 在设置里永远够不着（关不掉、也看不到状态）。
//  * 目录编辑器固定三行、未自定义时只置灰不隐藏（见 `AgentDirPickerRow`）——卡片窗口
//    高度按它算，行数随状态变化会让窗口比内容高一截。
//
//  启用开关是**唯一**的入口：omp / pi 一启用就装闸门版扩展（见
//  `AgentIntegrationInstaller.gateIsActive`），行内没有任何审批开关或字样——闸门随启用
//  而来，用户不必再点第二个开关。保护档位（问什么 / 应用未运行时 / 有待处理请求时自动展开）是
//  全局的，见 `ApprovalGateSettingsGroup`；它只需要知道「有没有生效的闸门」，由这里的
//  启用 / 关闭动作回调给页面。
//
//  单行关闭**没有确认弹窗**（开关本身就该即点即生效），代价是它会删掉工具配置里的 hook
//  条目（不可见、不可撤销）——所以关闭之后，动作条那一行会把左边的「全部启用并安装」
//  临时换成「撤销」（见 `pendingUndoKind`）。撤销是即时的、只留一次：任何后续动作都会
//  顶掉它。批量关闭仍有确认弹窗（一下摘掉所有集成，误点代价太大）。
//

import AppKit
import Combine
import Foundation
import SwiftUI

struct AgentSettingsSection: View {
    /// 进「标记动态」页：卡片第一行的入口行用它。页面持有 `NotchViewModel` 的动作，
    /// 逐层传到这里（卡片自身拿不到视图模型）。
    let onOpenAnimations: () -> Void

    /// 启用 / 关闭动作之后的回调：闸门策略卡片的启用态由页面持有（兄弟视图不会因为这里
    /// 改了 `@State` 而重画），页面据此重算「有没有生效的闸门」。
    let onGateStateChanged: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var dirSelector = AgentDirSelector.shared

    /// 「减少动态效果」系统偏好：行内展开动画据此换成不动的版本（见 `AppMotion`）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 每个 Agent 当前是否启用，切换开关后重新读取。
    @State private var isEnabled = AgentSettingsSection.currentEnabledMap()
    /// 每个 Agent 指定的配置目录；不在表里 = 自动检测。
    @State private var customDirectories = AgentSettingsSection.currentDirectoryMap()
    /// 卡片的显示顺序：已启用的排在前面（见 `enabledFirstOrder()`）。
    @State private var orderedAgents = AgentKind.allCases
    /// 刚刚被单行关闭、可以一键撤销的那个 Agent（nil = 没有可撤销的动作）。
    ///
    /// 单行关闭没有确认弹窗（开关本身就该即点即生效），代价是它删掉了工具配置里的 hook
    /// 条目——所以关闭之后动作条会把「全部启用并安装」临时让给「撤销」。它只留一次：
    /// 任何后续动作或重新读状态（见 `refreshState()`）都会顶掉它，用过即消失。
    @State private var pendingUndoKind: AgentKind?
    /// 卡片下方的提示行（行内开关的回执 / 失败原因、批量动作的汇总，或「有启用的 Agent
    /// 就得重启 CLI」这条状态提示）由**页面**持有：
    /// 它渲染在卡片脚注那一格里（定点 20pt，已进高度预算）。画在卡片内部会凭空多出一份
    /// 不在解析式里的高度，把下面的「工具调用保护」卡挤出可视区——而这条回执恰恰是
    /// 用户刚点完开关在等的东西。
    @Binding var notice: String?
    /// 提示行是否是错误：成功与失败共用这一行，只有颜色不同。
    @Binding var noticeIsError: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 卡片第一行：「标记动态」的入口（轮播角色缩略图 + 标题 + chevron）。
            // 它曾经是页眉里那枚 11 号字的小按钮——实测用户找不到；换成一整行之后，
            // 高度从 `visibleAgentRows` 里挪（5 → 4，见 `NotchMenuMetrics.blocks(for:)`）。
            AgentAnimationsEntryRow(action: onOpenAnimations)

            AgentBulkActionsRow(
                onEnableAll: enableAllAndInstall,
                onDisableAll: disableAllAndUninstall,
                // 有撤销可给时，动作条左边那一格让给它（见 `AgentBulkActionsRow`）。
                onUndo: undoAction
            )

            // 受支持的 Agent 有十几个，整张卡片按 `visibleAgentRows` 封顶、超出的
            // 在卡内滚动（与音效选择器同一套做法，滚动条同样交给系统浮层）：
            // 面板高度因此由常量推得出，下面的「工具调用保护」卡片也还在手边。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // 渲染**全部**行：只截断窗口高度（见 `agentCardLayout(total:directoryEditorHeight:)`），
                    // 否则窗口外的 Agent 在设置面板里永远够不着。
                    ForEach(Array(orderedAgents.enumerated()), id: \.element) { index, kind in
                        AgentSettingsRow(
                            kind: kind,
                            isEnabled: isEnabled[kind] ?? false,
                            customDirectory: customDirectories[kind],
                            isDirectoryExpanded: dirSelector.expandedKind == kind,
                            // 最后一行不画分隔线（提示行已经不在卡片里了）。
                            showsSeparator: index < orderedAgents.count - 1,
                            onToggle: { toggle(kind) },
                            onToggleDirectory: {
                                withAnimation(
                                    AppMotion.pick(
                                        SettingsMotion.expand, reduceMotion: reduceMotion)
                                ) { dirSelector.toggle(kind) }
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
                    directoryEditorHeight: dirSelector.expandedPickerHeight
                ).windowHeight
            )

        }
        .onAppear {
            refreshState()
            orderedAgents = Self.enabledFirstOrder()
            // 进页面就先立好脚注：有启用的 Agent 时提示「重启 CLI」（回执是动作触发的，
            // 这里没有新的动作，传 nil）。
            publishFootnote()
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

    /// 全部启用并安装：对**这台机器上装了**（配置目录存在）的每个 Agent 走与行内开关
    /// 完全相同的一条路径（`enable(_:)`，其中 omp / pi 会顺带装闸门版扩展）。
    ///
    /// 没检测到（`paths() == nil`）的 Agent 直接跳过——跳过不是失败。
    private func enableAllAndInstall() {
        var failures = 0
        for kind in AgentKind.allCases where AgentRegistry.provider(for: kind).isToolInstalled {
            if enable(kind) != nil { failures += 1 }
        }

        refreshState()
        publishFootnote(
            receipt: failures == 0
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
        publishFootnote(receipt: l10n.t("Disabled every agent and removed its integrations."))
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
            "Every enabled agent will be switched off and its integration removed. The tools themselves keep working in their terminals."
        )
        alert.addButton(withTitle: l10n.t("Cancel"))
        alert.addButton(withTitle: l10n.t("Disable All"))

        return withNotchPanelYielded { alert.runModal() } == .alertSecondButtonReturn
    }

    /// 脚注一行显示什么（内部可见：单测钉住「启用之后必须提示重启 CLI」）。
    ///
    /// 优先级：动作回执（用户刚点完开关在等的结果，失败原因尤其）> 重启提示 > nil
    /// （交回页面自己的默认文案）。
    ///
    /// 提示是**状态**而不是一次性回执：运行中的 Agent CLI 不会因为我们改了它的配置就加载
    /// hook —— 用户不重启，集成就不会生效。它只出现在卡片脚注这一处，不在每个 Agent 行里
    /// 重复（行内副标题已经被集成状态与配置目录占满）。
    nonisolated static func footnote(receipt: String?, hasEnabledAgent: Bool) -> String? {
        if let receipt { return receipt }
        guard hasEnabledAgent else { return nil }
        return LocalizationManager.t("Restart the agent's CLI to load the integration.")
    }

    /// 重算脚注：没有回执时按「有没有启用的 Agent」给出重启提示或交回默认文案。
    private func publishFootnote(receipt: String? = nil, isError: Bool = false) {
        let text = AgentSettingsSection.footnote(
            receipt: receipt, hasEnabledAgent: isEnabled.values.contains(true))
        notice = text
        noticeIsError = text == nil ? false : isError
    }

    // MARK: - Actions

    /// 动作条上「撤销」那一格的动作：没有可撤销的关闭时是 nil（那一格画「全部启用并安装」）。
    private var undoAction: (() -> Void)? {
        guard pendingUndoKind != nil else { return nil }
        return undoDisable
    }

    private func toggle(_ kind: AgentKind) {
        // 回执先攒着：脚注内容在重读状态**之后**才算得出（「有没有启用的 Agent」是状态，
        // 不是动作本身）。
        var receipt: String?
        var isError = false
        var disabledKind: AgentKind?
        if isEnabled[kind] ?? false {
            // 关闭：卸载集成并停用该 Agent。omp 那侧抬过的 handler 预算**保持不动**：
            // 还原是整份写回备份，会连带盖掉用户此后自己对 omp 配置的改动，代价比留下
            // 一个用不到的预算大（闸门版扩展已经卸载，没有 handler 会再用它）。
            AgentIntegrationInstaller.uninstall(kind)
            AppSettings.setAgent(kind, enabled: false)
            // 单行关闭也要回执：这一步会删掉该工具配置里的 hook 条目（不可见、不可撤销），
            // 而批量版既有确认也有回执——同一动作的两条路径不能只有批量那条说话。
            receipt = l10n.t("Turned off %@ and removed its integration.", kind.displayName)
            disabledKind = kind
        } else if let failure = enable(kind) {
            receipt = failure
            isError = true
        }

        refreshState()
        // 撤销的落点：这次关闭真的卸载了集成，所以「装回去 + 重新启用」一定还原得回去
        // （见 `undoDisable()`）。`refreshState()` 刚把上一轮的撤销顶掉，这里点亮新的那个。
        pendingUndoKind = disabledKind
        // 启用成功时没有回执：脚注就该提示「重启 CLI」——运行中的 CLI 不会因为我们改了
        // 配置就加载 hook（见 `footnote(receipt:hasEnabledAgent:)`）。
        publishFootnote(receipt: receipt, isError: isError)
    }

    /// 撤销上一次单行关闭：把集成装回去并重新启用。
    ///
    /// `pendingUndoKind` 只在「我们刚刚真的卸载了集成」的那条路径上落，所以这里一定
    /// 还原得回关闭前的状态；装不回去时如实报错（脚注转成错误色），不静默当成功。
    private func undoDisable() {
        guard let kind = pendingUndoKind else { return }
        pendingUndoKind = nil

        let failure = enable(kind)
        refreshState()
        publishFootnote(receipt: failure, isError: failure != nil)
    }

    /// 启用一个 Agent：装集成（omp / pi 在这里顺带装上闸门版扩展），失败即退回关闭状态。
    ///
    /// 顺序要紧：**先落「启用」标志再安装**——闸门版扩展是按 `gateIsActive`（= 支持闸门
    /// 且已被监控）选的，反了会装上只上报版，用户看到的是「开着开关却没有闸门」。
    /// omp 的 handler 预算由安装路径自己确保（见 `AgentIntegrationInstaller.install`）。
    ///
    /// 返回 nil 表示成功，否则是给用户看的失败原因。
    private func enable(_ kind: AgentKind) -> String? {
        AppSettings.setAgent(kind, enabled: true)

        // 集成装不上时不阻塞启用：部分 Agent（如 OpenCode）不依赖集成，
        // 没有它也能靠记录文件推断状态。装了集成的那些必须装成功，否则
        // 开关回滚成关闭，避免「已启用但收不到实时事件」。
        guard AgentIntegrationInstaller.install(kind) || !kind.requiresIntegrationInstall else {
            AppSettings.setAgent(kind, enabled: false)
            return l10n.t("Failed to install integration for %@", kind.displayName)
        }
        return nil
    }

    /// 开关切换后重读状态表，并让页面重算闸门策略行的启用态。
    ///
    /// 也在这里顶掉待撤销的那一次关闭：凡是「重新读一遍状态」的入口（开关、批量动作、
    /// 改配置目录、重新进页）都意味着用户已经在做别的事了，那个一次性的撤销不该还留着。
    /// `toggle` 会在它之后再把新的撤销点亮（见那边）。
    private func refreshState() {
        pendingUndoKind = nil
        isEnabled = AgentSettingsSection.currentEnabledMap()
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

/// 卡片第一行的批量动作条：撤销（临时）/ 全部启用并安装在左，全部关闭并卸载在右。
///
/// 它是卡片里的第一行，高度就是 `NotchMenuMetrics.rowHeight`（见
/// `blocks(for: .agents)`），因此按钮只能是 11 号字的小胶囊——那一行的高度是算进
/// 面板高度解析式的，加高按钮就等于改版面表。
///
/// 有撤销可给时它**占左边那一格**（不是再加一枚）：面板宽度随 `PanelSize` 缩放，
/// 最窄档把三枚胶囊并排放不下（会互相压扁），而撤销比「全部启用并安装」窄，换上去
/// 反而更稳。它也不落在最右那一格——那是破坏性动作的位置（撤销不毁东西）。
private struct AgentBulkActionsRow: View {
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void
    /// 撤销上一次单行关闭；nil = 没有可撤销的动作，此时左边那格画「全部启用并安装」。
    let onUndo: (() -> Void)?

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 8) {
            if let onUndo {
                // 描边式而不是实心：与「全部启用并安装」的实心强调色、破坏性动作的
                // 实心危险色都区分得开——撤销是回执，不是第三种主操作。
                AgentBulkPill(
                    title: l10n.t("Undo"),
                    foreground: AppPalette.accent,
                    fill: nil,
                    action: onUndo
                )
            } else {
                AgentBulkPill(
                    title: l10n.t("Enable All and Install"),
                    foreground: .black.opacity(0.85),
                    fill: AppPalette.accent,
                    action: onEnableAll
                )
            }

            Spacer(minLength: 8)

            // 破坏性操作放最右：离主操作最远，不在「顺手点一下」的位置上（它还会再弹确认）。
            // 底色是弱白 0.08（`AppPalette.pillFill` 就是这一档，改造前是裸字面量）：
            // 破坏性动作不填危险色——红字已经说明了它的性质，红底会把它变成整页的视觉焦点。
            AgentBulkPill(
                title: l10n.t("Disable All and Uninstall"),
                foreground: AppPalette.danger,
                fill: AppPalette.pillFill,
                action: onDisableAll
            )
        }
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(true)
    }
}

/// 批量动作条上的 11 号字小胶囊。文字、文字色与底色都定死在一行里，行高才不变；
/// 悬停时叠一层弱白（不换底色，实心与描边两种样式因此共用同一套反馈）。
///
/// `fill` 为 nil 时画描边胶囊——那是「撤销」的写法：它与实心的主操作、
/// 危险色的破坏性动作都区分得开。
private struct AgentBulkPill: View {
    let title: String
    let foreground: Color
    let fill: Color?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(pillBackground)
                .contentShape(Capsule())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovered = $0 }
    }

    /// 底色：实心胶囊（主操作 / 破坏性动作）或描边胶囊（撤销）。
    ///
    /// 悬停时在底色上再叠一层弱白——**叠在文字下面**，文字本身不跟着变浅；描边式的
    /// 那一支把描边画在最后，悬停时形状不会被弱白盖掉。
    private var pillBackground: some View {
        ZStack {
            if let fill {
                Capsule().fill(fill)
                if isHovered { Capsule().fill(AppPalette.rowHover) }
            } else {
                Capsule().fill(isHovered ? AppPalette.rowHover : Color.clear)
                Capsule().strokeBorder(AppPalette.accent, lineWidth: 1)
            }
        }
    }
}

// MARK: - Agent 行

/// 单个 Agent 的设置行：品牌标记 + 名称（副标题是自定义目录或集成状态）+ 尾部控件
/// （配置目录按钮 + 启用开关）。被关闭的 Agent 整行降透明度，但开关仍可点回来。
/// 展开时目录编辑器跟在主行下面（同一张卡片里）。
///
/// 尾部只有两个控件、都做在行内而不是另起一行：面板高度由 `NotchMenuMetrics` 的解析式
/// 给出，加行必须同步改那张高度表；行内多一个 22pt 的图标按钮不改变行高。
/// 启用开关的写法与 `SettingsToggleRow` 保持一致（同一套视觉配方）。
///
/// 这里**没有**闸门开关：omp / pi 的闸门随启用而来（见 `AgentIntegrationInstaller.gateIsActive`），
/// 页面上不出现任何审批字样。
private struct AgentSettingsRow: View {
    let kind: AgentKind
    let isEnabled: Bool
    /// 用户指定的配置目录；nil = 自动检测。
    let customDirectory: String?
    /// 这一行的目录编辑器是否展开（同时只有一行能展开，见 `AgentDirSelector`）。
    let isDirectoryExpanded: Bool
    let showsSeparator: Bool
    let onToggle: () -> Void
    let onToggleDirectory: () -> Void
    let onDirectoryChanged: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    /// 行悬停：整行叠一层弱白，18 行逐个都点得到的行因此有「可点」的反馈。
    @State private var isHovered = false

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
            // 悬停底色铺在主行**整行**上（`frame` 之后，才是那一行的全高全宽）；
            // 检测也挂在这里，展开着的目录编辑器因此不会连带点亮主行。
            .background(isHovered ? AppPalette.rowHover : Color.clear)
            .onHover { isHovered = $0 }

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

    // MARK: - Presentation

    private var isCustom: Bool {
        !(customDirectory ?? "").isEmpty
    }

    /// 副标题：自定义了配置目录就先说清「读的是哪个目录」（那通常比集成状态更是用户
    /// 刚做完的动作，也正是会被截断的那半句），否则维持集成状态。
    private var summary: (text: String, isWarning: Bool)? {
        if let integrationSummary, integrationSummary.isWarning { return integrationSummary }
        if environmentConfigRoot != nil { return (directorySummaryText, false) }
        if isCustom { return (directorySummaryText, false) }
        return integrationSummary
    }

    /// 这一行读的是哪个目录：自定义时是它，否则是「自动检测」。
    /// 副标题（自定义时）与文件夹按钮的无障碍取值共用同一句——VoiceOver 用户看不到
    /// 那个按钮的强调色，也看不到被截断的副标题。
    private var directorySummaryText: String {
        if let environmentRoot = environmentConfigRoot {
            return l10n.t("Environment directory: %@", shortenedPath(environmentRoot.path))
        }
        guard let customDirectory, !customDirectory.isEmpty else { return l10n.t("Auto-detect") }
        return l10n.t("Custom directory: %@", shortenedPath(customDirectory))
    }

    /// Codex / Grok 的环境变量优先级高于设置页覆盖目录；摘要显示实际生效根目录。
    private var environmentConfigRoot: URL? {
        let variable: String
        switch kind {
        case .codex: variable = "CODEX_HOME"
        case .grok: variable = "GROK_HOME"
        default: return nil
        }
        guard let raw = Foundation.ProcessInfo.processInfo.environment[variable],
            !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallback = home.appendingPathComponent(".\(kind.rawValue)")
        return AgentRootOverride.resolve(raw, fallback: fallback, home: home)
    }

    /// 副标题：集成状态，已安装时在后面补上写在哪（长路径交给截断）。
    /// 需要引人注意的状态都用警告色：不可用、装完没生效（可执行位设不上）、缺 `python3`
    /// 而装不上；版本过旧要重装同理。其余按普通状态显示。
    private var integrationSummary: (text: String, isWarning: Bool)? {
        if let warning = ompTimeoutWarning { return (warning, true) }
        guard let status = AgentRegistry.provider(for: kind).integrationStatus() else { return nil }

        if status.health == .unavailable {
            return (healthText(status.health), true)
        }
        if status.health == .installed,
            AgentIntegrationInstaller.hasVersionedIntegration(kind),
            AgentIntegrationInstaller.isInstalled(kind) == false
        {
            return (l10n.t("Outdated — reinstall"), true)
        }
        // 装了但没生效：配置里写着我们的脚本，可是文件差一道可执行位（只有 Cline 的事件
        // 文件需要自己被执行）——工具会调用它、每个事件都失败。
        if status.health == .installed, !AgentConfigInstaller.hookFilesAreExecutable(kind) {
            return (l10n.t("Installed, but the hook file could not be made executable."), true)
        }
        // hook 命令全靠 `python3` 的 Agent（Claude 与所有配置文件型 Agent）：这台机器上没有
        // 它时我们一个字节都不写（见 `AgentConfigInstaller.install` / `HookInstaller`），
        // 状态因此停在「未安装」，但必须说清原因。
        if status.health == .missing,
            kind.hookSpec != nil || kind == .claudeCode,
            !HookInstaller.pythonIsAvailable
        {
            return (l10n.t("Not installed — python3 is required for the shared hook script."), true)
        }
        let health = healthText(status.health)
        guard let file = status.installedFiles.first else { return (health, false) }
        // 状态与落点拼成一句时走格式键（`%@ · %@`）：分隔符两侧要按语言重排，
        // 直接字符串相加会让译者改不了语序。
        return (l10n.t("%@ · %@", health, shortenedPath(file.path)), false)
    }

    private var ompTimeoutWarning: String? {
        guard kind == .ohMyPi,
            isEnabled,
            AppSettings.ompGateTimeoutSetupFailed,
            AgentIntegrationInstaller.gateIsActive(.ohMyPi)
        else { return nil }
        return l10n.t(
            "OMP approval wait budget is not active. Re-enable OMP to retry; approvals may time out sooner than expected."
        )
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
/// 刘海面板在 `.mainMenu + 3`，会盖住模态窗口；结束后还原层级。批量动作的确认弹窗、
/// 账号删除的确认弹窗与目录编辑器里的选择面板都要走这一步，因此抽在一起、而不是各抄一份。
///
/// `ignoresMouseEvents` **不写回快照**：展开态该不该接收鼠标是**随指针位置变化的**
/// （见 `NotchWindowController.updateMouseAcceptance`），模态前那个快照在指针已经离开
/// 卡片时就是错的——写回去会让面板重新吞掉屏顶 750pt 的滚轮/手势。因此改成发一条通知，
/// 让控制器按当前指针重算。
func withNotchPanelYielded<T>(_ body: () -> T) -> T {
    let notchWindow = NSApp.windows.first { $0 is NotchPanel }
    let originalLevel = notchWindow?.level ?? (.mainMenu + 3)
    notchWindow?.level = .normal
    notchWindow?.ignoresMouseEvents = true

    let result = body()

    notchWindow?.level = originalLevel
    NotificationCenter.default.post(name: .notchPanelYieldEnded, object: nil)
    return result
}
