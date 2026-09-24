//
//  QuotaSettingsPage.swift
//  AgentIsland
//
//  「额度」页：New API 的**账号列表**（每个账号一行读数）+ 选中账号的详情
//  （身份 / 密钥额度 / 凭据）。与统计页同构——它是设置面板的一个分组
//  （`NotchMenuSection.quota`），因此**不套自己的滚动**（滚动由设置页接管），页眉右端
//  是「更新于 HH:MM + 刷新」（见 `QuotaRefreshControl`）。
//
//  版面与高度：账号卡 = 动作条（添加账号 / 编辑凭据）+ 每账号一行；详情卡 = 三行
//  （身份 / 密钥额度 / 凭据）+ 脚注。「编辑凭据」态下列表折叠成被编辑的那一行、三行读数
//  换成凭据表单——两段运行时高度都由 `NewAPIAccountPageState` 算成一个数，静态部分在
//  `NotchMenuMetrics.blocks(for: .quota)` 里（见 `NotchMenuMetricsTests` /
//  `UsageStatsLayoutTests`：真实排版必须等于解析式）。
//
//  应用不轮询：进页触一次（30 秒节流）+ 手动刷新，页眉的时间戳就是读数的新鲜度。
//

import SwiftUI

/// 「额度」页。
struct QuotaSettingsPage: View {
    @ObservedObject var viewModel: NewAPIBalanceViewModel
    @ObservedObject private var pageState = NewAPIAccountPageState.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            accountsGroup
            detailGroup
        }
        // 进页触一次拉取（30 秒节流；一个能查的账号都没有、或跑在测试宿主里直接返回），
        // 并把账号个数写回运行时状态（面板高度按它算）。进页一律回到读数态：编辑凭据是
        // 临时动作，上次留在编辑态会让再进来的用户以为配置被改了。
        .onAppear {
            if pageState.isPickerExpanded { pageState.toggleExpansion() }
            pageState.setAccountCount(viewModel.accounts.count)
            viewModel.onAppear()
        }
        .onChange(of: viewModel.accounts.count) { _, count in
            pageState.setAccountCount(count)
        }
    }

    // MARK: - 账号卡

    private var accountsGroup: some View {
        SettingsGroup(title: l10n.t("Account")) {
            QuotaActionRow(
                isEditing: pageState.isEditingCredentials,
                onAdd: viewModel.addAccount,
                onToggleEditing: toggleEditing
            )

            // 账号列表：渲染全部（否则第 N+1 个账号在面板里永远够不着），只把窗口高度按
            // `visibleAccountRows` 封顶，超出的在卡内滚动——与智能体卡同一条不变量。
            // 编辑态只留正在编辑的那一行：两个运行时增量因此不叠加（见 `NewAPIAccountPageState`）。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(renderedAccounts.enumerated()), id: \.element.id) {
                        position, account in
                        QuotaAccountRow(
                            account: account,
                            index: index(of: account),
                            reading: viewModel.reading(for: account),
                            isSelected: account.id == viewModel.selectedAccountID,
                            canRemove: viewModel.canRemoveSelectedAccount,
                            isInteractive: !pageState.isEditingCredentials,
                            onSelect: { viewModel.selectAccount(account.id) },
                            onRemove: viewModel.removeSelectedAccount
                        )
                    }
                }
            }
            .frame(height: NotchMenuMetrics.twoLineRowHeight * CGFloat(windowRowCount))
        }
    }

    /// 列表里画出来的账号：读数态是全部，编辑态只有正在编辑的那一个。
    private var renderedAccounts: [NewAPIAccount] {
        guard pageState.isEditingCredentials else { return viewModel.accounts }
        return [viewModel.selectedAccount]
    }

    /// 卡片窗口占几行（渲染行数由 `renderedAccounts` 给，与它独立）。
    private var windowRowCount: Int {
        guard !pageState.isEditingCredentials else { return 1 }
        return min(viewModel.accounts.count, NotchMenuMetrics.visibleAccountRows)
    }

    /// 账号在列表里的位置（显示名兜底用序号，因此要按当前顺序算）。
    private func index(of account: NewAPIAccount) -> Int {
        viewModel.accounts.firstIndex { $0.id == account.id } ?? 0
    }

    private func toggleEditing() {
        // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起面板里上一个展开块、收起时
        // 清掉互斥登记（面板高度只按单个展开核对，见 `PickerExpansion`）。
        withAnimation(SettingsMotion.expand) {
            pageState.toggleExpansion()
        }
    }

    // MARK: - 详情卡

    private var detailGroup: some View {
        SettingsGroup(
            title: detailTitle,
            footnote: l10n.t(
                "Amounts follow the instance's own currency setting; credentials are kept in this app's preferences."
            )
        ) {
            if pageState.isEditingCredentials {
                credentialsForm
            } else {
                identityRow
                keyBalanceRow
                credentialsRow
            }
        }
    }

    /// 详情卡的标题就是选中账号的名字（卡片里不再重复画一遍账号行）。
    private var detailTitle: String {
        newAPIAccountDisplayName(
            viewModel.selectedAccount, index: index(of: viewModel.selectedAccount), l10n: l10n)
    }

    /// 身份行：**这个令牌属于谁**——`/api/user/self` 的 `display_name` / `id` / `group`
    /// 加上分组倍率；右侧是累计请求数。凭据粘错时这是唯一能当场看出来的地方。
    private var identityRow: some View {
        SettingsRowLabel(
            badge: SettingsBadge(
                source: .symbol(name: "person.crop.circle", tint: AppPalette.accent)),
            title: identityTitle,
            subtitle: identitySubtitle
        ) {
            if let identity = reading.identity, identity.requestCount > 0 {
                Text(l10n.t("%lld requests", identity.requestCount))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundColor(AppPalette.tertiaryText)
            }
        }
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .settingsRowSeparator(true)
    }

    private var identityTitle: String {
        guard let identity = reading.identity, !identity.displayName.isEmpty else {
            return l10n.t("Account")
        }
        return identity.displayName
    }

    /// `#59 · default · 0.8x`；没有身份（缺令牌 / 取不到）时写账户槽的状态，
    /// 说的就是「为什么这里没有名字」。
    private var identitySubtitle: String {
        guard let identity = reading.identity else {
            return QuotaReadingSelection.statusText(
                reading.account, currency: reading.siteCurrency, locale: locale, l10n: l10n)
        }
        var parts = ["#\(identity.userID)"]
        if !identity.group.isEmpty {
            parts.append(groupRatioLabel(for: identity.group))
        }
        return parts.joined(separator: " · ")
    }

    /// 分组 + 倍率（`/api/user/self/groups` 的 `ratio`）；取不到倍率时只写分组名。
    private func groupRatioLabel(for group: String) -> String {
        guard let ratio = reading.groupRatio else { return group }
        return "\(group) \(String(format: "%gx", ratio))"
    }

    /// 密钥额度行：`/api/usage/token/` 的剩余 + 已用，有权威分母（`total_granted`）时画占比条。
    /// 匹配上 `/api/token/` 的条目时，副标题里带上令牌名——用户因此知道读的是哪一个 Key。
    private var keyBalanceRow: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .symbol(name: "key", tint: AppPalette.accent)),
            title: l10n.t("Key Balance"),
            subtitle: keySubtitle,
            subtitleColor: keySubtitleColor
        ) {
            VStack(alignment: .trailing, spacing: 5) {
                Text(keyValue)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(AppPalette.primaryText)

                if let ratio = keyProgressRatio {
                    QuotaProgressBar(ratio: ratio)
                        .frame(width: 72)
                }
            }
        }
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .settingsRowSeparator(true)
    }

    private var keyValue: String {
        if reading.token?.unlimited == true { return l10n.t("Unlimited") }
        return QuotaReadingSelection.value(
            reading.key, currency: reading.siteCurrency, locale: locale, l10n: l10n)
    }

    private var keySubtitle: String {
        let usage = QuotaReadingSelection.statusText(
            reading.key, currency: reading.siteCurrency, locale: locale, l10n: l10n)
        guard let token = reading.token, !token.name.isEmpty else { return usage }
        return l10n.t("Token %@", token.name) + " · " + usage
    }

    private var keySubtitleColor: Color {
        if case .failed = reading.key { return AppPalette.danger }
        return AppPalette.secondaryText
    }

    /// 已用 / 总额：只在有**权威分母**（Key 端点的 `total_granted`）且不是不限额度时画。
    /// 账户槽不画——它的 `used_quota` 是终身累计，与「剩余」不同量纲（`quota` 是余额）。
    private var keyProgressRatio: Double? {
        guard let value = reading.key.lastValue, !value.unlimited,
            let granted = value.granted, granted > 0
        else { return nil }
        return value.used / granted
    }

    /// 凭据行：实例地址 + 版本（`/api/status`）+ 已填凭据的尾号；没填访问令牌时写一句
    /// 「去哪儿生成」。点动作条上的「编辑凭据」进入表单。
    private var credentialsRow: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .symbol(name: "link", tint: AppPalette.accent)),
            title: l10n.t("Credentials"),
            subtitle: credentialsSubtitle
        ) {
            Text(maskedCredential)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundColor(AppPalette.tertiaryText)
        }
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .settingsRowSeparator(false)
    }

    private var credentialsSubtitle: String {
        let host = NewAPIAccount.host(from: viewModel.selectedAccount.config.trimmedServerURL)
        var parts: [String] = []
        if !host.isEmpty { parts.append(host) }
        // 缺访问令牌时写「去哪儿生成」——它比版本号更需要被看见；有令牌时反过来，写版本
        // （排查用，且此时不必再教用户去哪儿拿令牌）。两者都写会挤掉后一段（副标题单行截断）。
        if viewModel.selectedAccount.config.trimmedAccessToken.isEmpty {
            parts.append(l10n.t("Generate one in Profile → Security → Access Token"))
        } else if let version = reading.siteVersion, !version.isEmpty {
            parts.append(version)
        }
        return parts.isEmpty ? l10n.t("Not configured") : parts.joined(separator: " · ")
    }

    /// 凭据尾号掩码：让用户认得出「填的是哪一个」，但不满屏明文（明文要看点输入框旁的
    /// 眼睛按钮，那才是显式动作）。
    private var maskedCredential: String {
        let config = viewModel.selectedAccount.config
        if !config.trimmedAPIKey.isEmpty { return Self.mask(config.trimmedAPIKey) }
        if !config.trimmedAccessToken.isEmpty { return Self.mask(config.trimmedAccessToken) }
        return ""
    }

    /// 首 4 + `…` + 末 4（太短的值整体打点，别把短值原样露出来；空值给空串）。
    nonisolated static func mask(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        guard raw.count > 8 else { return String(repeating: "•", count: max(raw.count, 3)) }
        return raw.prefix(4) + "…" + raw.suffix(4)
    }

    /// 编辑态：五行凭据（账号名 / 服务器地址 / API 密钥 / 访问令牌 / 用户 ID）。
    /// 行数取字段表本身，因此加字段会自动长高（预算见 `NotchMenuMetrics.credentialFormHeight`）。
    private var credentialsForm: some View {
        ForEach(Array(credentialFields.enumerated()), id: \.offset) { position, entry in
            BalanceConfigRow(
                badge: entry.badge,
                title: entry.title,
                subtitle: entry.subtitle,
                text: binding(entry.field),
                isSecret: entry.isSecret,
                placeholder: entry.placeholder,
                showsSeparator: position < credentialFields.count - 1,
                fieldWidth: entry.fieldWidth,
                onSubmit: viewModel.commitConfig
            )
        }
    }

    /// 凭据表单的行表（顺序与 `NewAPIAccountField.allCases` 一致，高度按它推导）。
    private var credentialFields: [CredentialField] {
        [
            CredentialField(
                field: .label,
                badge: SettingsBadge(source: .symbol(name: "tag", tint: AppPalette.accent)),
                title: l10n.t("Account Name"),
                subtitle: l10n.t("Shown in the account list"),
                placeholder: l10n.t("Optional"),
                // 账号名与服务器地址是这一页最长的两条值（主机名或用户写的备注）：
                // 文本框给宽一档，否则 `https://your.newapi.host` 这类值会被截掉尾巴。
                fieldWidth: 246),
            CredentialField(
                field: .serverURL,
                badge: SettingsBadge(source: .symbol(name: "link", tint: AppPalette.accent)),
                title: l10n.t("Server URL"),
                subtitle: l10n.t("Only https:// is supported"),
                placeholder: l10n.t("https://api.example.com"),
                fieldWidth: 246),
            CredentialField(
                field: .apiKey,
                badge: SettingsBadge(source: .symbol(name: "key", tint: AppPalette.accent)),
                title: l10n.t("API Key"),
                subtitle: l10n.t("Used for the key balance"),
                isSecret: true,
                placeholder: l10n.t("sk-…")),
            CredentialField(
                field: .accessToken,
                badge: SettingsBadge(
                    source: .symbol(name: "person.crop.circle", tint: AppPalette.accent)),
                title: l10n.t("Access Token"),
                subtitle: l10n.t("Needed for the account balance"),
                isSecret: true,
                placeholder: l10n.t("Optional")),
            CredentialField(
                field: .userID,
                badge: SettingsBadge(source: .symbol(name: "number", tint: AppPalette.accent)),
                title: l10n.t("User ID"),
                subtitle: l10n.t("Needed by older New API versions"),
                placeholder: l10n.t("Optional")),
        ]
    }

    /// 一行凭据的静态描述（字段 + 文案 + 版面参数）。
    private struct CredentialField {
        let field: NewAPIAccountField
        let badge: SettingsBadge
        let title: String
        let subtitle: String
        var isSecret: Bool = false
        var placeholder: String = ""
        var fieldWidth: CGFloat = 150
    }

    // MARK: - 输入框绑定

    /// 输入框绑定：走视图模型的字段读写入口。选中账号在视图模型里，视图不自己找下标——
    /// 增删账号时下标会变，字段名不会。
    private func binding(_ field: NewAPIAccountField) -> Binding<String> {
        Binding(
            get: { viewModel.field(field) },
            set: { viewModel.setField(field, to: $0) }
        )
    }

    // MARK: - 读数

    /// 选中账号的读数。
    private var reading: NewAPIAccountReading { viewModel.selectedReading }
}

