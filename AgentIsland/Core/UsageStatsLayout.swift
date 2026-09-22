//
//  UsageStatsLayout.swift
//  AgentIsland
//
//  统计页的版面常量。统计页独有的数值集中在这里，行几何、圆角与配色一律复用既有
//  token（`NotchMenuMetrics` 的行几何、`AppPalette`、`AppRadius`），视图里不散落
//  魔法数。
//
//  统计页是设置面板的一个分组（`NotchMenuSection.statistics`），因此这里给的是
//  「内容高」而不是「面板高」：面板高由 `NotchMenuMetrics` 按分组算出来，滚动由
//  设置页的滚动接管（页面自己不再套一层 ScrollView）。时间范围控件在设置页的**页眉
//  行**里（见 `StatsRangePicker`），它的展开块挤占页内滚动视口而不是撑高面板。
//

import CoreGraphics

/// 统计页的版面常量与推导。
///
/// 高度是**固定值**而不是由内容撑出来的：面板高由 `NotchMenuMetrics` 的解析式给出
/// （`chromeHeight + contentHeight(for: .statistics)`，含这里的 `sectionHeight`），
/// 数据多少不改变面板高度；放不下的部分由设置页的滚动接管（见 `UsageStatsView`）。
nonisolated enum UsageStatsMetrics {
    // MARK: - 版面

    /// 统计页的内容高度。取 560 与「面板 + 分组页眉 + 分段控件」的固定开销相加后仍在
    /// `NotchMenuMetrics.maxPanelHeight` 之内（有实测：见 `UsageStatsLayoutTests`）。
    static let sectionHeight: CGFloat = 560
    /// 页面内容宽度：面板宽上限减去设置页的左右内边距（统计页与设置行左右对齐，
    /// 自己不再加内边距）。工具榜两列、芯片网格、月历与曲线图都要在这个宽度内排下。
    static var contentWidth: CGFloat {
        NotchMenuMetrics.panelWidthMax - NotchMenuMetrics.listPaddingHeight
    }

    // MARK: - 页面容器

    /// 各分组之间的间距。
    static let groupSpacing: CGFloat = NotchMenuMetrics.groupSpacing
    /// 页眉行与内容之间的间距（统计页只做参照：实际间距由设置页给）。
    static let contentTopGap: CGFloat = NotchMenuMetrics.contentTopGap

    // MARK: - 页眉行里的范围控件

    /// 范围控件宽度：预设档名短，自选范围是「9月1日 – 9月20日」这类读数；宽度固定，
    /// 切换档位时左边的标题不会跟着抖。
    static let headerRangeWidth: CGFloat = 150
    /// 页眉行里图标按钮（重新统计）的边长：与设置页眉的返回按钮同一档。
    static let headerActionSize: CGFloat = 22
    /// 范围控件里文字与箭头的间距。
    static let headerRangeGap: CGFloat = 4
    /// 窗口标题的缩字下限：窗口标题过长时缩字而不截断。
    static let headerRangeMinimumScale: CGFloat = 0.8

    // MARK: - 范围选择器（页眉控件的展开块）

    /// 芯片网格的列数：7 个预设 + 「自定义…」= 8 格，正好两行。
    static let rangeChipColumns = 4
    static let rangeChipHeight: CGFloat = 30
    static let rangeChipSpacing: CGFloat = 4
    static let rangeChipRowSpacing: CGFloat = 4
    /// 芯片文字的缩字下限（各语言里最长的那档仍排得下，见 `UsageStatsLayoutTests`）。
    static let rangeChipMinimumScale: CGFloat = 0.8
    /// 选择器块的上下内边距。
    static let rangePickerVerticalPadding: CGFloat = 10
    /// 芯片网格与月历之间的间距（分隔线两侧各一个）。
    static let rangePickerGap: CGFloat = 10
    /// 选择器块的总高：卡片内边距 + 两行芯片 + 间距 + 分隔线 + 间距 + 月历 + 读数行。
    ///
    /// 它**不参与面板高度**（统计分组是固定 560 的整块，且这种组合下已顶到 728 上限），
    /// 而是作为固定块插在分段条与滚动区之间挤占视口；`UsageStatsLayoutTests` 用它守住
    /// 「展开后滚动视口仍不小于 200pt」。
    static var rangePickerHeight: CGFloat {
        2 * rangePickerVerticalPadding
            + 2 * rangeChipHeight + rangeChipRowSpacing
            + rangePickerGap + 1 + rangePickerGap
            + calendarMonthHeaderHeight + calendarWeekdayHeight
            + CGFloat(UsageStatsCalendar.rowCount) * calendarCellHeight
            + CGFloat(UsageStatsCalendar.rowCount - 1) * calendarCellSpacing
            + calendarReadoutHeight
    }

    // MARK: - 月历

    static let calendarCellWidth: CGFloat = 30
    static let calendarCellHeight: CGFloat = 26
    static let calendarCellSpacing: CGFloat = 2
    static let calendarCellRadius: CGFloat = 5
    /// 月头行（◀ 2026年9月 ▶）与周标题行的高度。
    static let calendarMonthHeaderHeight: CGFloat = 24
    static let calendarWeekdayHeight: CGFloat = 16
    /// 月历的固定行数：与 `UsageStatsCalendar.monthGrid` 的格子数同源。
    static let calendarMaxRowCount = UsageStatsCalendar.rowCount
    /// 读数行（「9月1日 – 9月20日」或「先选起始日，再选结束日。」）。
    static let calendarReadoutHeight: CGFloat = 18
    /// 月历块宽度 = 7 列 + 6 个列间距。
    static var calendarWidth: CGFloat {
        CGFloat(7) * calendarCellWidth + 6 * calendarCellSpacing
    }

    // MARK: - 总览卡

    /// 总览卡的上下内边距。
    static let summaryVerticalPadding: CGFloat = 12
    /// 总 token 数字的字号（等宽，数值刷新时宽度不抖）。
    static let summaryNumberSize: CGFloat = 26
    /// 会话数 / 工具调用数这类小计的字号。
    static let summaryStatSize: CGFloat = 15
    /// 总览卡内部的行距。
    static let summaryLineSpacing: CGFloat = 8
    /// 两个小计之间的间距。
    static let summaryStatSpacing: CGFloat = 18
    /// 明细行（输入 / 输出 / 缓存读 / 缓存写 / 命中率）的行高与行距。
    static let detailRowHeight: CGFloat = 16
    static let detailRowSpacing: CGFloat = 4

    // MARK: - 分组行

    /// Agent 行的行高（名称一行 + 占比条一行）。
    static let agentRowHeight: CGFloat = 44
    /// 占比条的粗细与圆角。
    static let shareBarHeight: CGFloat = 4
    static let shareBarRadius: CGFloat = 2

    // MARK: - 曲线图

    /// 绘图区高度（不含图例、读数行、横轴行与左侧刻度栏）。
    static let chartPlotHeight: CGFloat = 120
    /// y 轴刻度文案的字号（`UsageTrendChart` 渲染刻度与量宽都用它，两处必须是同一个值）。
    static let chartYAxisLabelSize: CGFloat = 9
    /// 左侧 y 轴刻度栏的最小 / 最大宽度，以及文案与绘图区之间的留白。
    /// 刻度文案会随量级变长（`1235万` / `695亿`），固定宽度会把它截断，因此宽度是按
    /// 真实文案量出来再夹在这两个界限之间（见 `chartYAxisWidth(forLabelWidths:)`）。
    static let chartYAxisMinimumWidth: CGFloat = 34
    /// 上限取 60：缩写值一律 2 位小数后，最长的刻度文案（`10000.00亿` / `1000.00B`）
    /// 实测要 57.6pt（含留白），56 会把它截断（`UsageStatsLayoutTests` 实测数据）。
    static let chartYAxisMaximumWidth: CGFloat = 60
    static let chartYAxisLabelPadding: CGFloat = 6
    /// y 轴网格线条数（0 / 峰值一半 / 峰值）与横轴刻度个数。
    static let chartGridLineCount = 3
    static let chartXTickCount = 4
    /// 悬停读数行的高度：它**始终存在**（未悬停时给提示），悬停时只有文字变化——
    /// 若改成「悬停时才出现在光标下面的浮层」，hover 会反复进入/离开，看起来在闪。
    static let chartReadoutHeight: CGFloat = 16
    /// 横轴刻度行的行高。
    static let chartXAxisHeight: CGFloat = 14
    /// 曲线粗细、悬停圆点半径、面积填充的不透明度。
    static let chartLineWidth: CGFloat = 1.5
    static let chartDotRadius: CGFloat = 2.5
    static let chartAreaOpacity: CGFloat = 0.10
    /// 图例行：整行高、圆点直径与两项之间的间距。
    static let chartLegendHeight: CGFloat = 20
    static let chartLegendDotSize: CGFloat = 7
    static let chartLegendGap: CGFloat = 8
    /// 趋势卡的总高（卡片内边距 + 图例 + 读数行 + 图 + 横轴行）：首屏要能整块看到，
    /// 不需要滚动就能读出形状（`UsageStatsLayoutTests` 钉住这条）。
    static var trendCardHeight: CGFloat {
        2 * 10 + chartLegendHeight + 6 + chartReadoutHeight + 6 + chartPlotHeight + 4
            + chartXAxisHeight
    }

    /// y 轴刻度栏宽度：按最长的那条刻度文案量出来的宽度加上留白，夹在上下限之间。
    /// 传入的是**已按当前语言格式化好的**刻度文案宽度（与渲染同一把尺子量）。
    static func chartYAxisWidth(forLabelWidths widths: [CGFloat]) -> CGFloat {
        let widest = widths.max() ?? 0
        return min(
            max(chartYAxisMinimumWidth, widest + chartYAxisLabelPadding),
            chartYAxisMaximumWidth)
    }

    // MARK: - 工具榜

    /// 工具榜最多显示的行数（数据层给全量降序表，截断在视图里）。
    static let toolListMax = 12
    /// 工具名与调用次数两列的宽度：固定后各行的占比条才会对齐。
    static let toolNameWidth: CGFloat = 108
    static let toolCountWidth: CGFloat = 56
    /// 工具行的行高。
    static let toolRowHeight: CGFloat = 26

    // MARK: - 模型榜

    /// 模型榜最多显示的行数（数据层给全量降序表，截断在视图里）。
    static let modelListMax = 8
    /// 模型名与 token 两列的宽度：固定后各行的占比条才会对齐。
    static let modelNameWidth: CGFloat = 176
    /// token 列宽：缩写值最长 9 字符（`10000.00亿` / `1000.00B`）在 11pt 等宽下实测
    /// 66.7pt（见 `UsageStatsLayoutTests`），取 72 留出余量。
    static let modelTokenWidth: CGFloat = 72
    /// 模型行的行高（与工具榜同一档）。
    static let modelRowHeight: CGFloat = 26

    // MARK: - 脚注与空态

    /// 脚注（口径说明与索引时间）的行距。
    static let footnoteLineSpacing: CGFloat = 5
    /// 空态的最小高度：设置面板给本分组的可视内容区是 560（页面顶部还有 10 的间距），
    /// 留出这个高度后提示块落在视觉居中处，而不是贴着页眉。有数据时内容通常高于可视区
    /// （由设置页的滚动接管）。
    static let emptyStateMinHeight: CGFloat = 520
}
