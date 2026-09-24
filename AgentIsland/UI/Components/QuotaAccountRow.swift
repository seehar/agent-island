//
//  QuotaAccountRow.swift
//  AgentIsland
//
//  「额度」页的账号行与动作条：每个账号一行（名称 / 主机名 + 该账号的主读数 + 状态副行），
//  选中行用强调色勾与正文色标出；动作条一行放「添加账号」与「编辑凭据」。
//
//  两处约束：
//  * 行高固定 `twoLineRowHeight`——它参与面板高度解析式（`NewAPIAccountPageState`），
//    改行高要同时改那边，真实排版由 `UsageStatsLayoutTests` 兜住；
//  * 主读数取「账户余额优先，只有 Key 时才用密钥额度」：两个槽位各要各的凭据，
//    多数账号只填得起一个（否则会有一行恒为「—」，改造前就是这个样子）。
//

import SwiftUI

/// 一个账号行。
struct QuotaAccountRow: View {
    let account: NewAPIAccount
    let index: Int
    let reading: NewAPIAccountReading
    let isSelected: Bool
    /// 只剩一个账号时不给删（页面上永远留着一个可编辑的账号）。
    let canRemove: Bool
    /// 能否点选。编辑凭据态下列表折叠成一行，那一行只用来标示「正在编辑谁」。
    let isInteractive: Bool
    var onSelect: () -> Void = {}
    var onRemove: () -> Void = {}

    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale
    @State private var isHovered = false
    @State private var isRemoveHovered = false

    private var text: QuotaAccountRowText {
        QuotaAccountRowText(account: account, reading: reading, locale: locale, l10n: l10n)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 主按钮只管选中；删除按钮是它的兄弟节点，不嵌套按钮。
            Button(action: onSelect) {
                content
                    .frame(height: NotchMenuMetrics.twoLineRowHeight)
                    .background(
                        isHovered && isInteractive ? AppPalette.rowHover : Color.clear)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .disabled(!isInteractive)

            if isSelected && canRemove && isInteractive { removeButton }
        }
        .settingsRowSeparator(true)
    }

    // MARK: - 内容

    private var content: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .symbol(name: "globe", tint: AppPalette.accent)),
            title: newAPIAccountDisplayName(account, index: index, l10n: l10n),
            subtitle: text.subtitle,
            titleColor: isSelected ? AppPalette.primaryText : AppPalette.secondaryText,
            subtitleColor: text.isFailure ? AppPalette.danger : AppPalette.secondaryText
        ) {
            HStack(spacing: 6) {
                // 主读数是这一页的正文：15pt 等宽（与统计页小计同一档），行与行之间
                // 数字对得上；选中行只改明度，**不改字号**——否则逐行比较时数字不等大。
                Text(text.primary)
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(
                        isSelected ? AppPalette.primaryText : AppPalette.secondaryText)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppPalette.accent)
                }
            }
        }
    }

    /// 删除这一行（选中行才出现）：22pt 的方形悬停框，不改变行高。
    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppPalette.secondaryText)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isRemoveHovered ? AppPalette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isRemoveHovered = $0 }
        .help(l10n.t("Remove Account"))
        .accessibilityLabel(Text(l10n.t("Remove Account")))
    }
}

// MARK: - 动作条

/// 账号卡的动作条：左「添加账号」、右「编辑凭据 / 完成」。行高取 `rowHeight`。
struct QuotaActionRow: View {
    let isEditing: Bool
    let onAdd: () -> Void
    let onToggleEditing: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isAddHovered = false
    @State private var isEditHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAdd) {
                SettingsRowLabel(
                    badge: SettingsBadge(source: .symbol(name: "plus", tint: AppPalette.accent)),
                    title: l10n.t("Add Account")
                ) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isAddHovered ? AppPalette.rowHover : Color.clear)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .contentShape(Rectangle())
            .onHover { isAddHovered = $0 }

            Button(action: onToggleEditing) {
                Text(isEditing ? l10n.t("Done") : l10n.t("Edit Credentials"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isEditing ? AppPalette.accent : AppPalette.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            .fill(isEditHovered ? AppPalette.rowHover : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsCompactButtonStyle())
            .onHover { isEditHovered = $0 }
            .accessibilityLabel(Text(isEditing ? l10n.t("Done") : l10n.t("Edit Credentials")))
            .padding(.trailing, NotchMenuMetrics.rowHorizontalPadding)
        }
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(true)
    }
}

