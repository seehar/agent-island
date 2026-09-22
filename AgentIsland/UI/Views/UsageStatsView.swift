//
//  UsageStatsView.swift
//  AgentIsland
//
//  统计页：总览 + 各 Agent 拆分 + 各模型拆分 + 多路趋势曲线图 + 工具榜 + 口径脚注。
//  视图只消费 `UsageStatsSnapshot`——总量、缓存命中率、排序都由数据层给出，
//  这里不重算口径（口径写在 Models/UsageStats.swift 的注释里）。
//
//  它是设置面板的一个分组（`NotchMenuSection.statistics`），因此**不套自己的滚动**：
//  滚动由设置页的 `ScrollView` 接管，否则会出现嵌套滚动（内层吃走滚轮）。面板高度由
//  `NotchMenuMetrics` 按本分组的固定高算出，不随数据多少变化；页面顶部也不再加内边距
//  ——那一份间距由设置页给（`NotchMenuMetrics.contentTopGap`，解析式里只算一次）。
//  时间范围控件在设置页的页眉行里，见 `StatsRangePicker`。
//

import SwiftUI

struct UsageStatsView: View {
    @ObservedObject var viewModel: UsageStatsViewModel
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 数字与日期的格式化跟随界面语言（由根视图的 LocalizedRoot 注入环境 locale）。
    @Environment(\.locale) private var locale

