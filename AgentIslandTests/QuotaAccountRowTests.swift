//
//  QuotaAccountRowTests.swift
//  AgentIslandTests
//
//  额度页账号行的**读数选择**规则：主读数取「能读的那一槽」（账户余额优先，只有 Key 时
//  才用密钥额度），以及凭据尾号掩码。
//
//  两个槽位各要各的凭据（账户槽要访问令牌、Key 槽要 `sk-`），因此「只有一边能读」是常态：
//  改造前是固定两行读数，无论切到哪个账号都有一行恒为「—」——这条规则一旦回归就会重现，
//  所以它单独有用例。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("额度页账号行")
struct QuotaAccountRowTests {
    private func slot(
        _ available: Double, used: Double = 10, granted: Double? = nil, unlimited: Bool = false
    ) -> NewAPIBalanceReading {
        .value(
            NewAPIBalanceValue(
                available: available, used: used, granted: granted, unlimited: unlimited))
    }

    @Test("两个槽都能读时，主读数取账户余额（这才是「我的钱」）")
    func prefersAccountBalanceWhenBothReadable() {
        let reading = NewAPIAccountReading(account: slot(350), key: slot(120))
        #expect(QuotaReadingSelection.primarySlot(reading) == .account)
    }

    @Test("只有 Key 能读时，主读数退到密钥额度（只填 sk- 的账号是常态）")
    func fallsBackToKeyBalance() {
        var reading = NewAPIAccountReading(account: .needsAccessToken, key: slot(120))
        #expect(QuotaReadingSelection.primarySlot(reading) == .key)

        // 失败但留着上次数值：仍然算「能读」——数字不该因为一次网络抖动消失。
        reading = NewAPIAccountReading(
            account: .failed(reason: "x", value: nil),
            key: .failed(reason: "x", value: slot(7).lastValue))
        #expect(QuotaReadingSelection.primarySlot(reading) == .key)
    }