// MARK: - 占比条

/// 额度占比条：已用 / 总额。**只用在有权威分母的地方**（Key 端点的 `total_granted`）。
struct QuotaProgressBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppPalette.segmentedTrack)

                Capsule(style: .continuous)
                    .fill(AppPalette.accent)
                    .frame(width: max(0, min(1, ratio)) * geometry.size.width)
            }
        }
        .frame(height: UsageStatsMetrics.shareBarHeight)
        .accessibilityHidden(true)
    }
}

// MARK: - 文案

/// 一个账号行的文案：主读数 + 副行（另一槽的状态）+ 副行是不是失败态。
///
/// 拆出来是为了让「取哪个槽当主读数」这条规则能被用例钉住（见 `QuotaAccountRowTests`）：
/// 它是这一页最容易悄悄回归的地方（两个槽位各自要各自的凭据，只有一边能读是常态）。
@MainActor
struct QuotaAccountRowText {
    let primary: String
    let subtitle: String
    let isFailure: Bool

    init(
        account: NewAPIAccount,
        reading: NewAPIAccountReading,
        locale: Locale,
        l10n: LocalizationManager
    ) {
        let slot = QuotaReadingSelection.primarySlot(reading)
        primary = QuotaReadingSelection.primaryValue(
            reading, locale: locale, l10n: l10n)
        // 副行 = 主机名 +（另一槽**有内容**时才写它的用量或失败原因）。
        // 缺凭据 / 未配置是预期内的空——「拿不到数据的就不要展示」，不再写「需要 X」
        // （见 `QuotaReadingSelection.isVisible`）。
        let other = slot == .key ? reading.account : reading.key
        // 有内容时才写：用量走**紧凑写法**（副行单行会中部截断），失败只写原因。
        let otherText: String
        switch other {
        case .value(let value):
            otherText = QuotaReadingSelection.compactUsage(
                value, currency: reading.siteCurrency, locale: locale, l10n: l10n)
        case .failed(let reason, _):
            otherText = reason
        case .loading, .notConfigured, .needsAccessToken, .needsAPIKey:
            otherText = ""
        }
        let host = NewAPIAccount.host(from: account.config.trimmedServerURL)
        let parts = [host, otherText].filter { !$0.isEmpty }
        // 两者都空（空账号，或只填了凭据没填地址）：写一句「未配置」当唯一指引，
        // 否则这一行只剩一个名字。
        subtitle = parts.isEmpty ? l10n.t("Not configured") : parts.joined(separator: " · ")
        if case .failed = other, QuotaReadingSelection.isVisible(other) {
            isFailure = true
        } else {
            isFailure = false
        }
    }
}

/// 读数选择与状态文案（纯规则 + 文案）。
@MainActor
enum QuotaReadingSelection {
    /// 主读数取哪个槽。
    enum Slot: Equatable {
        case account
        case key
        /// 两个槽都没有数值（未配置 / 缺凭据 / 正在拉取 / 失败且没有旧值）。
        case none
    }

    /// 账户余额优先，只有 Key 时才用密钥额度。
    ///
    /// 账户端点不一定可查（它要访问令牌），Key 端点也不一定（它要 `sk-`）；多数账号只填得
    /// 起一个，因此主读数必须是「能读的那个」，而不是固定的一行。
    nonisolated static func primarySlot(_ reading: NewAPIAccountReading) -> Slot {
        if reading.account.lastValue != nil { return .account }
        if reading.key.lastValue != nil { return .key }
        return .none
    }

    /// 这一槽的内容**该不该出现在界面上**：拿到数据、或取数出错（要给原因）才画。
    ///
    /// 「拿不到数据的就不要展示」——缺凭据（`needsAPIKey` / `needsAccessToken`）与未配置是
    /// 预期内的空：平台只给 `sk-` 时没有账号数据、只给访问令牌时没有密钥额度，对应那一行/
    /// 那句话整块不画，而不是画一行「需要 X」。正在拉取也不画：先占位再消失比「数据到了才
    /// 出现」更跳。
    nonisolated static func isVisible(_ reading: NewAPIBalanceReading) -> Bool {
        switch reading {
        case .value, .failed: return true
        case .loading, .notConfigured, .needsAccessToken, .needsAPIKey: return false
        }
    }