    /// 数值缺失时的占位符（命中率的分母为 0 就没法算）。破折号是排版符号、不随语言
    /// 变化，因此不占一个本地化键。
    private static let unavailableValue = "—"

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.snapshot.totals.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: UsageStatsMetrics.groupSpacing) {
                overviewCard

                if hasAgents { agentGroup }
                if hasModels { modelGroup }
                if hasTrend { trendGroup }
                if hasTools { toolGroup }

                footnote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var totals: UsageTotals { viewModel.snapshot.totals }
    private var hasAgents: Bool { !viewModel.snapshot.agents.isEmpty }
    private var hasModels: Bool { !viewModel.snapshot.models.isEmpty }
    private var hasTrend: Bool { !viewModel.snapshot.trend.isEmpty }
    private var hasTools: Bool { !viewModel.snapshot.tools.isEmpty }

    // MARK: - 总览卡

    private var overviewCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: UsageStatsMetrics.summaryLineSpacing) {
                Text(l10n.t("Total tokens"))
                    .appFont(11, weight: .semibold)
                    .foregroundColor(AppPalette.tertiaryText)

                HStack(alignment: .firstTextBaseline, spacing: UsageStatsMetrics.summaryStatSpacing) {
                    Text(tokenText(totals.total))
                        .appFont(
                            UsageStatsMetrics.summaryNumberSize,
                            weight: .semibold,
                            design: .monospaced
                        )
                        .foregroundColor(AppPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer(minLength: 8)

                    statBlock(totals.sessions, label: l10n.t("Sessions"))
                    statBlock(totals.calls, label: l10n.t("Tool calls"))
                }

                separator

                VStack(spacing: UsageStatsMetrics.detailRowSpacing) {
                    detailRow(l10n.t("Input"), value: tokenText(totals.input))
                    detailRow(l10n.t("Output"), value: tokenText(totals.output))
                    detailRow(l10n.t("Cache read"), value: tokenText(totals.cacheRead))
                    detailRow(l10n.t("Cache write"), value: tokenText(totals.cacheWrite))
                    detailRow(l10n.t("Cache hit rate"), value: cacheHitRateText)
                }
            }
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
            .padding(.vertical, UsageStatsMetrics.summaryVerticalPadding)
        }
    }

    /// 卡片内的发丝分隔线：把「总量 + 小计」与下面的明细行分开。
    private var separator: some View {
        Rectangle()
            .fill(AppPalette.separator)
            .frame(height: 1)
    }

    /// 一个小计：数值在上、名称在下，右对齐后两块的数字列能对上。
    private func statBlock(_ value: Int, label: String) -> some View {
        VStack(alignment: .trailing, spacing: NotchMenuMetrics.titleSpacing) {
            Text(value, format: .number)
                .appFont(UsageStatsMetrics.summaryStatSize, weight: .semibold, design: .monospaced)
                .foregroundColor(AppPalette.primaryText)
                .lineLimit(1)

            Text(label)
                .appFont(10)
                .foregroundColor(AppPalette.tertiaryText)
                .lineLimit(1)
        }
    }

    /// 明细行：左侧名称、右侧数值（等宽，多行之间数字对齐）。
    private func detailRow(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .appFont(11)
                .foregroundColor(AppPalette.secondaryText)

            Spacer(minLength: 8)

            Text(value)
                .appFont(11, weight: .medium, design: .monospaced)
                .foregroundColor(AppPalette.primaryText)
        }
        .frame(height: UsageStatsMetrics.detailRowHeight)
    }

    // MARK: - 各 Agent 拆分

    private var agentGroup: some View {
        cardGroup(l10n.t("Agents")) {
            VStack(spacing: 0) {
                ForEach(viewModel.snapshot.agents) { usage in
                    agentRow(usage)
                }
            }
        }
    }

    /// 占比条的分母取窗口内最大的那个 Agent：相对占比比「占全局的比例」更能看出谁在用。
    private var maxAgentTotal: Int {
        viewModel.snapshot.agents.map(\.totals.total).max() ?? 0
    }

    private func agentRow(_ usage: AgentUsage) -> some View {
        HStack(spacing: NotchMenuMetrics.badgeGap) {
            SettingsBadge(source: .agent(usage.agent))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(usage.agent.shortName)
                        .appFont(12, weight: .medium)
                        .foregroundColor(AppPalette.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(tokenText(usage.totals.total))
                        .appFont(11, weight: .medium, design: .monospaced)
                        .foregroundColor(AppPalette.secondaryText)

                    Text(l10n.t("%lld sessions", usage.totals.sessions))
                        .appFont(10)
                        .foregroundColor(AppPalette.tertiaryText)
                }

                shareBar(
                    ratio: share(usage.totals.total, of: maxAgentTotal),
                    tint: usage.agent.brandColor
                )
            }
        }
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
        .frame(height: UsageStatsMetrics.agentRowHeight)
    }

    // MARK: - 各模型拆分

    private var modelGroup: some View {
        cardGroup(l10n.t("Models")) {
            VStack(spacing: 0) {
                ForEach(topModels) { model in
                    modelRow(model)
                }
            }
        }
    }

    /// 数据层给的是全量降序表，这里按版面截断（与工具榜同一策略）。
    private var topModels: [ModelUsage] {
        Array(viewModel.snapshot.models.prefix(UsageStatsMetrics.modelListMax))
    }

    /// 占比条的分母取窗口内最大的那个模型。
    private var maxModelTotal: Int {
        viewModel.snapshot.models.map(\.totals.total).max() ?? 0
    }

    private func modelRow(_ usage: ModelUsage) -> some View {
        HStack(spacing: 10) {
            // 模型名长短不一（`claude-sonnet-4-5-20250929`）：固定列宽 + 中间截断，
            // 保留首尾（提供方与版本号都在两端），各行占比条因此对齐。
            Text(usage.name)
                .appFont(11, design: .monospaced)
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: UsageStatsMetrics.modelNameWidth, alignment: .leading)

            // 与工具榜同一理由：模型榜不与任何身份绑定，占比条用中性文字色。
            shareBar(ratio: share(usage.totals.total, of: maxModelTotal), tint: AppPalette.secondaryText)

            Text(tokenText(usage.totals.total))
                .appFont(11, weight: .medium, design: .monospaced)
                .foregroundColor(AppPalette.primaryText)
                .lineLimit(1)
                .frame(width: UsageStatsMetrics.modelTokenWidth, alignment: .trailing)
        }
        .frame(height: UsageStatsMetrics.modelRowHeight)
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
    }

    // MARK: - 趋势

    private var trendGroup: some View {
        cardGroup(l10n.t("Trend")) {
            UsageTrendChart(
                points: viewModel.snapshot.trend,
                // 粒度取**快照自己记的窗口**：横轴刻度与桶必须来自同一次查询，
                // 否则换窗口的过渡帧里会出现「天粒度的桶配小时刻度」这类错配。
                granularity: viewModel.snapshot.window.granularity(),
                visibleSeries: $viewModel.visibleSeries
            )
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 工具榜

    private var toolGroup: some View {
        cardGroup(l10n.t("Tools")) {
            VStack(spacing: 0) {
                ForEach(topTools) { tool in
                    toolRow(tool)
                }
            }
        }
    }

    /// 数据层给的是全量降序表，这里按版面截断：再往下列已经没有信息量。
    private var topTools: [ToolUsage] {
        Array(viewModel.snapshot.tools.prefix(UsageStatsMetrics.toolListMax))
    }

    private var maxToolCalls: Int {
        viewModel.snapshot.tools.map(\.calls).max() ?? 0
    }

    private func toolRow(_ tool: ToolUsage) -> some View {
        HStack(spacing: 10) {
            Text(MCPToolFormatter.formatToolName(tool.name))
                .appFont(11, design: .monospaced)
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: UsageStatsMetrics.toolNameWidth, alignment: .leading)

            // 工具榜不与任何身份绑定，占比条用中性文字色：强调色在本仓库是「选中态」专用。
            shareBar(ratio: share(tool.calls, of: maxToolCalls), tint: AppPalette.secondaryText)

            Text(tool.calls, format: .number)
                .appFont(11, weight: .medium, design: .monospaced)
                .foregroundColor(AppPalette.primaryText)
                .frame(width: UsageStatsMetrics.toolCountWidth, alignment: .trailing)
        }
        .frame(height: UsageStatsMetrics.toolRowHeight)
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
    }

    // MARK: - 脚注与空态

    /// 口径脚注：交代页面上的数字怎么来的，以及数据的新鲜度。口径与
    /// `Models/UsageStats.swift` 的注释一一对应，改口径时两处一起改。
    private var footnote: some View {
        VStack(alignment: .leading, spacing: UsageStatsMetrics.footnoteLineSpacing) {
            Text(
                l10n.t(
                    "Totals include cached tokens; hit rate = cache read / (input + cache read + cache write)."
                ))
            Text(
                l10n.t(
                    "Session counts exclude subagents; usage from deleted session records is still counted."
                ))
            indexStatus
        }
        .appFont(10)
        .foregroundColor(AppPalette.subtleText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
    }

    /// 索引状态：正在回填就明说（此时数字还会继续长），否则给出最近一次索引完成时间。
    @ViewBuilder
    private var indexStatus: some View {
        HStack(spacing: 6) {
            if viewModel.snapshot.isIndexing {
                Text(l10n.t("Indexing…"))
            }

            if let indexedAt = viewModel.snapshot.indexedAt {
                Text(
                    l10n.t(
                        "Last indexed %@",
                        indexedAt.formatted(
                            .dateTime.month(.abbreviated).day().hour().minute().locale(locale))
                    ))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(l10n.t("No data yet"))
                .appFont(13, weight: .medium)
                .foregroundColor(AppPalette.tertiaryText)

            Text(
                l10n.t(
                    "Run an agent to collect usage. If nothing appears, check that its integration is installed."
                )
            )
            .appFont(11)
            .foregroundColor(AppPalette.subtleText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            indexStatus
                .appFont(10)
                .foregroundColor(AppPalette.subtleText)
        }
        .frame(maxWidth: .infinity, minHeight: UsageStatsMetrics.emptyStateMinHeight)
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
    }

    // MARK: - 小组件

    /// 分组：标题 + 一张卡片。卡片的底色、描边与圆角复用 `SettingsCard`（与设置面板
    /// 是同一套 chrome）；标题走 `appFont`，因此统计页的字号档位对它同样生效。
    private func cardGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.sectionHeaderGap) {
            Text(title)
                .appFont(11, weight: .semibold)
                .foregroundColor(AppPalette.tertiaryText)
                .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)

            SettingsCard {
                content()
            }
        }
    }

    /// 占比条：轨道用分段控件的弱底色，填充色由调用方给（Agent 行用它自己的品牌色）。
    private func shareBar(ratio: Double, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: UsageStatsMetrics.shareBarRadius, style: .continuous)
            .fill(AppPalette.segmentedTrack)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: UsageStatsMetrics.shareBarRadius, style: .continuous)
                    .fill(tint)
                    .scaleEffect(x: clampedRatio(ratio), anchor: .leading)
            }
            .frame(height: UsageStatsMetrics.shareBarHeight)
    }

    private func clampedRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0), 1)
    }

    /// 占比：分母为 0（窗口内没有任何用量）时按 0 画。
    private func share(_ value: Int, of maximum: Int) -> Double {
        guard maximum > 0 else { return 0 }
        return Double(value) / Double(maximum)
    }

    /// token 数值的短字符串：中文界面按「万 / 亿」，其余语言按 K / M（见 UsageTokenFormat）。
    private func tokenText(_ value: Int) -> String {
        UsageTokenFormat.short(
            value,
            languageCode: locale.language.languageCode?.identifier ?? "en",
            locale: l10n.locale
        )
    }

    /// 缓存命中率：分母为 0 时数据层给 nil（没走过缓存就谈不上命中率），这里显示占位符。
    /// 小数位与 token 的短格式一致（2 位），整页数字的位数因此统一。
    private var cacheHitRateText: String {
        guard let rate = totals.cacheHitRate else { return Self.unavailableValue }
        return rate.formatted(.percent.precision(.fractionLength(2)).locale(locale))
    }
}

// MARK: - 设置面板里的统计分组

/// 统计页作为设置面板一个分组时的外壳：只负责进/离页的生命周期钩子。
///
/// 高度与滚动都由设置面板负责（分组内容高见 `NotchMenuMetrics.blocks(for:)`），
/// 视图模型由内容根持有（`NotchView`），因此切走再切回来不会重置时间窗口、也不会
/// 重新取一次快照——两个入口（头部图标 / 设置面板）看到的是同一份状态。
struct UsageStatisticsSettingsPage: View {
    @ObservedObject var viewModel: UsageStatsViewModel

    var body: some View {
        UsageStatsView(viewModel: viewModel)
            // 进页即让索引器做一次增量扫描（内部有节流）；新数据到达后视图模型会重取快照。
            .onAppear {
                viewModel.onAppear()
            }
            .onDisappear {
                viewModel.onDisappear()
            }
    }
}
