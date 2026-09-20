//
//  UsageStatsLayout.swift
//  AgentIsland
//
//  统计页的版面常量。统计页独有的数值集中在这里，行几何、圆角与配色一律复用既有
//  token（`NotchMenuMetrics` 的行几何、`AppPalette`、`AppRadius`），视图里不散落
//  魔法数。
//

import CoreGraphics

/// 统计页的版面常量与推导。
///
/// 面板高度是硬约束：宿主窗口高固定 **750**（`UI/Window/NotchWindowController.swift`），
/// 而设置面板那条 `NotchMenuMetrics.maxPanelHeight` 夹取只作用于 `.menu`，统计页不继承，
/// 因此这里的高度自己守住余量；内容放不下由页内滚动接管（见 `UsageStatsView`）。
nonisolated enum UsageStatsMetrics {
    // MARK: - 面板

    /// 统计页的面板高度。窗口 750 − 头部行与面板内边距 − 展开动画余量。
    static let panelHeight: CGFloat = 560
    /// 面板宽度上限：与实例列表、设置面板同宽。
    static let panelWidthMax: CGFloat = 480

    // MARK: - 页面容器

    /// 页面四周内边距，与设置面板容器一致。
    static let pagePadding: CGFloat = 8
    /// 各分组之间的间距。
    static let groupSpacing: CGFloat = NotchMenuMetrics.groupSpacing
    /// 范围分段控件与内容之间的间距。
    static let contentTopGap: CGFloat = NotchMenuMetrics.contentTopGap
    /// 范围分段控件的高度：与设置面板的分组切换同规格。
    static let tabBarHeight: CGFloat = NotchMenuMetrics.tabBarHeight
    /// 分段控件的轨道与滑块圆角，与 `NotchMenuTabBar` 保持一致。
    static let segmentedTrackRadius: CGFloat = 9
    static let segmentedThumbRadius: CGFloat = 7

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
    /// 空态的最小高度：面板内容区约 450，留出这个高度后提示块落在视觉居中处，
    /// 而不是贴着分段控件。
    static let emptyStateMinHeight: CGFloat = 380

    // MARK: - 推导

    /// 柱子的间距：按桶数分档，避免「全部」这种几百个桶的窗口把柱子挤成一片。
    static func chartBarSpacing(barCount: Int) -> CGFloat {
        if barCount <= 7 { return chartBarSpacingWide }
        if barCount <= chartTightBarCount { return chartBarSpacingMiddle }
        return chartBarSpacingTight
    }
}
