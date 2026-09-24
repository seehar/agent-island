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
}
