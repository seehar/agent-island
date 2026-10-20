//
//  NewAPIBalanceFormat.swift
//  AgentIsland
//
//  「额度」页的展示格式化（纯函数）：把 New API 的额度数字写成界面上的分组写法。
//  locale 一律由调用方传入——面板里的数字要跟着界面语言走
//  （`@Environment(\.locale)`），而 `NumberFormatter` / `Double.formatted()` 默认跟随
//  系统 locale，两处混用会出现「界面中文、数字英文」；传参同时也让用例能钉住确定的值。
//

import Foundation

/// 额度页的展示格式化。
nonisolated enum NewAPIBalanceFormat {
    /// 界面上的额度值：站点把额度显示成货币时按站点口径换算成钱（`$350.27`），
    /// 否则写内部单位（`175,134,432`）。
    ///
    /// 换算与平台页面同源（实例自己的 `quota ÷ quotaPerUnit × 汇率`，见
    /// `NewAPICurrency` 的注释），三种货币形态的排版也照抄平台前端：
    /// USD / CNY 是「符号紧贴数字」（`Intl` 的 `narrowSymbol`），CUSTOM 是「符号 + 空格 +
    /// 数字」，TOKENS 直接显示 token 数。
    static func display(_ quota: Double, currency: NewAPICurrency, locale: Locale) -> String {
        guard let formatted = Self.displayed(quota, currency: currency, locale: locale) else {
            return Self.quota(quota, locale: locale)
        }
        return formatted
    }

    /// 额度在界面上代表的**数字**（`display` 印出来的那个量）：站点把额度显示成钱时按站点
    /// 口径换算成钱，否则就是内部额度本身；不需要符号与分组。
    ///
    /// 存在的理由是**阈值比较**：额度提醒的阈值是用户照着页面上的数字设的（见
    /// `QuotaAlertSelector`），所以判断必须与显示同源。各处的 symbol / 空格 / 分组
    /// 排版仍只有 `display` 一处——这里只把「换算成什么量」抽出来给两处共用。
    static func displayedValue(_ quota: Double, currency: NewAPICurrency) -> Double {
        guard currency.displayInCurrency, currency.displayType != .tokens else { return quota }
        switch currency.displayType {
        case .tokens:
            return quota
        case .usd:
            return converted(quota, currency, rate: 1)
        case .cny:
            return converted(quota, currency, rate: currency.usdExchangeRate)
        case .custom:
            return converted(quota, currency, rate: currency.customExchangeRate)
        }
    }

    /// `display` 的排版部分（无符号 / 空格 / 分组口径时返回 nil，调用方退回 `quota(_:)`）。
    private static func displayed(
        _ quota: Double, currency: NewAPICurrency, locale: Locale
    ) -> String? {
        guard currency.displayInCurrency else { return nil }

        switch currency.displayType {
        case .tokens:
            return nil
        case .usd, .cny:
            let isCNY = currency.displayType == .cny
            let symbol = isCNY ? "¥" : "$"
            return symbol + Self.money(Self.displayedValue(quota, currency: currency), locale: locale)
        case .custom:
            let symbol = currency.customSymbol.trimmingCharacters(in: .whitespaces)
            let text = Self.money(
                Self.displayedValue(quota, currency: currency), locale: locale)
            return symbol.isEmpty ? text : symbol + " " + text
        }
    }

    /// 金额：千分位 + 最多两位小数（与平台前端的大额档位一致：`$350.27`、`$350`）。
    static func money(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 额度数字：整数分组（`1,234,567`），小数四舍五入到整数。
    ///
    /// 站点的显示类型是 `TOKENS`、或站点自己关掉了货币显示时走这里：额度是内部单位，
    /// 此时不做任何换算（与改造前一致）。
    static func quota(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }

    /// 额度 → 货币值：`quota ÷ quotaPerUnit × 汇率`。两个分母都做守卫（站点填 0 时按缺省）。
    private static func converted(
        _ quota: Double, _ currency: NewAPICurrency, rate: Double
    ) -> Double {
        let unit = currency.quotaPerUnit > 0 ? currency.quotaPerUnit : 500_000
        let safeRate = rate > 0 ? rate : 1
        return quota / unit * safeRate
    }
}