    @Test("两个槽都没有数值时没有主读数（未配置 / 缺凭据 / 正在拉取 / 失败无旧值）")
    func noPrimaryWithoutValues() {
        let states: [NewAPIBalanceReading] = [
            .notConfigured,
            .needsAccessToken,
            .needsAPIKey,
            .loading,
            .failed(reason: "x", value: nil),
        ]

        for state in states {
            let reading = NewAPIAccountReading(account: state, key: state)
            #expect(
                QuotaReadingSelection.primarySlot(reading) == .none,
                "「\(state)」不该产生主读数")
        }
    }

    @Test("凭据掩码保留首尾各 4 位，短值整体打点，空值给空串")
    func credentialMaskKeepsBothEnds() {
        #expect(QuotaSettingsPage.mask("sk-9abcdefgXYZ") == "sk-9…gXYZ")
        #expect(QuotaSettingsPage.mask("sk-abc") == "••••••")
        #expect(QuotaSettingsPage.mask("") == "")
    }

    @Test("拿不到数据的槽不展示：缺凭据 / 未配置 / 拉取中都不画，有数据或失败才画")
    func hiddenWhenSlotHasNoData() {
        // 「拿不到数据的就不要展示」：这些状态是**预期内的空**，画出来只会是一行
        //「需要 X」——平台只给 sk- 时没有账号数据、只给访问令牌时没有密钥额度。
        let hidden: [NewAPIBalanceReading] = [
            .notConfigured, .needsAccessToken, .needsAPIKey, .loading,
        ]
        for state in hidden {
            #expect(
                QuotaReadingSelection.isVisible(state) == false,
                "「\(state)」不该展示")
        }

        // 有数据、或取数出错（要给原因）才展示。
        #expect(QuotaReadingSelection.isVisible(slot(1)))
        #expect(
            QuotaReadingSelection.isVisible(.failed(reason: "boom", value: nil)),
            "失败要说原因，否则用户不知道发生了什么")
        #expect(
            QuotaReadingSelection.isVisible(.failed(reason: "boom", value: slot(1).lastValue)),
            "失败但有上次数值：数字仍要显示")
    }

    @Test("详情卡可选行数：只有 sk- 的账号没有账号段，只有令牌的账号没有密钥段")
    func optionalDetailRowsFollowCredentials() {
        // 只填访问令牌（账户端点有数据、Key 槽缺凭据）⇒ 只剩身份行。
        let tokenOnly = NewAPIAccountReading(account: slot(350), key: .needsAPIKey)
        #expect(QuotaReadingSelection.optionalDetailRowCount(tokenOnly) == 1)
        #expect(QuotaReadingSelection.showsAccountSection(tokenOnly))
        #expect(QuotaReadingSelection.showsKeySection(tokenOnly) == false)

        // 只填 sk-（Key 端点有数据、账户槽缺凭据）⇒ 只剩密钥额度行。
        let keyOnly = NewAPIAccountReading(account: .needsAccessToken, key: slot(120))
        #expect(QuotaReadingSelection.optionalDetailRowCount(keyOnly) == 1)
        #expect(QuotaReadingSelection.showsAccountSection(keyOnly) == false)
        #expect(QuotaReadingSelection.showsKeySection(keyOnly))

        // 两个槽都能读 ⇒ 两行都在；一个都读不到（空账号 / 两个凭据都没填）⇒ 一行都不画，
        // 详情卡只剩「凭据」那一行（它是配置摘要与编辑入口）。
        let both = NewAPIAccountReading(account: slot(1), key: slot(2))
        #expect(QuotaReadingSelection.optionalDetailRowCount(both) == 2)

        let neither = NewAPIAccountReading(account: .notConfigured, key: .notConfigured)
        #expect(QuotaReadingSelection.optionalDetailRowCount(neither) == 0)

        // 上限与版面上限同源：可选行不会超过 `quotaDetailOptionalRowsMax`。
        #expect(
            QuotaReadingSelection.optionalDetailRowCount(both)
                <= NotchMenuMetrics.quotaDetailOptionalRowsMax)
    }

    @Test("用量写法：不限额度不写总额；账号行副行只写「已用」")
    func usageTextRules() {
        let l10n = LocalizationManager.shared
        let locale = Locale(identifier: "zh-Hans")
        // 不限额度但服务端仍给了 total_granted（真机上的 lixh03 令牌就是这样：已用 $16,222 /
        // 总额 $15,934，「已用 > 总额」看着自相矛盾）。
        let unlimited = NewAPIBalanceValue(
            available: 500, used: 16_222, granted: 15_934, unlimited: true)
        let limited = NewAPIBalanceValue(
            available: 600, used: 400, granted: 1_000, unlimited: false)

        let unlimitedText = QuotaReadingSelection.usage(
            unlimited, currency: .rawQuota, locale: locale, l10n: l10n)
        #expect(unlimitedText.contains("16,222"), "已用要照写")
        #expect(unlimitedText.contains("15,934") == false, "不限额度时不该出现总额")

        let limitedText = QuotaReadingSelection.usage(
            limited, currency: .rawQuota, locale: locale, l10n: l10n)
        #expect(limitedText.contains("400") && limitedText.contains("1,000"), "有限额时两者都写")

        // 账号行副行是单行 + 中部截断，因此一律只写已用（完整口径留在详情卡）。
        for value in [unlimited, limited] {
            let compact = QuotaReadingSelection.compactUsage(
                value, currency: .rawQuota, locale: locale, l10n: l10n)
            #expect(compact.contains(NewAPIBalanceFormat.display(
                value.used, currency: .rawQuota, locale: locale)))
            #expect(compact.contains("总额") == false && compact.contains(" of ") == false)
        }
    }

    @Test("账号行副行：不再写「需要 X」，另一槽没数据时只写主机名")
    func rowSubtitleSkipsMissingCredentialHints() {
        let account = NewAPIAccount(
            label: "海外", config: NewAPIConfig(serverURL: "https://h.example.com"))
        let l10n = LocalizationManager.shared
        let locale = Locale(identifier: "zh-Hans")

        // 只填 sk-：账户槽缺凭据 ⇒ 副行只有主机名（主读数是密钥额度）。
        let keyOnly = NewAPIAccountReading(account: .needsAccessToken, key: slot(120))
        let text = QuotaAccountRowText(
            account: account, reading: keyOnly, locale: locale, l10n: l10n)
        #expect(text.subtitle == "h.example.com")
        #expect(text.isFailure == false)

        // 只填令牌：Key 槽缺凭据 ⇒ 副行同样只有主机名（主读数是账户余额）。
        let tokenOnly = NewAPIAccountReading(account: slot(350), key: .needsAPIKey)
        #expect(
            QuotaAccountRowText(account: account, reading: tokenOnly, locale: locale, l10n: l10n)
                .subtitle == "h.example.com")

        // 另一槽有数据 ⇒ 追加它的用量；失败 ⇒ 追加原因并用危险色。
        let both = NewAPIAccountReading(account: slot(350), key: slot(120, used: 30, granted: 200))
        let bothText = QuotaAccountRowText(
            account: account, reading: both, locale: locale, l10n: l10n)
        #expect(bothText.subtitle.hasPrefix("h.example.com · "))

        let failed = NewAPIAccountReading(
            account: slot(350), key: .failed(reason: "boom", value: nil))
        let failedText = QuotaAccountRowText(
            account: account, reading: failed, locale: locale, l10n: l10n)
        #expect(failedText.subtitle == "h.example.com · boom")
        #expect(failedText.isFailure)

        // 空账号：没有主机名也没有数据 ⇒ 写一句「未配置」当唯一指引。
        let blank = NewAPIAccount()
        #expect(
            QuotaAccountRowText(
                account: blank, reading: NewAPIAccountReading(), locale: locale, l10n: l10n
            ).subtitle == l10n.t("Not configured"))
    }
}