    /// 详情卡里「账号」那一段要不要画（它看账户槽：只有令牌的账号才有）。
    nonisolated static func showsAccountSection(_ reading: NewAPIAccountReading) -> Bool {
        isVisible(reading.account)
    }

    /// 详情卡里「密钥额度」那一段要不要画（它看 Key 槽：只有 `sk-` 的账号才有）。
    nonisolated static func showsKeySection(_ reading: NewAPIAccountReading) -> Bool {
        isVisible(reading.key)
    }

    /// 详情卡可选行的行数（0…2），写回 `NewAPIAccountPageState` 供面板高度解析式使用。
    ///
    /// 页面渲染与写回走**同一个**函数，因此「画了几行」与「算了几行」不会漂移；真实排版与
    /// 解析式的一致性由 `UsageStatsLayoutTests` 的 fittingSize 用例兜住。
    nonisolated static func optionalDetailRowCount(_ reading: NewAPIAccountReading) -> Int {
        (showsAccountSection(reading) ? 1 : 0) + (showsKeySection(reading) ? 1 : 0)
    }

    /// 主读数的值（`—` 表示还没有数）。
    static func primaryValue(
        _ reading: NewAPIAccountReading, locale: Locale, l10n: LocalizationManager
    ) -> String {
        switch primarySlot(reading) {
        case .account:
            return Self.value(
                reading.account, currency: reading.siteCurrency, locale: locale, l10n: l10n)
        case .key:
            return Self.value(
                reading.key, currency: reading.siteCurrency, locale: locale, l10n: l10n)
        case .none: return "—"
        }
    }

    /// 一个槽位的数值：`—` / 「不限额度」/ 按实例口径换算的金额。
    static func value(
        _ reading: NewAPIBalanceReading, currency: NewAPICurrency, locale: Locale,
        l10n: LocalizationManager
    ) -> String {
        guard let value = reading.lastValue else { return "—" }
        if value.unlimited { return l10n.t("Unlimited") }
        return NewAPIBalanceFormat.display(value.available, currency: currency, locale: locale)
    }

    /// 一个槽位的状态说明：用量 / 缺什么 / 失败原因。
    ///
    /// 失败时数值仍留在 `value(_:)` 里（上次数值），这里只说原因——一次网络抖动不该把数字
    /// 擦掉，用户也不会把它当成刚拿到的读数（与改造前同一口径）。
    static func statusText(
        _ reading: NewAPIBalanceReading, currency: NewAPICurrency, locale: Locale,
        l10n: LocalizationManager
    ) -> String {
        switch reading {
        case .value(let value):
            return Self.usage(value, currency: currency, locale: locale, l10n: l10n)
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

    /// 用量说明：Key 端点给总额（`total_granted`），账户端点只有已用。
    ///
    /// **不限额度**时不写总额：那个分母对「无限」没有意义，会写出「已用 $16,222 / 总额
    /// $15,934」这种看起来矛盾的一行（真机实测）。
    static func usage(
        _ value: NewAPIBalanceValue, currency: NewAPICurrency, locale: Locale,
        l10n: LocalizationManager
    ) -> String {
        let used = NewAPIBalanceFormat.display(value.used, currency: currency, locale: locale)
        guard let granted = value.granted, !value.unlimited else { return l10n.t("Used %@", used) }
        return l10n.t(
            "Used %@ of %@", used,
            NewAPIBalanceFormat.display(granted, currency: currency, locale: locale))
    }

    /// 账号行副行里的用量：只写「已用」，不写总额。
    ///
    /// 副行是单行 + **中部截断**，写全「已用 X / 总额 Y」会被截掉尾巴（真机实测：
    /// `calciumion.nbops.com · …$16,222.23 / 总额 $15,934.81`）。完整口径留在详情卡里。
    static func compactUsage(
        _ value: NewAPIBalanceValue, currency: NewAPICurrency, locale: Locale,
        l10n: LocalizationManager
    ) -> String {
        let used = NewAPIBalanceFormat.display(value.used, currency: currency, locale: locale)
        return l10n.t("Used %@", used)
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
