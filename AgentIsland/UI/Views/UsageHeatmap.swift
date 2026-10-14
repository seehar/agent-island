//
//  UsageHeatmap.swift
//  AgentIsland
//
//  每日用量热力图（GitHub 贡献图那种）：53 列 ≈ 近一年、一格一个自然日，
//  深浅按当前选中的量分五档（口径在 `UsageHeatmapScale`）。卡片里从上到下是：
//  一行说明（窗口与读法）→ 日期范围与合计 → 月份标签 → 左侧星期标签 + 格网 →
//  右下角色阶图例；悬停任一格弹一张浮卡（日期 + 两个读数，跟随光标、被夹在卡片内）。
//
//  它是**固定窗口**：不跟随统计页的范围选择器。一次查询里两种窗口并存是有意的
//  （见 `UsageStatsSnapshot.daily`）——折线看「选定范围的走势」，这里看「近一年的节律」。
//  格子与日期由 `UsageStatsCalendar.heatmapWeeks` 给出（行序按 `calendar.firstWeekday`，
//  与月历同一个约定），视图只做「日期 → 颜色 / 读数」的映射。
//
//  格网宽度吃满可用宽度（53 列等分，与曲线图的绘图区同一条原则）：面板在紧凑档或
//  窄屏上会比上限窄，写死格宽会把整页撑破、落进面板后被裁掉两侧。格宽同时决定格高
//  （正方形），因此**整块高度随宽度变**——面板高度的解析式取标准档的那一份（见
//  `UsageStatsMetrics.heatmapGridHeight`）。
//

import SwiftUI

/// 每日用量热力图。
struct UsageHeatmap: View {
    /// 每日读数（稀疏、升序）。来自 `UsageStatsSnapshot.daily`。
    let days: [DayUsage]
    /// 上色按哪个量（右上角分档控件；选择由页面持有，切页回来保持）。
    @Binding var metric: StatsHeatmapMetric
    /// 页面内容宽（卡片左右内边距由这里扣）。
    ///
    /// 格边长**必须**由它算出来（`heatmapCellSide(forGridWidth:)`），不能靠 `aspectRatio`
    /// 或实测：形状的理想尺寸是 10×10，弹性列拿到实宽后 `aspectRatio` 仍会拿理想值定高，
    /// 格子就不再是「按列宽算的方块」（实测 53 列会摊成 660pt 宽、被卡片裁掉）。
    /// 面板宽与 `NotchMenuMetrics.contentAreaWidth(inPanelWidth:)` 同源，因此这里传下来的
    /// 值与真实排版一致，也不需要「先量一次再改」的两帧。
    let contentWidth: CGFloat
    /// 「今天」：末列是包含它的那一周，它之后的格子不画。默认取当前时刻；用例传定值。
    var now: Date = Date()
    /// 分桶与排格用的日历（与数据层查询用的是同一份）。
    var calendar: Calendar = .current

    @ObservedObject private var l10n = LocalizationManager.shared
    /// 日期与数字的格式化跟随界面语言（由根视图的 LocalizedRoot 注入环境 locale）。
    @Environment(\.locale) private var locale

    /// 悬停命中的格子（列 / 行）与光标位置（格网坐标系）；离开格网时清空。
    @State private var hover: Hover?
    /// 卡片的内部宽度（页面内容宽扣掉卡片自己的左右内边距）。
    private var cardWidth: CGFloat {
        contentWidth - 2 * NotchMenuMetrics.rowHorizontalPadding
    }

    /// 格网的宽度（卡片内宽扣掉星期标签栏）与一格的边长：绘制、悬停反查、浮卡定位共用。
    private var gridWidth: CGFloat {
        UsageStatsMetrics.heatmapGridWidth(forCardWidth: cardWidth)
    }

    private var cellSide: CGFloat {
        UsageStatsMetrics.heatmapCellSide(forGridWidth: gridWidth)
    }

    /// 悬停状态。`location` 是格网坐标系里的光标位置（浮卡定位用）。
    private struct Hover: Equatable {
        let column: Int
        let row: Int
        let location: CGPoint
    }

