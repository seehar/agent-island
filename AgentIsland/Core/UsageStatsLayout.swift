//
//  UsageStatsLayout.swift
//  AgentIsland
//
//  统计页的版面常量。统计页独有的数值集中在这里，行几何、圆角与配色一律复用既有
//  token（`NotchMenuMetrics` 的行几何、`AppPalette`、`AppRadius`），视图里不散落
//  魔法数。
//
//  统计页是**读数面**（`NotchMenuSection.statistics`）：不占侧栏位、不显示侧栏，
//  整块内容占满面板宽度。这里给的是「内容高」而不是「面板高」：面板高由
//  `NotchMenuMetrics` 按分组算出来（读数面不套设置面的 640 上限，见 `maxDashboardHeight`），
//  滚动由内容面的 ScrollView 接管（页面自己不再套一层）。时间范围控件在**页眉行**里
//  （见 `StatsRangePicker`），它的展开块挤占页内滚动视口而不是撑高面板。
//

import CoreGraphics

/// 统计页的版面常量与推导。
///
/// 高度是**固定值**而不是由内容撑出来的：面板高由 `NotchMenuMetrics` 的解析式给出
/// （`chromeHeight + contentHeight(for: .statistics)`，含这里的 `sectionHeight`），
/// 数据多少不改变面板高度；上限是读数面的 `maxDashboardHeight`（730）而不是设置面的
/// 640，因此在任何可达的固定开销下整页都看得全（实测见 `UsageStatsLayoutTests`）。
nonisolated enum UsageStatsMetrics {
    // MARK: - 版面

    /// 统计页的内容高度（含脚注），由四个数推出来——**不是**随手取的整数：
    ///
    ///   · `sectionHeightBeforeHeatmap`（577）= 热力图之前那一版的实测内容高；
    ///   · + `heatmapSectionHeight`：热力图是后加的一个分组（组间距 + 标题行 + 卡片）；
    ///   · − 两处榜单让出的长尾：工具榜 12 → 8（−104）、模型榜 8 → 6（−52）。
    ///
    /// 与面板的固定开销（36…76）相加后仍在读数面上限 `NotchMenuMetrics.maxDashboardHeight`
    /// （730）之内：76 +（58 + ~586）= ~720，余 ~10pt。余量由
    /// `UsageStatsLayoutTests.heatmapSectionFeedsTheHeightBudget` 钉住（改任一项都要重算）。
    static var sectionHeight: CGFloat {
        sectionHeightBeforeHeatmap + heatmapSectionHeight
            - CGFloat(12 - toolListMax) * toolRowHeight
            - CGFloat(8 - modelListMax) * modelRowHeight
    }

    /// 热力图分组加入之前那一版的内容高（含脚注）。560 → 577 是因为脚注新增了
    /// 「不计入的 Agent」那一行（`UsageStatsView.excludedAgentsNote`，文案压成一行、
    /// 最窄档也排得下）：一行 = 10pt 字体 + `footnoteLineSpacing`(5) + 行高余量（实测 17）。
    private static let sectionHeightBeforeHeatmap: CGFloat = 577
    /// 页面内容宽度（标准档）：面板宽预算减去卡片侧内边距与容器内边距
    /// （`NotchMenuMetrics.contentAreaWidth` = 448）。统计页是读数面、不显示侧栏，
    /// 拿到的就是这一份整宽；工具榜两列、芯片网格、月历与图例行都要在这个宽度内排下。
    ///
    /// 它是**标准档**的判据，**不能当固定宽度用**：实际面板宽是
    /// `min(screenRect.width * 0.4, panelWidthMax) × 面板尺寸档`（见 `NotchViewModel.openedSize`），
    /// 紧凑档（390.4）与窄屏都会比它窄。按这个宽度写死尺寸会把整页撑破面板、再被左右裁掉
    /// ——曾经就是曲线图的绘图区宽度（实测紧凑档左右各裁 15.5pt，见 `UsageTrendChart`；
    /// 回归用例见 `UsageStatsLayoutTests` 的「统计页在紧凑档面板宽度内也排得下」）。
    static var contentWidth: CGFloat {
        NotchMenuMetrics.contentAreaWidth
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
    /// 它**不参与面板高度**（统计分组是固定 `sectionHeight` 的整块），
    /// 而是作为固定块插在页眉与滚动区之间挤占视口；`UsageStatsLayoutTests` 用它守住
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

    // MARK: - 热力图（近 53 周 · 每日用量）

    /// 格子间距（行、列同一个）与圆角。格子小（标准档约 6.5pt），圆角因此比
    /// `shareBarRadius` 还小一档。
    ///
    /// 间距取 1pt：53 列塞进几百点宽，2pt 的缝快赶上格子本身宽（约 36%，一眼是「点阵」
    /// 而不是「热力图」）；1pt 时格子更大（标准档 5.51 → 6.49pt）、整块更接近参考稿的密度。
    static let heatmapCellSpacing: CGFloat = 1
    static let heatmapCellRadius: CGFloat = 1.5
    /// 左侧星期标签栏的宽度：只画隔行的 周一 / 周三 / 周五 / 周日。取**固定值**而不是按
    /// 文案自适应——面板高度的解析式要跟语言无关；「两种语言的星期缩写都排得下」由
    /// `UsageStatsLayoutTests` 的宽度用例守住。
    static let heatmapWeekdayGutterWidth: CGFloat = 28
    /// 星期标签与格网之间的间距（算在栏宽内）。
    static let heatmapWeekdayLabelGap: CGFloat = 6

    /// 卡片内上下内边距。
    static let heatmapCardVerticalPadding: CGFloat = 10
    /// 汇总行（日期范围 + 两个读数）与它下面的间距。
    static let heatmapSummaryHeight: CGFloat = 13
    static let heatmapSummaryGap: CGFloat = 6
    /// 月份标签行与它下面的间距。
    static let heatmapMonthLabelHeight: CGFloat = 11
    static let heatmapMonthLabelGap: CGFloat = 2
    /// 图例行（色阶 + 少 / 多）与它上面的间距。
    static let heatmapLegendGap: CGFloat = 4
    static let heatmapLegendHeight: CGFloat = 11
    static let heatmapLegendSwatchSize: CGFloat = 8
    static let heatmapLegendSwatchRadius: CGFloat = 2
    /// 图例里色阶小方块之间的间距（比格网的间距宽一点：图例的方块大、挨太紧会糊成一条）。
    static let heatmapLegendSwatchSpacing: CGFloat = 3
    /// 右上角分档控件（Tokens / 工具调用）的高度与分段间距：与分组标题行同高（14），
    /// 标题、说明行与控件挤在同一行里（说明行不进卡片——那是整页只剩几个点余量时
    /// 最先该省的一行）。
    static let heatmapMetricSwitcherHeight: CGFloat = 14
    static let heatmapMetricSwitcherSpacing: CGFloat = 2
    static let heatmapMetricSwitcherPadding: CGFloat = 1
    static let heatmapMetricSwitcherRadius: CGFloat = 6
    /// 分组标题行里标题与说明行之间的间距。
    static let heatmapHeaderTextGap: CGFloat = 8
    /// 汇总行两段文字各自的缩字下限（最窄档 + 最长文案仍要一行放得下）。
    static let heatmapSummaryMinimumScale: CGFloat = 0.85

    /// 悬停浮卡：宽度、内边距、标题与两个读数行的高度。它浮在**卡片之内**（跟随光标、
    /// 被夹在卡片范围内），因此不占版面高度。
    static let heatmapHoverCardWidth: CGFloat = 152
    static let heatmapHoverCardPadding: CGFloat = 8
    static let heatmapHoverTitleHeight: CGFloat = 13
    static let heatmapHoverRowHeight: CGFloat = 14
    static let heatmapHoverCardGap: CGFloat = 3
    static var heatmapHoverCardHeight: CGFloat {
        2 * heatmapHoverCardPadding + heatmapHoverTitleHeight + 2 * heatmapHoverCardGap
            + 2 * heatmapHoverRowHeight
    }

    /// 分组标题行的高度：标题（`sectionHeaderHeight`）与右上角分档控件取高者。
    static var heatmapHeaderHeight: CGFloat {
        max(NotchMenuMetrics.sectionHeaderHeight, heatmapMetricSwitcherHeight)
    }

    /// 格网的可用宽度（给定卡片内宽）：卡片内宽 − 星期标签栏。
    static func heatmapGridWidth(forCardWidth cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - heatmapWeekdayGutterWidth)
    }

    /// 格网的可用宽度（给定面板宽）：页面内容宽 − 卡片左右内边距 − 星期标签栏。
    /// 标准档的那一份进面板高度的解析式（见 `heatmapGridHeight`）。
    static func heatmapGridWidth(inPanelWidth panelWidth: CGFloat) -> CGFloat {
        heatmapGridWidth(
            forCardWidth: NotchMenuMetrics.contentAreaWidth(inPanelWidth: panelWidth)
                - 2 * NotchMenuMetrics.rowHorizontalPadding)
    }

    /// 一格的边长（正方形）：53 列等分格网宽——格宽吃满可用宽，格高跟着它走。
    static func heatmapCellSide(forGridWidth gridWidth: CGFloat) -> CGFloat {
        let columns = CGFloat(UsageStatsCalendar.heatmapWeekCount)
        return max(0, (gridWidth - (columns - 1) * heatmapCellSpacing) / columns)
    }

    /// 格网高度 = 7 行格子 + 6 个行间距（格高 = 格宽，见 `heatmapCellSide(forGridWidth:)`）。
    static func heatmapGridHeight(forGridWidth gridWidth: CGFloat) -> CGFloat {
        let rows = CGFloat(UsageStatsCalendar.daysPerWeek)
        return rows * heatmapCellSide(forGridWidth: gridWidth)
            + (rows - 1) * heatmapCellSpacing
    }

    /// 标准档下的格网高度：进面板高度解析式的那一份（窄面板下格网更矮，页面整体只会更短）。
    static var heatmapGridHeight: CGFloat {
        heatmapGridHeight(forGridWidth: heatmapGridWidth(inPanelWidth: NotchMenuMetrics.panelWidthMax))
    }

    /// 悬停命中：把一个点（格网坐标系）换成「第几列第几行」，落在格网外给 `nil`。
    /// 与 `heatmapCellSide(forGridWidth:)` 同一套几何——反查与绘制不能各算一套。
    static func heatmapCell(at point: CGPoint, gridWidth: CGFloat) -> (column: Int, row: Int)? {
        let pitch = heatmapCellSide(forGridWidth: gridWidth) + heatmapCellSpacing
        guard pitch > 0, point.x >= 0, point.y >= 0 else { return nil }
        // 先卡「点在格网矩形里」：53 列正好铺满格网宽，右边多出来的一条就是卡片内边距，
        // 落在那里不该算成最后一列。
        guard
          point.x < gridWidth, point.y < heatmapGridHeight(forGridWidth: gridWidth)
        else { return nil }
        let column = Int(point.x / pitch)
        let row = Int(point.y / pitch)
        guard
          column >= 0, column < UsageStatsCalendar.heatmapWeekCount,
          row >= 0, row < UsageStatsCalendar.daysPerWeek
        else { return nil }
        return (column, row)
    }

    /// 悬停浮卡的落点（相对格网左上角）：优先放在格子的右侧，右边放不下翻到左侧；
    /// 纵向跟着格子、再夹进**卡片内容**范围（浮卡比格网高，光夹格网会顶出卡片）。
    /// 与 `heatmapCell(at:gridWidth:)` 同一套几何——反查、绘制与浮卡定位不能各算一套。
    static func heatmapHoverCardPosition(column: Int, row: Int, gridWidth: CGFloat) -> CGSize {
        let side = heatmapCellSide(forGridWidth: gridWidth)
        let pitch = side + heatmapCellSpacing
        let cellX = CGFloat(column) * pitch
        let cellY = CGFloat(row) * pitch

        var x = cellX + side + 6
        if x + heatmapHoverCardWidth > gridWidth { x = cellX - heatmapHoverCardWidth - 6 }
        x = min(max(x, 0), max(0, gridWidth - heatmapHoverCardWidth))

        let gridHeight = heatmapGridHeight(forGridWidth: gridWidth)
        let lowest = gridHeight + heatmapSpaceBelowGrid - heatmapHoverCardHeight
        let ceiling = -heatmapSpaceAboveGrid
        var y = cellY - (heatmapHoverCardHeight - side) / 2
        y = min(max(y, ceiling), max(lowest, ceiling))
        return CGSize(width: x, height: y)
    }

    /// 热力图卡片的内容高：上下内边距 + 汇总行 + 月份标签 + 格网 + 图例。
    /// （说明行在**分组标题行**里，不占卡片的高度。）
    static var heatmapCardHeight: CGFloat {
        2 * heatmapCardVerticalPadding + heatmapSummaryHeight + heatmapSummaryGap
            + heatmapMonthLabelHeight + heatmapMonthLabelGap + heatmapGridHeight
            + heatmapLegendGap + heatmapLegendHeight
    }

    /// 格网之上 / 之下在卡片内容里各有多少空间（悬停浮卡纵向夹取用：浮卡比格网高，
    /// 光夹格网会顶出卡片）。
    static var heatmapSpaceAboveGrid: CGFloat {
        heatmapCardVerticalPadding + heatmapSummaryHeight + heatmapSummaryGap
            + heatmapMonthLabelHeight + heatmapMonthLabelGap
    }
    static var heatmapSpaceBelowGrid: CGFloat {
        heatmapCardVerticalPadding + heatmapLegendGap + heatmapLegendHeight
    }

    /// 热力图分组的净高：组间距 + 标题行（含分档控件）+ 卡片。
    static var heatmapSectionHeight: CGFloat {
        groupSpacing + heatmapHeaderHeight + NotchMenuMetrics.sectionHeaderGap + heatmapCardHeight
    }

    // MARK: - 工具榜

    /// 工具榜最多显示的行数（数据层给全量降序表，截断在视图里）。
    /// 12 → 8：热力图占的高度从长尾让——第 9–12 行合计只占全部调用的 5.6%
    /// （本机实测：223 个工具名、77 万次调用）。
    static let toolListMax = 8
    /// 工具名与调用次数两列的宽度：固定后各行的占比条才会对齐。
    static let toolNameWidth: CGFloat = 108
    static let toolCountWidth: CGFloat = 56
    /// 工具行的行高。
    static let toolRowHeight: CGFloat = 26

    // MARK: - 模型榜

    /// 模型榜最多显示的行数（数据层给全量降序表，截断在视图里）。
    /// 8 → 6：与工具榜一起给热力图腾 `sectionHeight` 的预算；前 6 个模型占全部用量的
    /// 92%（本机实测：102 个模型名），再往下列都是零头。
    static let modelListMax = 6
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
    /// 空态的最小高度：跟着 `sectionHeight` 走——空态是同一页的「没有数据」面，留出这个
    /// 高度后提示块落在视觉居中处，而不是贴着页眉；两者的差额保持在既有区间内
    /// （见 `UsageStatsLayoutTests.emptyStateFitsPanel`）。
    static let emptyStateMinHeight: CGFloat = 537
}
