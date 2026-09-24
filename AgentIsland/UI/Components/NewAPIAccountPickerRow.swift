//
//  NewAPIAccountPickerRow.swift
//  AgentIsland
//
//  「额度」页的账号行：左侧是当前账号名 + 展开箭头，右侧两个图标按钮（新增账号 /
//  删除当前账号）；展开后账号列表插在同一张卡片里，超过可见行数的在列表里滚动。
//
//  两处约束逼出来的写法：
//  * 账号列表**渲染全部账号**，只把可见高度按 `visibleOptions` 封顶（滚动交给列表）——
//    否则第 N+1 个账号在面板里永远够不着。
//  * 展开高度按**可见行数**算（不是固定 3 行）：只有一个账号时固定 3 行会在面板底部
//    留一截空白（音效列表不这样，是因为内置音效永远多于可见行数）。
//

import SwiftUI

/// 账号行：选择当前账号（展开列表）+ 增删账号。
struct NewAPIAccountPickerRow: View {
    @ObservedObject var viewModel: NewAPIBalanceViewModel
    @ObservedObject var selector: NewAPIAccountSelector
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale
    @State private var isRowHovered = false
    @State private var isAddHovered = false
    @State private var isRemoveHovered = false

    private var isExpanded: Bool { selector.isPickerExpanded }

    /// 展开后可见的账号数：超出部分在列表里滚动，面板不会被账号数量撑长。
    private var visibleOptionCount: Int {
        min(viewModel.accounts.count, NewAPIAccountSelector.visibleOptions)
    }

    var body: some View {
        VStack(spacing: 0) {
            row

            if isExpanded {
                options
                    .padding(.top, NotchMenuMetrics.optionListTopPadding)
                    .padding(.bottom, NotchMenuMetrics.optionListBottomPadding)
                    .padding(.leading, NotchMenuMetrics.optionIndent)
            }
        }
        .settingsRowSeparator(showsSeparator)
        // 账号增删时把可见行数写回选择器：它参与面板高度解析式（见 `NewAPIAccountSelector`）。
        .onAppear { selector.setAccountCount(viewModel.accounts.count) }
        .onChange(of: viewModel.accounts.count) { _, count in
            selector.setAccountCount(count)
        }
    }

    // MARK: - 主行

    private var row: some View {
        HStack(spacing: 0) {
            // 主按钮专门负责展开/收起；两个图标按钮是它的兄弟节点，不嵌套按钮。
            Button(action: toggle) {
                SettingsRowLabel(
                    badge: SettingsBadge(
                        source: .symbol(name: "person.crop.circle", tint: AppPalette.accent)),
                    title: l10n.t("Account")
                ) {
                    SettingsDisclosureValue(value: selectedName, isExpanded: isExpanded)
                }
                .background(isRowHovered ? AppPalette.rowHover : Color.clear)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .contentShape(Rectangle())
            .onHover { isRowHovered = $0 }

            iconButton(
                symbol: "plus",
                label: l10n.t("Add Account"),
                isHovered: $isAddHovered,
                action: viewModel.addAccount
            )

            // 只剩一个账号时不给删：页面上永远留着一个可编辑的账号（见视图模型）。
            if viewModel.canRemoveSelectedAccount {
                iconButton(
                    symbol: "minus",
                    label: l10n.t("Remove Account"),
                    isHovered: $isRemoveHovered,
                    action: viewModel.removeSelectedAccount
                )
            }
        }
        .frame(height: NotchMenuMetrics.rowHeight)
    }

    /// 行内的图标按钮：22pt 的方形悬停框，不改变行高。
    private func iconButton(
        symbol: String,
        label: String,
        isHovered: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppPalette.secondaryText)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovered.wrappedValue ? AppPalette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovered.wrappedValue = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }

    // MARK: - 选项列表

    private var options: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(viewModel.accounts) { account in
                    SettingsOptionRow(
                        label: newAPIAccountDisplayName(
                            account, index: index(of: account), l10n: l10n),
                        detail: detail(for: account),
                        isSelected: account.id == viewModel.selectedAccountID
                    ) {
                        viewModel.selectAccount(account.id)
                    }
                }
            }
        }
        .frame(height: CGFloat(visibleOptionCount) * NotchMenuMetrics.optionRowHeight)
    }

    /// 账号在列表里的位置（显示名兜底用序号，因此要按当前顺序算）。
    private func index(of account: NewAPIAccount) -> Int {
        viewModel.accounts.firstIndex { $0.id == account.id } ?? 0
    }

    /// 选项行右侧的补充：该账号的账户余额；没取到就写清为什么。
    private func detail(for account: NewAPIAccount) -> String {
        let reading = viewModel.reading(for: account).account
        if let value = reading.lastValue {
            // 这里必然是账户槽，而账户端点不给「不限额度」（见 `decodeAccountUsage`），
            // 因此不判 `unlimited`。
            return NewAPIBalanceFormat.quota(value.available, locale: locale)
        }
        switch reading {
        case .loading: return l10n.t("Loading…")
        case .needsAccessToken: return l10n.t("Needs an Access Token")
        case .needsAPIKey: return l10n.t("Needs an API Key")
        case .failed(let reason, _): return reason
        // `.value` 到不了这里（它的 `lastValue` 必非空，上面已经返回）；和「未配置」
        // 归在一起只是为了让 switch 穷举。
        case .notConfigured, .value: return l10n.t("Not configured")
        }
    }

    // MARK: - 文案

    /// 主行右侧的当前账号名。
    private var selectedName: String {
        let index = viewModel.accounts.firstIndex { $0.id == viewModel.selectedAccountID } ?? 0
        return newAPIAccountDisplayName(viewModel.selectedAccount, index: index, l10n: l10n)
    }

    private func toggle() {
        // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起面板里上一个展开块
        // （面板高度只按单个展开核对，见 `PickerExpansion`）。
        withAnimation(SettingsMotion.expand) {
            selector.toggleExpansion()
        }
    }
}

// MARK: - 显示名

/// 账号的显示名：备注名 → 服务器主机名 → 「账号 N」（空账号也要有个可认的名字）。
@MainActor
func newAPIAccountDisplayName(
    _ account: NewAPIAccount, index: Int, l10n: LocalizationManager
) -> String {
    let name = account.displayName
    return name.isEmpty ? l10n.t("Account %lld", index + 1) : name
}
