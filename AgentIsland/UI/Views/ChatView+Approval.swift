//
//  ChatView+Approval.swift
//  AgentIsland
//
//  ChatView 的审批与交互条家族：交互式提问提示条、审批条及其详情块、主按钮形态。
//
//  自 ChatView.swift 按渲染家族拆出，类型与可见性保持不变（同模块内 internal）。
//

import SwiftUI

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let agent: AgentKind
    let isInTmux: Bool
    let onGoToTerminal: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .appFont(12, weight: .medium, design: .monospaced)
                    .foregroundColor(TerminalColors.amber)
                Text(l10n.t("%@ needs your input", agent.displayName))
                    .appFont(11)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .appFont(11, weight: .medium)
                    Text(l10n.t("Terminal"))
                        .appFont(13, weight: .medium)
                }
                .foregroundColor(isInTmux ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Chat Approval Bar

/// 审批主按钮的形态。
///
/// 危险档（集成侧命中危险命令名单）**不能与常规档同形**：同一个位置、同一个词、
/// 同一个强调色会让「放行」变成肌肉记忆，危险命令被顺手点掉。抽成纯类型是为了把
/// 这条映射钉进单测（见 `ApprovalInteractionTests`）。
nonisolated enum ApprovalPrimaryAction: Equatable {
    /// 常规档：`.borderedProminent` + 「Allow」。
    case routine
    /// 危险档：`.bordered` + 危险色 + 「Run anyway」。
    case runAnyway

    init(isCritical: Bool) {
        self = isCritical ? .runAnyway : .routine
    }

    /// 是否用突出样式。只有常规档用——危险档保持描边，不抢主按钮位。
    var isProminent: Bool { self == .routine }
}

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    /// 要授权的输入的完整文本（不截断）；`nil` = 集成没带入参。
    let detail: String?
    /// 原始工具入参 JSON，供「详情」展开态显示。
    let rawInput: String?
    let display: PendingApprovalDisplay?
    let onApprove: () -> Void
    let onDeny: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 主按钮形态：危险档换文案、换样式、换色（见 `ApprovalPrimaryAction`）。
    private var primaryAction: ApprovalPrimaryAction {
        ApprovalPrimaryAction(isCritical: display?.isCritical == true)
    }

    /// 系统的「减弱动态效果」偏好：入场弹性经 `AppMotion` 换曲线。错峰的延迟**保留**——
    /// 命中区门禁（`approveButton`）跟的是「已显示」这个状态，不跟曲线。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Tool info
                VStack(alignment: .leading, spacing: 2) {
                    Text(MCPToolFormatter.formatToolName(tool))
                        .appFont(12, weight: .medium, design: .monospaced)
                        .foregroundColor(
                            display?.isCritical == true ? AppPalette.danger : TerminalColors.amber)
                    if let display, display.isCritical {
                        // 集成侧命中危险命令名单：与普通待批区分开，避免「看不出这次是危险的」
                        Text(l10n.t("Dangerous command"))
                            .appFont(11, weight: .medium)
                            .foregroundColor(AppPalette.danger)
                    }
                    if let display, display.terminalIsAsking {
                        Text(l10n.t("Asking in terminal"))
                            .appFont(11)
                            .foregroundColor(AppPalette.tertiaryText)
                    }
                    if let display, display.isGateDegraded {
                        Text(
                            display.degradedTier.map { l10n.t("Gate degraded: %@", $0) }
                                ?? l10n.t("Gate degraded")
                        )
                        .appFont(11)
                        .foregroundColor(AppPalette.warning)
                    }
                }
                .opacity(showContent ? 1 : 0)
                .offset(x: showContent ? 0 : -10)

                Spacer()

                // Deny button
                Button {
                    onDeny()
                } label: {
                    Text(l10n.t("Deny"))
                        .appFont(13, weight: .medium)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .opacity(showDenyButton ? 1 : 0)
                .scaleEffect(showDenyButton ? 1 : 0.8)
                // 与放行按钮同一条不变量：看不见的按钮不能接点击（见 `approveButton`）。
                .allowsHitTesting(showDenyButton)

                approveButton
            }

            // 要授权的输入在这里完整摊开：此前它只是标题下面一行 `lineLimit(1)` 的摘要，
            // Write/Edit 只看得见文件名、Bash 只看得见前 100 字——「看清再放行」在界面上
            // 根本做不到。整块与按钮行同宽，长路径/长命令才读得下去。
            if let detail {
                ApprovalDetailBlock(text: detail, rawInput: rawInput)
                    .opacity(showContent ? 1 : 0)
            }
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(
                AppMotion.pick(
                    .spring(response: 0.3, dampingFraction: 0.7), reduceMotion: reduceMotion
                ).delay(0.05)
            ) {
                showContent = true
            }
            withAnimation(
                AppMotion.pick(
                    .spring(response: 0.35, dampingFraction: 0.7), reduceMotion: reduceMotion
                ).delay(0.1)
            ) {
                showDenyButton = true
            }
            withAnimation(
                AppMotion.pick(
                    .spring(response: 0.35, dampingFraction: 0.7), reduceMotion: reduceMotion
                ).delay(0.15)
            ) {
                showAllowButton = true
            }
        }
    }

    /// 放行按钮。**命中区必须与可见性同步**：`opacity(0)` 不参与命中测试，淡入的这
    /// 100–150ms 里一枚看不见的按钮就能放行一次权限请求。`.allowsHitTesting` 是这条
    /// 不变量的落点，别把它当成多余的一行删掉。
    @ViewBuilder
    private var approveButton: some View {
        if primaryAction.isProminent {
            Button {
                onApprove()
            } label: {
                approveLabel(l10n.t("Allow"))
            }
            .buttonStyle(.borderedProminent)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
            .allowsHitTesting(showAllowButton)
        } else {
            Button {
                onApprove()
            } label: {
                approveLabel(l10n.t("Run anyway"))
            }
            .buttonStyle(.bordered)
            .tint(AppPalette.danger)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
            .allowsHitTesting(showAllowButton)
        }
    }

    private func approveLabel(_ text: String) -> some View {
        Text(text)
            .appFont(13, weight: .medium)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 审批输入块的高度算术（用于 `ApprovalDetailBlock`）。
///
/// 单独抽出来是为了可单测，也为了把「一行短路径不该撑出一片空白」写成不变量：
/// 里层的 `ScrollView` 是灵活的，让面板自己分高度的话，它会分走一大块（把对话区挤小）
/// 甚至留白。这里按估算的折行数给确定高度，超出上限才交给滚动。
nonisolated enum ApprovalDetailLayout {
    /// 11pt 等宽字的一行高度（pt）：系统行高约为字号的 1.2 倍，取 14 留一点余量，
    /// 免得估算偏小把最后一行裁掉。
    static let lineHeight: CGFloat = 14

    /// 块高 = 内容（估算）高，最多 `ToolOutputWindow.expandedMaxHeight`。
    static func height(for text: String) -> CGFloat {
        let lines = CGFloat(ToolOutputWindow.estimatedWrappedLineCount(of: text))
        return min(lines * lineHeight, ToolOutputWindow.expandedMaxHeight)
    }
}

/// 审批输入块：把「要授权的东西」完整摊开，再挂一层原始入参 JSON。
///
/// 高度是算出来的确定值（`ApprovalDetailLayout`），上限与工具输出的长文本同一档
/// （`ToolOutputWindow.expandedMaxHeight`），不另起常量：整条命令可能很长，但审批条
/// 不能把对话区撑满。
private struct ApprovalDetailBlock: View {
    let text: String
    /// `nil` = 没有原始入参（旧集成），不画详情开关。
    let rawInput: String?

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var showsRawInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: ApprovalDetailLayout.height(for: text))

            if let rawInput {
                if showsRawInput {
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(rawInput)
                            .appFont(10, design: .monospaced)
                            .foregroundColor(AppPalette.tertiaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: ApprovalDetailLayout.height(for: rawInput))
                }

                Button {
                    showsRawInput.toggle()
                } label: {
                    // 文案复用既有的「Show / Collapse」两条键：catalog 里没有「详情」这一条，
                    // 需要新键时先上报，不擅自往 catalog 里加（单写者纪律）。
                    Text(showsRawInput ? l10n.t("Collapse") : l10n.t("Show"))
                        .appFont(10, weight: .medium)
                        .foregroundColor(AppPalette.secondaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsCompactButtonStyle())
                .accessibilityLabel(Text(showsRawInput ? l10n.t("Collapse") : l10n.t("Show")))
            }
        }
    }
}
