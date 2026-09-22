//
//  UsageStatsFormat.swift
//  AgentIsland
//
//  统计页的展示格式化：窗口标题、范围读数、坐标轴刻度、悬停桶标签、月历的月名与周名。
//  日期一律按**界面语言**（调用方传入的 `locale`）格式化，不读系统 locale——界面语言
//  可以在运行期切换，而 `DateFormatter` 默认跟随系统，两处混用会出现「界面中文、日期英文」。
//

import Foundation

/// 统计页的展示格式化（纯函数）。
nonisolated enum UsageStatsFormat {
    /// 预设档的档名。语言显式传入（默认取已持久化的界面语言）：测试因此能分别断言两侧
    /// 的译文，而不是「解析不到、回落成 key」也算通过。
    ///
    /// 键保持字面量（本地化守卫据此审计「哪些键被引用」），查表走
    /// `LocalizationManager.t(_:languageCode:)`。
    static func presetTitle(
        _ range: StatsRange, languageCode: String = AppSettings.language.resolvedCode
    ) -> String {
        switch range {
        case .lastDay: return LocalizationManager.t("Last 24h", languageCode: languageCode)
        case .lastWeek: return LocalizationManager.t("Last 7d", languageCode: languageCode)
        case .lastMonth: return LocalizationManager.t("Last 30d", languageCode: languageCode)
        case .today: return LocalizationManager.t("Today", languageCode: languageCode)
        case .week: return LocalizationManager.t("This Week", languageCode: languageCode)
        case .month: return LocalizationManager.t("This Month", languageCode: languageCode)
        case .all: return LocalizationManager.t("All", languageCode: languageCode)
        }
    }

    /// 页眉控件上的窗口标题：预设给档名，自选给「起 – 止」。
    static func windowTitle(_ window: StatsWindow, locale: Locale) -> String {
        switch window {
        case .preset(let range):
            return presetTitle(range)
        case .custom(let from, let to):
            return customRange(from: from, to: to, locale: locale)
        }
    }

    /// 自选范围的读数（如「9月1日 – 9月20日」）。跨年时两端都带年份——
    /// 否则「12月28日 – 1月3日」看不出跨了年。
    static func customRange(from: Date, to: Date, locale: Locale) -> String {
        let range = UsageStatsCalendar.normalized(from, to)
        let calendar = Calendar.current
        let sameYear =
            calendar.component(.year, from: range.from) == calendar.component(.year, from: range.to)
        let style =
            sameYear
            ? Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
            : Date.FormatStyle.dateTime.year().month(.abbreviated).day().locale(locale)
        return "\(range.from.formatted(style)) – \(range.to.formatted(style))"
    }

    /// 横轴刻度：小时粒度给钟点，日粒度给日期。
    static func axisLabel(_ date: Date, granularity: TrendGranularity, locale: Locale) -> String {
        switch granularity {
        case .hour:
            return date.formatted(.dateTime.hour().minute().locale(locale))
        case .day:
            return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        }
    }

    /// 悬停读数的桶标签：小时粒度带钟点，日粒度只有日期。
    static func bucketLabel(_ date: Date, granularity: TrendGranularity, locale: Locale) -> String {
        switch granularity {
        case .hour:
            return date.formatted(
                .dateTime.month(.abbreviated).day().hour().minute().locale(locale))
        case .day:
            return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        }
    }

    /// 月历的月份标题（en "September 2026" / zh-Hans "2026年9月"）。
    static func monthTitle(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.year().month(.wide).locale(locale))
    }

    /// 月历的周标题：按 `calendar.firstWeekday` 顺序的 7 个短名（en "Mon" / zh-Hans "周一"）。
    /// 符号取自 locale 驱动的 `DateFormatter`——`Calendar.shortWeekdaySymbols` 跟随系统
    /// locale，与运行期切换的界面语言不是一回事；解析不到时退回日历自带的那份。
    static func weekdaySymbols(locale: Locale, calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? calendar.shortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }

        let offset = calendar.firstWeekday - 1
        guard offset > 0 else { return symbols }
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    /// 月历格子里的一天：只显示日号（按界面语言的数字写法，不带「日」这类后缀）。
    static func dayNumber(_ date: Date, locale: Locale) -> String {
        Calendar.current.component(.day, from: date).formatted(.number.locale(locale))
    }
}
