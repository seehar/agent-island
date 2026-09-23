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
    /// 额度数字：整数分组（`1,234,567`），小数四舍五入到整数。
    ///
    /// New API 的额度是内部单位（由实例配置决定，官方文档明确不得反推汇率），因此这里
    /// 只做分组，不做任何货币换算。
    static func quota(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }
}
