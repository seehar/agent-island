//
//  UsageTrendChart.swift
//  AgentIsland
//
//  趋势曲线图：图例（可切换显示哪几路）+ 多路平滑曲线 + y / x 刻度 + 悬停十字线与读数卡。
//
//  y 轴按**可见路的窗内峰值**归一（单轴、五路共用），因此同一张图里各路的高低是可比的；
//  网格线、刻度与悬停读数都从同一份峰值推出，三处不会各算一套。
//

import SwiftUI

/// 多路趋势曲线图。
struct UsageTrendChart: View {
    /// 桶序列（升序、含空桶），由数据层给。
    let points: [TrendPoint]
    /// 桶的粒度：决定横轴刻度与悬停桶标签的写法。
    let granularity: TrendGranularity
    /// 当前显示哪几路（图例切换）。
    @Binding var visibleSeries: Set<StatsSeries>

    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale
    /// 悬停命中的桶序号（`nil` = 没有悬停）。
    @State private var hoveredIndex: Int?

    /// 面积填充的绘制顺序：先画最大的包络（总 ≥ 各路），较小的序列才不会被盖住。
    private let drawOrder: [StatsSeries] = [.total, .cacheRead, .cacheWrite, .input, .output]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            legend

            HStack(spacing: 0) {
                yAxisLabels
                chartArea
            }

