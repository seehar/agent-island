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
//  设置页的滚动接管（页面自己不再套一层 ScrollView）。
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
    /// `NotchMenuMetrics.maxPanelHeight` 之内（有实测：见 UsageStatsLayoutTests）。
    static let sectionHeight: CGFloat = 560
    /// 页面内容宽度：面板宽上限减去设置页的左右内边距（统计页与设置行左右对齐，
    /// 自己不再加内边距）。工具榜两列与柱图都要在这个宽度内排下。
    static var contentWidth: CGFloat {
        NotchMenuMetrics.panelWidthMax - NotchMenuMetrics.listPaddingHeight
    }

    // MARK: - 页面容器

    /// 各分组之间的间距。
    static let groupSpacing: CGFloat = NotchMenuMetrics.groupSpacing
    /// 范围分段控件与内容之间的间距。
    static let contentTopGap: CGFloat = NotchMenuMetrics.contentTopGap
    /// 范围分段控件的高度：与设置面板的分组切换同规格。
    static let tabBarHeight: CGFloat = NotchMenuMetrics.tabBarHeight
    /// 范围滑块的圆角，与设置页分组切换的滑块一致（轨道已不再画：两条相邻的
    /// 分段控件共用同一形状会被读成同层导航）。
    static let segmentedThumbRadius: CGFloat = 7
    /// 「重新统计」按钮的宽度：取固定值，两种文案（重新统计 / 正在索引…）切换时
    /// 左边的分段控件不该跟着抖；`minimumScaleFactor` 兜住更长的那一档。
    static let rangeActionWidth: CGFloat = 64
    /// 按钮内图标与文字的间距。
    static let rangeActionIconGap: CGFloat = 4
    /// 范围分段控件与按钮之间的间距。
    static let rangeActionGap: CGFloat = 8
    /// 范围段之间的间距（七档范围的宽度预算按它算，见 `UsageStatsLayoutTests`）。
    static let segmentSpacing: CGFloat = 2
    /// 范围段文字的缩字下限：七档时每段约 54pt（面板 480），最长的标签是英文
    /// This Month（11 号 medium 约 60pt），缩到这个比例仍排得下——到不了就截断。
    /// `UsageStatsLayoutTests` 用真实字体度量钉住这条预算。
    static let segmentMinimumScale: CGFloat = 0.7

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

    // MARK: - 趋势柱图

    /// 柱图高度：柱高按窗内峰值归一到这个高度。
    static let chartHeight: CGFloat = 52
    /// 值为 0 的桶画一条细底线：占位，但不参与高度归一。
    static let chartBaselineHeight: CGFloat = 1.5
    /// 柱子圆角（柱很窄时会被柱宽吃掉）。
    static let chartBarRadius: CGFloat = 1.5
    /// 柱子间距：桶越密间距越小（「全部」可能有几百个桶）。
    static let chartBarSpacingWide: CGFloat = 6
    static let chartBarSpacingMiddle: CGFloat = 4
    static let chartBarSpacingTight: CGFloat = 2
    /// 桶数超过这个值改用最紧的间距。
    static let chartTightBarCount = 30
    /// 柱图下方首尾时间标签的行高。
    static let chartAxisHeight: CGFloat = 14

    // MARK: - 工具榜

    /// 工具榜最多显示的行数（数据层给全量降序表，截断在视图里）。
    static let toolListMax = 12
    /// 工具名与调用次数两列的宽度：固定后各行的占比条才会对齐。
    static let toolNameWidth: CGFloat = 108
    static let toolCountWidth: CGFloat = 56
    /// 工具行的行高。
    static let toolRowHeight: CGFloat = 26

    // MARK: - 脚注与空态

    /// 脚注（口径说明与索引时间）的行距。
    static let footnoteLineSpacing: CGFloat = 5
    /// 空态的最小高度：设置面板给本分组的可视内容区约 516（分组内容高减去范围控件
    /// 与间距），留出这个高度后提示块落在视觉居中处，而不是贴着范围控件。
    /// 有数据时统计页内容通常高于可视区（由设置页的滚动接管），空态则刚好贴近一屏。
    static let emptyStateMinHeight: CGFloat = 460

    // MARK: - 推导

    /// 柱子的间距：按桶数分档，避免「全部」这种几百个桶的窗口把柱子挤成一片。
    static func chartBarSpacing(barCount: Int) -> CGFloat {
        if barCount <= 7 { return chartBarSpacingWide }
        if barCount <= chartTightBarCount { return chartBarSpacingMiddle }
        return chartBarSpacingTight
    }
}
