//
//  UsageHeatmap.swift
//  AgentIsland
//
//  每日用量热力图（GitHub 贡献图那种）：近 `UsageStatsCalendar.heatmapWeekCount` 周、
//  一格一个自然日、深浅按当日总量分五档（口径在 `UsageHeatmapScale`）。
//
//  它是**固定窗口**：不跟随统计页的范围选择器。一次查询里两种窗口并存是有意的
//  （见 `UsageStatsSnapshot.daily`）——折线看「选定范围的走势」，这里看「近半年的节律」。
//  格子与日期由 `UsageStatsCalendar.heatmapWeeks` 给出（行序按 `calendar.firstWeekday`，
//  与月历同一个约定），视图只做「日期 → 颜色 / 读数」的映射。
//
//  网格宽度吃满可用宽度（格宽 = 可用宽等分，与曲线图的绘图区同一条原则）：面板在紧凑档
//  或窄屏上会比上限窄，写死格宽会把整页撑破、落进面板后被裁掉两侧。格**高**固定
//  (`heatmapCellHeight`)，因此整块高度不随宽度变——面板高度的解析式里算的就是它。
//

import SwiftUI

/// 每日用量热力图。
struct UsageHeatmap: View {
    /// 每日总量（稀疏、升序）。来自 `UsageStatsSnapshot.daily`。
    let days: [DayUsage]
    /// 「今天」：末列是包含它的那一周，它之后的格子不画。默认当前时刻；用例传定值。
    var now: Date = Date()
    /// 分桶与排格用的日历（与数据层查询用的是同一份）。
    var calendar: Calendar = .current

    @ObservedObject private var l10n = LocalizationManager.shared
    /// 日期与数字的格式化跟随界面语言（由根视图的 LocalizedRoot 注入环境 locale）。
    @Environment(\.locale) private var locale

    var body: some View {
        // 一次算好格子、每日总量索引与分档阈值：逐格去建字典会让 182 个格子各重建一次。
        let weeks = UsageStatsCalendar.heatmapWeeks(containing: now, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)
        let totals = Dictionary(
            days.map { ($0.dayKey, $0.total) }, uniquingKeysWith: { first, _ in first })
        let thresholds = UsageHeatmapScale.thresholds(of: days.map(\.total))

        VStack(alignment: .leading, spacing: UsageStatsMetrics.heatmapCaptionSpacing) {
            grid(weeks: weeks, todayStart: todayStart, totals: totals, thresholds: thresholds)
            captionRow
        }
    }

    // MARK: - 网格

    /// 26 列（每列一周）× 7 行：列吃满可用宽度、格高与间距固定，整块高度因此恒定。
    private func grid(
        weeks: [[Date]], todayStart: Date, totals: [String: Int], thresholds: [Int]
    ) -> some View {
        HStack(spacing: UsageStatsMetrics.heatmapCellSpacing) {
            ForEach(weeks.indices, id: \.self) { column in
                VStack(spacing: UsageStatsMetrics.heatmapCellSpacing) {
                    ForEach(weeks[column].indices, id: \.self) { row in
                        cell(
                            for: weeks[column][row], todayStart: todayStart, totals: totals,
                            thresholds: thresholds)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: UsageStatsMetrics.heatmapGridHeight, alignment: .top)
    }

    /// 一格：未来（今天之后）的格子不画；其余按档位填色，悬停给出「日期 · 当日总量」。
    @ViewBuilder
    private func cell(
        for date: Date, todayStart: Date, totals: [String: Int], thresholds: [Int]
    ) -> some View {
        if let total = total(for: date, todayStart: todayStart, totals: totals) {
            let text = readout(for: date, total: total)
            RoundedRectangle(cornerRadius: UsageStatsMetrics.heatmapCellRadius, style: .continuous)
                .fill(
                    ChartPalette.heatmapLevels[
                        UsageHeatmapScale.level(total: total, thresholds: thresholds)]
                )
                .frame(height: UsageStatsMetrics.heatmapCellHeight)
                .help(text)
                .accessibilityLabel(Text(text))
        } else {
            // 未来：占位但不画（同一列的各行仍然对齐），也不给悬停读数。
            Color.clear
                .frame(height: UsageStatsMetrics.heatmapCellHeight)
        }
    }

    /// 一格的用量：未来格子给 `nil`；没有记录的日子按 0（数据层只给有用量的日子）。
    private func total(for date: Date, todayStart: Date, totals: [String: Int]) -> Int? {
        guard date <= todayStart else { return nil }
        return totals[UsageStatsKey.bucket(for: date, granularity: .day, calendar: calendar)] ?? 0
    }

    // MARK: - 读数行

    /// 读数行：左边说清这块量的是什么、窗口多大；右边是「浅 → 深」的图例。
    private var captionRow: some View {
        HStack(spacing: 8) {
            Text(l10n.t("Tokens per day · last %lld weeks", UsageStatsCalendar.heatmapWeekCount))
                .appFont(10)
                .foregroundColor(AppPalette.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            legend
        }
        .frame(height: UsageStatsMetrics.heatmapCaptionHeight)
    }

    /// 图例：五格色阶（含空档）+ 两端的「少 / 多」。
    private var legend: some View {
        HStack(spacing: 4) {
            Text(l10n.t("Less"))
                .appFont(9)
                .foregroundColor(AppPalette.subtleText)

            ForEach(ChartPalette.heatmapLevels.indices, id: \.self) { level in
                RoundedRectangle(
                    cornerRadius: UsageStatsMetrics.heatmapLegendSwatchRadius, style: .continuous
                )
                .fill(ChartPalette.heatmapLevels[level])
                .frame(
                    width: UsageStatsMetrics.heatmapLegendSwatchSize,
                    height: UsageStatsMetrics.heatmapLegendSwatchSize)
            }

            Text(l10n.t("More"))
                .appFont(9)
                .foregroundColor(AppPalette.subtleText)
        }
    }

    // MARK: - 格式化

    /// 一格的悬停读数：日期 + 当日总量（数字用页面上同一份短格式）。
    private func readout(for date: Date, total: Int) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        return l10n.t("%@ · %@ tokens", day, tokenText(total))
    }

    /// token 数值的短字符串：中文界面按「万 / 亿」，其余语言按 K / M（见 `UsageTokenFormat`）。
    private func tokenText(_ value: Int) -> String {
        UsageTokenFormat.short(
            value,
            languageCode: locale.language.languageCode?.identifier ?? "en",
            locale: l10n.locale
        )
    }
}