    var body: some View {
        // 一次算好格子、分档阈值与合计：逐格去查字典会让 371 个格子各查一次。
        let grid = Self.makeGrid(
            days: days, metric: metric, now: now, calendar: calendar, locale: l10n.locale)

        VStack(alignment: .leading, spacing: 0) {
            summary(grid)
                .frame(height: UsageStatsMetrics.heatmapSummaryHeight, alignment: .leading)
                .padding(.bottom, UsageStatsMetrics.heatmapSummaryGap)

            monthLabels(grid)
                .frame(height: UsageStatsMetrics.heatmapMonthLabelHeight, alignment: .leading)
                .padding(
                    .leading,
                    UsageStatsMetrics.heatmapWeekdayGutterWidth
                        + UsageStatsMetrics.heatmapWeekdayLabelGap)
                .padding(.bottom, UsageStatsMetrics.heatmapMonthLabelGap)

            HStack(alignment: .top, spacing: UsageStatsMetrics.heatmapWeekdayLabelGap) {
                weekdayLabels()
                gridBody(grid)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 8)
                legend
            }
            .frame(height: UsageStatsMetrics.heatmapLegendHeight, alignment: .trailing)
            .padding(.top, UsageStatsMetrics.heatmapLegendGap)
        }
        .padding(.vertical, UsageStatsMetrics.heatmapCardVerticalPadding)
    }

    // MARK: - 卡片里的文字行

    /// 汇总行：左边是这一窗的起止日期，右边是这一窗的合计（两个读数都给，不跟选中档变）。
    private func summary(_ grid: Grid) -> some View {
        HStack(spacing: 8) {
            Text(grid.rangeText(locale: locale))
                .appFont(10)
                .foregroundColor(AppPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(UsageStatsMetrics.heatmapSummaryMinimumScale)

            Text(
                l10n.t(
                    "%@ tokens · %@ tool calls", tokenText(grid.totalTokens),
                    tokenText(grid.totalCalls))
            )
            .appFont(11, weight: .medium)
            .foregroundColor(AppPalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(UsageStatsMetrics.heatmapSummaryMinimumScale)

            Spacer(minLength: 0)
        }
    }

    /// 月份标签行：与格网同一列节拍（左边空出星期标签栏），标签从该月第一列的左边缘起排
    /// （宽出去的部分自然压在后几列上——一列只有几个点宽，写不下两个字）。
    private func monthLabels(_ grid: Grid) -> some View {
        let starts = UsageStatsCalendar.heatmapMonthStarts(weeks: grid.weeks, calendar: calendar)
        let byColumn = Dictionary(
            starts.map { ($0.column, $0.date) }, uniquingKeysWith: { first, _ in first })

        return HStack(spacing: UsageStatsMetrics.heatmapCellSpacing) {
            ForEach(grid.weeks.indices, id: \.self) { column in
                ZStack(alignment: .leading) {
                    Color.clear
                    if let date = byColumn[column] {
                        Text(monthText(date))
                            .appFont(9)
                            .foregroundColor(AppPalette.subtleText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 左侧星期标签：只画隔行的四档（行 0 / 2 / 4 / 6）。行高是**弹性**的——整栏被
    /// HStack 拉到与格网等高，7 份等分 + 同一个行间距，行中心因此与格子的中心重合
    /// （不需要把格边长从格网那边传过来）。
    private func weekdayLabels() -> some View {
        let symbols = weekdaySymbols()

        return VStack(spacing: UsageStatsMetrics.heatmapCellSpacing) {
            ForEach(0..<UsageStatsCalendar.daysPerWeek, id: \.self) { row in
                Group {
                    if row.isMultiple(of: 2), symbols.indices.contains(weekdayIndex(forRow: row)) {
                        Text(symbols[weekdayIndex(forRow: row)])
                            .appFont(9)
                            .foregroundColor(AppPalette.subtleText)
                            .lineLimit(1)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: cellSide)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(
            width: UsageStatsMetrics.heatmapWeekdayGutterWidth
                - UsageStatsMetrics.heatmapWeekdayLabelGap
        )
    }

    /// 色阶图例（右下角）：浅 → 深五格 + 两端的「少 / 多」。
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

    // MARK: - 格网

    /// 53 列（每列一周）× 7 行：格子是**边长由格网宽算出来的正方形**（见 `cellSide`），
    /// 因此整块高度 = 7 格 + 6 个间距；绘制、悬停反查与浮卡定位共用同一份几何。
    private func gridBody(_ grid: Grid) -> some View {
        HStack(spacing: UsageStatsMetrics.heatmapCellSpacing) {
            ForEach(grid.cells.indices, id: \.self) { column in
                VStack(spacing: UsageStatsMetrics.heatmapCellSpacing) {
                    ForEach(grid.cells[column].indices, id: \.self) { row in
                        cell(grid.cells[column][row], grid: grid, column: column, row: row)
                    }
                }
            }
        }
        // 悬停：整块格网是一个命中面（格子只有几个点宽，逐个格子做命中面会点不着），
        // 位置反查落在哪一格。
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hover = UsageStatsMetrics.heatmapCell(at: point, gridWidth: gridWidth)
                    .map { Hover(column: $0.column, row: $0.row, location: point) }
            case .ended:
                hover = nil
            }
        }
        .overlay(alignment: .topLeading) { hoverCard(grid) }
    }

    /// 一格：未来（今天之后）的格子不画；其余按档位填色，悬停时加一圈描边。
    @ViewBuilder
    private func cell(_ cell: Grid.Cell, grid: Grid, column: Int, row: Int) -> some View {
        if let value = cell.value(for: metric) {
            let isHovered = hover?.column == column && hover?.row == row
            RoundedRectangle(cornerRadius: UsageStatsMetrics.heatmapCellRadius, style: .continuous)
                .fill(
                    ChartPalette.heatmapLevels[
                        UsageHeatmapScale.level(total: value, thresholds: grid.thresholds)]
                )
                .frame(width: cellSide, height: cellSide)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: UsageStatsMetrics.heatmapCellRadius, style: .continuous
                    )
                    .strokeBorder(AppPalette.hoverForeground, lineWidth: isHovered ? 1 : 0)
                }
                .accessibilityLabel(Text(cell.readout(locale: locale, l10n: l10n)))
        } else {
            // 未来：占位但不画（同一列的各行仍然对齐），也没有悬停读数。
            Color.clear
                .frame(width: cellSide, height: cellSide)
        }
    }

    // MARK: - 悬停浮卡

    /// 浮卡：日期（含星期）+ 两个读数。跟随光标、不参与命中（`allowsHitTesting(false)`，
    /// 否则它会挡住格网的悬停），位置由 `UsageStatsMetrics.heatmapHoverCardPosition` 给出。
    @ViewBuilder
    private func hoverCard(_ grid: Grid) -> some View {
        if let hover, let cell = grid.cell(column: hover.column, row: hover.row) {
            UsageHeatmapHoverCard(date: cell.date, usage: cell.usage)
                .offset(
                    UsageStatsMetrics.heatmapHoverCardPosition(
                        column: hover.column, row: hover.row, gridWidth: gridWidth)
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - 格式化

    /// 月份标签：跟界面语言（`3月` / `Mar`）。
    private func monthText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).locale(locale))
    }

    /// 一周里第 `row` 行是星期几（0 = 周起始日那一行）。
    private func weekdayIndex(forRow row: Int) -> Int {
        (calendar.firstWeekday - 1 + row) % 7
    }

    /// 界面语言下的星期缩写（下标 0 = 周日，与 `Calendar.firstWeekday` 同一套编号）。
    private func weekdaySymbols() -> [String] {
        var calendar = calendar
        calendar.locale = l10n.locale
        return calendar.shortWeekdaySymbols
    }

    /// token 数值的短字符串：中文界面按「万 / 亿」，其余语言按 K / M（见 `UsageTokenFormat`）。
    private func tokenText(_ value: Int) -> String {
        UsageTokenFormat.short(
            value,
            languageCode: locale.language.languageCode?.identifier ?? "en",
            locale: l10n.locale
        )
    }

    // MARK: - 绘制输入

    /// 一次查询的绘制输入：格子（日期 + 读数）、分档阈值、汇总数字。全部一次算好，
    /// 逐格去查库 / 建字典会让 371 个格子各算一遍。
    private struct Grid {
        /// 一格：日期 + 当日读数（未来格 `usage == nil`；没有记录的日子是 0 读数）。
        struct Cell {
            let date: Date
            let usage: DayUsage?

            /// 按当前指标取值；未来格给 `nil`。
            func value(for metric: StatsHeatmapMetric) -> Int? {
                usage?.value(for: metric)
            }

            /// 悬停 / 无障碍读数：日期 + 两个量。
            func readout(locale: Locale, l10n: LocalizationManager) -> String {
                guard let usage else { return "" }
                func short(_ value: Int) -> String {
                    UsageTokenFormat.short(
                        value,
                        languageCode: locale.language.languageCode?.identifier ?? "en",
                        locale: l10n.locale)
                }
                return l10n.t(
                    "%@ · %@ tokens · %@ tool calls",
                    date.formatted(.dateTime.year().month().day().locale(locale)),
                    short(usage.total), short(usage.calls))
            }
        }

        /// 列升序（最早的一周 → 含今天的那一周），每列 7 天（行序按 `calendar.firstWeekday`）。
        let cells: [[Cell]]
        /// 分档阈值（按当前指标现算）。
        let thresholds: [Int]
        let totalTokens: Int
        let totalCalls: Int
        let todayStart: Date

        /// 月份标签要的纯日期网格。
        var weeks: [[Date]] {
            cells.map { $0.map(\.date) }
        }

        var firstDay: Date {
            cells.first?.first?.date ?? todayStart
        }

        /// 某一格的完整读数（未来格给 `nil`）。
        func cell(column: Int, row: Int) -> (date: Date, usage: DayUsage)? {
            guard cells.indices.contains(column), cells[column].indices.contains(row) else {
                return nil
            }
            let cell = cells[column][row]
            guard let usage = cell.usage else { return nil }
            return (cell.date, usage)
        }

        /// 汇总行的日期范围：`2025年10月13日 – 2026年10月14日`（右端是今天，不是本周末尾）。
        func rangeText(locale: Locale) -> String {
            let style = Date.FormatStyle.dateTime.year().month().day().locale(locale)
            return "\(firstDay.formatted(style)) – \(todayStart.formatted(style))"
        }
    }

    private static func makeGrid(
        days: [DayUsage], metric: StatsHeatmapMetric, now: Date, calendar: Calendar, locale: Locale
    ) -> Grid {
        let weeks = UsageStatsCalendar.heatmapWeeks(containing: now, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)
        let byKey = Dictionary(
            days.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })

        let cells: [[Grid.Cell]] = weeks.map { column in
            column.map { date in
                guard date <= todayStart else { return Grid.Cell(date: date, usage: nil) }
                let key = UsageStatsKey.bucket(for: date, granularity: .day, calendar: calendar)
                return Grid.Cell(
                    date: date, usage: byKey[key] ?? DayUsage(dayKey: key, total: 0, calls: 0))
            }
        }

        return Grid(
            cells: cells,
            thresholds: UsageHeatmapScale.thresholds(of: days.map { $0.value(for: metric) }),
            totalTokens: days.reduce(0) { $0 + $1.total },
            totalCalls: days.reduce(0) { $0 + $1.calls },
            todayStart: todayStart)
    }
}

/// 悬停浮卡：日期（含星期）+ 两个读数。单独成一个类型——它不依赖格网几何，
/// 用例与渲染探针可以直接给它一个日期 + 读数看排版。
struct UsageHeatmapHoverCard: View {
    let date: Date
    let usage: DayUsage

    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: UsageStatsMetrics.heatmapHoverCardGap) {
            Text(title)
                .appFont(10, weight: .semibold)
                .foregroundColor(AppPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: UsageStatsMetrics.heatmapHoverTitleHeight, alignment: .leading)

            hoverRow(l10n.t("Tokens"), value: tokens(usage.total))
            hoverRow(l10n.t("Tool calls"), value: tokens(usage.calls))
        }
        .padding(UsageStatsMetrics.heatmapHoverCardPadding)
        .frame(width: UsageStatsMetrics.heatmapHoverCardWidth, alignment: .leading)
        // 玻璃质感抄面板自己的那一份实现（`NotchPanelSurface`：macOS 26+ 走 Liquid Glass、
        // 更早走 `Material`，上面再叠压暗罩）——浮卡要压得住底下的格网、两行读数要看得清。
        .notchPanelSurface(
            shape: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous),
            scrim: NotchSurfaceScrim.floating,
            tint: NotchSurfaceScrim.floatingTint
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .strokeBorder(AppPalette.cardStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    /// 标题：日期 + 星期（顺序与写法由语言的日期格式决定）。
    private var title: String {
        date.formatted(
            .dateTime.weekday(.abbreviated).year().month(.wide).day().locale(locale))
    }

    /// 一行读数：左边名目、右边数值（等宽，两行数字对齐）。
    private func hoverRow(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .appFont(10)
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(value)
                .appFont(10, weight: .medium, design: .monospaced)
                .foregroundColor(AppPalette.primaryText)
                .lineLimit(1)
        }
        .frame(height: UsageStatsMetrics.heatmapHoverRowHeight)
    }

    /// token 数值的短字符串：中文界面按「万 / 亿」，其余语言按 K / M（见 `UsageTokenFormat`）。
    private func tokens(_ value: Int) -> String {
        UsageTokenFormat.short(
            value,
            languageCode: locale.language.languageCode?.identifier ?? "en",
            locale: l10n.locale
        )
    }
}
