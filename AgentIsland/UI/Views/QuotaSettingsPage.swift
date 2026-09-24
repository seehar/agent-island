//
//  QuotaSettingsPage.swift
//  AgentIsland
//
//  「额度」页：New API 的**账号列表**（服务器地址 / API Key / 访问令牌 / 用户 ID）与当前
//  选中账号的两个余额读数（账户余额、当前 Key 额度）。与统计页同构——它是设置面板的一个
//  分组（`NotchMenuSection.quota`），因此**不套自己的滚动**（滚动由设置页接管），页眉右端
//  是「更新于 HH:MM + 刷新」（见 `QuotaRefreshControl`）。
//
//  版面与高度：第一张卡片 = 账号行（展开的是账号列表，可见行数封顶在
//  `NewAPIAccountSelector.visibleOptions`）+ 五行凭据；第二张卡片 = 两行读数 + 脚注。
//  账号**数量**不参与面板高度（列表在选项块里滚动），因此 `blocks(for: .quota)` 可以
//  静态描述这一页（见 `NotchMenuMetricsTests`）。
//
//  应用不轮询：进页触一次（30 秒节流）+ 手动刷新，页眉的时间戳就是读数的新鲜度。
//

import SwiftUI

/// 「额度」页。
struct QuotaSettingsPage: View {
    @ObservedObject var viewModel: NewAPIBalanceViewModel
    @ObservedObject private var accountSelector = NewAPIAccountSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(title: l10n.t("New API")) {
                NewAPIAccountPickerRow(viewModel: viewModel, selector: accountSelector)

                BalanceConfigRow(
                    badge: SettingsBadge(source: .symbol(name: "tag", tint: AppPalette.accent)),
                    title: l10n.t("Account Name"),
                    subtitle: l10n.t("Shown in the account list"),
                    text: binding(.label),
                    placeholder: l10n.t("Optional"),
                    // 账号名是这一页最长的一条值（主机名或用户写的备注），文本框给它宽一档。
                    fieldWidth: 246,
                    onSubmit: viewModel.commitConfig
                )

                BalanceConfigRow(
                    badge: SettingsBadge(source: .symbol(name: "link", tint: AppPalette.accent)),
                    title: l10n.t("Server URL"),
                    subtitle: l10n.t("Only https:// is supported"),
                    text: binding(.serverURL),
                    placeholder: l10n.t("https://api.example.com"),
                    fieldWidth: 246,
                    onSubmit: viewModel.commitConfig
                )

                BalanceConfigRow(
                    badge: SettingsBadge(source: .symbol(name: "key", tint: AppPalette.accent)),
                    title: l10n.t("API Key"),
                    subtitle: l10n.t("Used for the key balance"),
                    text: binding(.apiKey),
                    isSecret: true,
                    placeholder: l10n.t("sk-…"),
                    onSubmit: viewModel.commitConfig
                )

                BalanceConfigRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "person.crop.circle", tint: AppPalette.accent)),
                    title: l10n.t("Access Token"),
                    subtitle: l10n.t("Needed for the account balance"),
                    text: binding(.accessToken),
                    isSecret: true,
                    placeholder: l10n.t("Optional"),
                    onSubmit: viewModel.commitConfig
                )

                BalanceConfigRow(
                    badge: SettingsBadge(source: .symbol(name: "number", tint: AppPalette.accent)),
                    title: l10n.t("User ID"),
                    subtitle: l10n.t("Needed by older New API versions"),
                    text: binding(.userID),
                    placeholder: l10n.t("Optional"),
                    showsSeparator: false,
                    onSubmit: viewModel.commitConfig
                )
            }

            SettingsGroup(
                title: l10n.t("Balance"),
                footnote: l10n.t(
                    "Quota is New API's internal unit; credentials are kept in this app's preferences."
                )
            ) {
                BalanceValueRow(
                    badge: SettingsBadge(
                        source: .symbol(name: "creditcard", tint: AppPalette.accent)),
                    title: l10n.t("Account Balance"),
                    reading: viewModel.selectedReading.account
                )
                BalanceValueRow(
                    badge: SettingsBadge(source: .symbol(name: "key", tint: AppPalette.accent)),
                    title: l10n.t("Key Balance"),
                    reading: viewModel.selectedReading.key,
                    showsSeparator: false
                )
            }
        }
        // 进页触一次拉取（30 秒节流；一个能查的账号都没有、或跑在测试宿主里直接返回）。
        .onAppear { viewModel.onAppear() }
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
}

// MARK: - 读数行

/// 一行余额读数：标题 + 用量（或失败原因）+ 尾随的剩余额度。
///
/// 刷新失败时**仍显示上次成功的数字**，副标题换成原因并用危险色——数字不会因为一次网络抖动
/// 被擦掉，用户也不会把它当成刚拿到的读数。
struct BalanceValueRow: View {
    let badge: SettingsBadge
    let title: String
    let reading: NewAPIBalanceReading
    var showsSeparator: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale

    var body: some View {
        SettingsRowLabel(
            badge: badge,
            title: title,
            subtitle: subtitle,
            subtitleColor: subtitleColor
        ) {
            Text(valueText)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(AppPalette.primaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .settingsRowSeparator(showsSeparator)
    }

    // MARK: - 内容

    /// 尾随数值：`—` 表示还没有读数（未配置 / 拉取中 / 失败且没有旧值）。
    private var valueText: String {
        guard let value = reading.lastValue else { return "—" }
        if value.unlimited { return l10n.t("Unlimited") }
        return NewAPIBalanceFormat.quota(value.available, locale: locale)
    }

    private var subtitle: String {
        switch reading {
        case .value(let value):
            return usageSubtitle(value)
        case .failed(let reason, _):
            return reason
        case .loading:
            return l10n.t("Loading…")
        case .needsAccessToken:
            return l10n.t("Needs an Access Token")
        case .needsAPIKey:
            return l10n.t("Needs an API Key")
        case .notConfigured:
            return l10n.t("Not configured")
        }
    }

    /// 副标题色：失败原因用危险色，其余用次级色。
    private var subtitleColor: Color {
        if case .failed = reading { return AppPalette.danger }
        return AppPalette.secondaryText
    }

    /// 用量说明：Key 端点给总额（`total_granted`），账户端点只有已用。
    private func usageSubtitle(_ value: NewAPIBalanceValue) -> String {
        let used = NewAPIBalanceFormat.quota(value.used, locale: locale)
        guard let granted = value.granted else { return l10n.t("Used %@", used) }
        return l10n.t(
            "Used %@ of %@", used, NewAPIBalanceFormat.quota(granted, locale: locale))
    }
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