// MARK: - 页眉控件

/// 页眉右端的「更新于 HH:MM + 刷新」。位置由 `NotchMenuView.pageHeader` 给（与统计页的
/// 范围控件 + 重新统计按钮同一格），因此不占页面的行高。
struct QuotaRefreshControl: View {
    @ObservedObject var viewModel: NewAPIBalanceViewModel
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let refreshedAt = viewModel.snapshot.refreshedAt {
                HStack(spacing: 3) {
                    Text(l10n.t("Updated"))
                    // 时间不是文案：`Text(date, format:)` 按环境 locale 渲染，不走查表。
                    Text(refreshedAt, format: .dateTime.hour().minute())
                }
                .font(.system(size: 10))
                .foregroundColor(AppPalette.tertiaryText)
            }

            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(
                        width: UsageStatsMetrics.headerActionSize,
                        height: UsageStatsMetrics.headerActionSize
                    )
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            .fill(
                                isHovered && !viewModel.isRefreshing
                                    ? AppPalette.rowHover : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsCompactButtonStyle())
            .disabled(viewModel.isRefreshing)
            .onHover { isHovered = $0 }
            .help(l10n.t("Refresh"))
            .accessibilityLabel(Text(l10n.t("Refresh")))
        }
    }

    /// 图标色：刷新中（禁用）降到最弱一级，与设置面板其它禁用态同口径。
    private var tint: Color {
        if viewModel.isRefreshing { return AppPalette.subtleText }
        return isHovered ? AppPalette.primaryText : AppPalette.secondaryText
    }
}