            xAxis
        }
    }

    // MARK: - 推导

    /// 五路共用的峰值：只按可见路算——关掉某一路后，剩下的线会重新铺满高度。
    private var peak: Int {
        var peak = 0
        for point in points {
            for series in visibleSeries {
                peak = max(peak, point.value(for: series))
            }
        }
        return peak
    }

    /// 绘图区宽度：页内容宽 → 卡片内边距 → 左侧 y 轴刻度栏。
    private var plotWidth: CGFloat {
        max(
            0,
            UsageStatsMetrics.contentWidth
                - 2 * NotchMenuMetrics.rowHorizontalPadding
                - UsageStatsMetrics.chartYAxisWidth
        )
    }

    private var geometry: UsageChartGeometry {
        UsageChartGeometry(plotWidth: plotWidth, plotHeight: UsageStatsMetrics.chartPlotHeight)
    }

    /// 数字短格式的语言代码（中文按「万 / 亿」，其余按 K / M，见 `UsageTokenFormat`）。
    private var languageCode: String {
        locale.language.languageCode?.identifier ?? "en"
    }

    // MARK: - 图例

    /// 图例：五路各一格，点一下切换显示。关掉最后一路只剩空网格，因此由这里的
    /// 守卫忽略（`UsageStatsViewModel.toggleSeries` 同一判据）。
    private var legend: some View {
        HStack(spacing: UsageStatsMetrics.chartLegendGap) {
            ForEach(StatsSeries.allCases) { series in
                legendChip(series)
            }
        }
        .frame(height: UsageStatsMetrics.chartLegendHeight)
    }

    private func legendChip(_ series: StatsSeries) -> some View {
        let isVisible = visibleSeries.contains(series)

        return Button {
            withAnimation(SettingsMotion.segment) {
                toggle(series)
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isVisible ? series.chartColor : AppPalette.separator)
                    .frame(
                        width: UsageStatsMetrics.chartLegendDotSize,
                        height: UsageStatsMetrics.chartLegendDotSize
                    )

                Text(series.title(l10n))
                    .font(.system(size: 10))
                    .foregroundColor(isVisible ? AppPalette.secondaryText : AppPalette.subtleText)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .accessibilityLabel(Text(series.title(l10n)))
    }

    private func toggle(_ series: StatsSeries) {
        if visibleSeries.contains(series) {
            guard visibleSeries.count > 1 else { return }
            visibleSeries.remove(series)
        } else {
            visibleSeries.insert(series)
        }
    }

    // MARK: - y 轴刻度

    /// 左侧刻度：峰值、峰值一半、0 三条，与三条网格线一一对应。
    private var yAxisLabels: some View {
        ZStack(alignment: .top) {
            yAxisLabel(peak)
                .offset(y: -5)
            yAxisLabel(peak / 2)
                .offset(y: UsageStatsMetrics.chartPlotHeight / 2 - 5)
            yAxisLabel(0)
                .offset(y: UsageStatsMetrics.chartPlotHeight - 10)
        }
        .frame(
            width: UsageStatsMetrics.chartYAxisWidth,
            height: UsageStatsMetrics.chartPlotHeight,
            alignment: .top
        )
    }

    private func yAxisLabel(_ value: Int) -> some View {
        Text(UsageTokenFormat.short(value, languageCode: languageCode, locale: l10n.locale))
            .font(.system(size: 9))
            .foregroundColor(AppPalette.tertiaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 4)
    }

    // MARK: - 绘图区

    /// 绘图区：网格线 + 面积填充 + 曲线（一次 Canvas 画完），悬停时补十字线与圆点。
    private var chartArea: some View {
        Canvas { context, size in
            let geometry = UsageChartGeometry(plotWidth: size.width, plotHeight: size.height)
            drawGrid(context: &context, geometry: geometry)

            for series in drawOrder where visibleSeries.contains(series) {
                let projected = geometry.points(
                    values: points.map { $0.value(for: series) }, peak: peak)

                // 只有一个桶时画不出线，画一个点代替。
                if projected.count == 1, let only = projected.first {
                    context.fill(
                        dotPath(center: only), with: .color(series.chartColor))
                    continue
                }
                guard projected.count >= 2 else { continue }

                context.fill(
                    areaPath(projected: projected, geometry: geometry),
                    with: .color(series.chartColor.opacity(UsageStatsMetrics.chartAreaOpacity)))
                context.stroke(
                    curvePath(projected: projected), with: .color(series.chartColor),
                    lineWidth: UsageStatsMetrics.chartLineWidth)
            }

            if let hoveredIndex, points.indices.contains(hoveredIndex) {
                drawHover(context: &context, geometry: geometry, index: hoveredIndex)
            }
        }
        .frame(width: plotWidth, height: UsageStatsMetrics.chartPlotHeight)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoveredIndex = geometry.nearestIndex(x: location.x, count: points.count)
            case .ended:
                hoveredIndex = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoveredIndex, points.indices.contains(hoveredIndex) {
                tooltip(for: hoveredIndex)
                    .offset(
                        x: tooltipOffset(index: hoveredIndex),
                        y: UsageStatsMetrics.chartTooltipTopInset)
            }
        }
    }

    /// 三条水平网格线：顶（峰值）、中（峰值一半）、底（0）。
    private func drawGrid(context: inout GraphicsContext, geometry: UsageChartGeometry) {
        let lineCount = UsageStatsMetrics.chartGridLineCount
        for line in 0..<lineCount {
            let ratio = CGFloat(line) / CGFloat(lineCount - 1)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: geometry.plotHeight * ratio))
            path.addLine(to: CGPoint(x: geometry.plotWidth, y: geometry.plotHeight * ratio))
            context.stroke(path, with: .color(AppPalette.separator), lineWidth: 1)
        }
    }

    /// 悬停：竖十字线 + 每一路在桶上的圆点。
    private func drawHover(context: inout GraphicsContext, geometry: UsageChartGeometry, index: Int) {
        let x = geometry.x(index: index, count: points.count)

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: x, y: 0))
        crosshair.addLine(to: CGPoint(x: x, y: geometry.plotHeight))
        context.stroke(crosshair, with: .color(AppPalette.separator), lineWidth: 1)

        let point = points[index]
        for series in StatsSeries.allCases where visibleSeries.contains(series) {
            let center = CGPoint(
                x: x, y: geometry.y(value: point.value(for: series), peak: peak))
            context.fill(dotPath(center: center), with: .color(series.chartColor))
        }
    }

    /// 一路值的平滑曲线：单调三次插值（不过冲，见 `UsageChartCurve`）。
    private func curvePath(projected: [CGPoint]) -> Path {
        var path = Path()
        guard let first = projected.first else { return path }
        path.move(to: first)

        for (index, control) in UsageChartCurve.controlPoints(projected).enumerated() {
            path.addCurve(to: projected[index + 1], control1: control.0, control2: control.1)
        }
        return path
    }

    /// 面积填充：曲线 + 右下 + 左下闭合（点是按 x 升序的，因此闭合路径就是这块面积）。
    private func areaPath(projected: [CGPoint], geometry: UsageChartGeometry) -> Path {
        var path = curvePath(projected: projected)
        guard let first = projected.first, let last = projected.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: geometry.plotHeight))
        path.addLine(to: CGPoint(x: first.x, y: geometry.plotHeight))
        path.closeSubpath()
        return path
    }

    private func dotPath(center: CGPoint) -> Path {
        let radius = UsageStatsMetrics.chartDotRadius
        return Path(
            ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    // MARK: - 悬停读数卡

    /// 读数卡：桶标签 + 每个可见路的数值。
    private func tooltip(for index: Int) -> some View {
        let point = points[index]

        return VStack(alignment: .leading, spacing: 2) {
            Text(UsageStatsFormat.bucketLabel(point.start, granularity: granularity, locale: locale))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppPalette.primaryText)
                .lineLimit(1)

            ForEach(StatsSeries.allCases.filter { visibleSeries.contains($0) }) { series in
                HStack(spacing: 4) {
                    Circle()
                        .fill(series.chartColor)
                        .frame(width: 6, height: 6)

                    Text(series.title(l10n))
                        .font(.system(size: 10))
                        .foregroundColor(AppPalette.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(
                        UsageTokenFormat.short(
                            point.value(for: series), languageCode: languageCode, locale: l10n.locale)
                    )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(AppPalette.primaryText)
                    .lineLimit(1)
                }
                .frame(height: UsageStatsMetrics.chartTooltipRowHeight)
            }
        }
        .padding(UsageStatsMetrics.chartTooltipPadding)
        .frame(width: UsageStatsMetrics.chartTooltipWidth, alignment: .leading)
        .background(
            AppPalette.cardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .strokeBorder(AppPalette.cardStroke, lineWidth: 0.5)
        )
    }

    /// 读数卡的 x：以悬停桶为中心，再夹进绘图区（否则边缘的桶会把卡片切掉一半）。
    private func tooltipOffset(index: Int) -> CGFloat {
        let centered =
            geometry.x(index: index, count: points.count) - UsageStatsMetrics.chartTooltipWidth / 2
        let maximum = max(0, plotWidth - UsageStatsMetrics.chartTooltipWidth)
        return min(max(centered, 0), maximum)
    }

    // MARK: - x 轴

    /// 横轴刻度：首尾 + 中间等分（最多 `chartXTickCount` 个），与绘图区同宽。
    private var xAxis: some View {
        HStack(spacing: 0) {
            ForEach(Array(tickIndices.enumerated()), id: \.offset) { position, index in
                Text(
                    UsageStatsFormat.axisLabel(
                        points[index].start, granularity: granularity, locale: locale)
                )
                .font(.system(size: 10))
                .foregroundColor(AppPalette.tertiaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: alignment(forTickAt: position))
            }
        }
        .padding(.leading, UsageStatsMetrics.chartYAxisWidth)
        .frame(height: UsageStatsMetrics.chartXAxisHeight)
    }

    /// 刻度序号：首尾各一，中间等分（去重升序；桶少时自然少几个刻度）。
    private var tickIndices: [Int] {
        guard !points.isEmpty else { return [] }
        let last = points.count - 1
        guard last >= UsageStatsMetrics.chartXTickCount - 1 else { return Array(0...last) }

        let step = Double(last) / Double(UsageStatsMetrics.chartXTickCount - 1)
        var indices = (0..<UsageStatsMetrics.chartXTickCount).map {
            Int((Double($0) * step).rounded())
        }
        indices.append(last)
        return Array(Set(indices)).sorted()
    }

    /// 首尾刻度贴向两端，中间的居中（刻度与绘图区的左右边缘对齐）。
    private func alignment(forTickAt position: Int) -> Alignment {
        if position == 0 { return .leading }
        if position == tickIndices.count - 1 { return .trailing }
        return .center
    }
}

// MARK: - 序列的表现

extension StatsSeries {
    /// 曲线色。见 `ChartPalette`：不是状态色，也不参与选中态。
    var chartColor: Color {
        switch self {
        case .total: return ChartPalette.total
        case .input: return ChartPalette.input
        case .output: return ChartPalette.output
        case .cacheRead: return ChartPalette.cacheRead
        case .cacheWrite: return ChartPalette.cacheWrite
        }
    }

    /// 图例与读数里的名字。键保持字面量，本地化守卫据此审计。
    func title(_ l10n: LocalizationManager) -> String {
        switch self {
        case .total: return l10n.t("Total tokens")
        case .input: return l10n.t("Input")
        case .output: return l10n.t("Output")
        case .cacheRead: return l10n.t("Cache read")
        case .cacheWrite: return l10n.t("Cache write")
        }
    }
}
