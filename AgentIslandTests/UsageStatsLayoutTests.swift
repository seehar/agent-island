//
//  UsageStatsLayoutTests.swift
//  AgentIslandTests
//
//  统计页的版面不变量。统计页现在是设置面板的一个分组：面板高度由
//  `NotchMenuMetrics` 的解析式给出（`sectionHeight` 是其中一项），宿主窗口高固定 750
//  （`NotchWindowController`）——两者都要装得下，且行内两列 + 柱图要排得开。
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

/// 串行：额度页的版面用例会改共享的 `NewAPIAccountPageState.shared`（面板高度按它算），
/// 并行跑会互相踩状态。
@Suite("统计页版面", .serialized)
struct UsageStatsLayoutTests {
  /// 宿主窗口高度（与 `NotchWindowController` 一致）。
  private let windowHeight: CGFloat = 750
  /// 有真实刘海的机型上头部行的高度（macOS 菜单栏区）。
  private let notchHeight: CGFloat = 38
  /// 面板底部内边距（与 `NotchView` 给面板留的间距一致）。
  private let bottomPadding: CGFloat = 12

  /// 统计页在默认固定开销下的面板高度（固定开销 = 头部行 + 面板底部内边距）。
  /// 它是**读数面**：上限是 `maxDashboardHeight`（不是设置面的 640），因此任何可达开销下
  /// 都是解析值、不会被夹取。
  private var statisticsPanelHeight: CGFloat {
    NotchMenuMetrics.panelHeight(
      for: .statistics, expandedPickerHeight: 0,
      chromeHeight: max(24, notchHeight) + bottomPadding)
  }

  @Test("统计页整页装得进窗口：解析高 == 内容 + 开销，且没被上限夹取")
  func panelFitsWindow() {
    #expect(
      statisticsPanelHeight
        == max(24, notchHeight) + bottomPadding + NotchMenuMetrics.contentHeight(for: .statistics),
      "读数面被夹取了：整页会有一部分掉到隐藏滚动条的视口外")
    #expect(statisticsPanelHeight <= NotchMenuMetrics.maxDashboardHeight)
    // 面板之下还要留出 `NotchView` 的底部内边距，整体仍要在宿主窗口里。
    #expect(statisticsPanelHeight + bottomPadding <= windowHeight)
  }

  @Test("统计分组的面板宽度与其他分组同宽（同一个常量）")
  func panelUsesSharedWidthCap() {
    #expect(NotchMenuMetrics.panelWidthMax == 480)
  }

  @Test("面板宽度不超过窗口内容宽度")
  func panelWidthFitsScreen() {
    // 内容宽度由面板宽上限与设置页的内边距推出来（统计页自己不再加内边距）。
    let contentWidth = UsageStatsMetrics.contentWidth
    #expect(contentWidth > 0)

    // 工具榜两列 + 占比条：占比条至少要有 40pt 才看得出差别。
    let toolRowWidth =
      UsageStatsMetrics.toolNameWidth + UsageStatsMetrics.toolCountWidth + 40
    #expect(toolRowWidth <= contentWidth)
  }

  @Test("八格范围芯片在两种面板宽度下都排得下（各语言都试）")
  func rangeChipLabelsFitTheirColumns() {
    // 标签 = 7 个预设档名 + 一格「自定义…」；文案从打包后的 .lproj 取，因此本地化改长
    // （或加一档范围）都会让这条用例失败——那时要重算格宽，而不是让它截断。
    let presetKeys = ["Today", "Last 24h", "This Week", "Last 7d", "This Month", "Last 30d", "All"]
    let chipKeys = presetKeys + ["Custom…"]
    #expect(presetKeys.count == StatsRange.chipOrder.count)
    // 8 格正好排满两行（4 列 × 2 行）。
    #expect(chipKeys.count == UsageStatsMetrics.rangeChipColumns * 2)

    let panels: [(name: String, width: CGFloat)] = [
      ("standard", NotchMenuMetrics.panelWidthMax),
      ("compact", NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale),
    ]
    for panel in panels {
      let chip = chipWidth(panelWidth: panel.width)
      for key in chipKeys {
        for code in ["en", "zh-Hans"] {
          let label = LocalizationManager.bundle(for: code)
            .localizedString(forKey: key, value: nil, table: nil)
          // 中文必须真的翻译过：解析不到时会静默回落到英语源文案。
          if code != "en" {
            #expect(label != key, "\(key) 没有 \(code) 文案")
          }
          let needed = labelWidth(label, size: 10) * UsageStatsMetrics.rangeChipMinimumScale
          #expect(
            needed <= chip,
            "\(panel.name) 档下 \(code) 的「\(label)」排不下：需要 \(needed)pt，格宽 \(chip)pt")
        }
      }
    }
  }

  @Test("统计页的页眉行在两种面板宽度下都排得下（标题 + 范围控件 + 重新统计）")
  func statisticsHeaderRowFitsPanel() {
    let panels: [(name: String, width: CGFloat)] = [
      ("standard", NotchMenuMetrics.panelWidthMax),
      ("compact", NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale),
    ]

    for panel in panels {
      for code in ["en", "zh-Hans"] {
        let title = LocalizationManager.bundle(for: code)
          .localizedString(forKey: "Statistics", value: nil, table: nil)
        // 行的左右内边距 8 + 返回按钮 + 标题 + 三段 6pt 间距 + 范围控件 + 重新统计。
        let minimum =
          2 * 8 + UsageStatsMetrics.headerActionSize
          + labelWidth(title, size: 13, weight: .semibold)
          + 3 * 6 + UsageStatsMetrics.headerRangeWidth + UsageStatsMetrics.headerActionSize
        #expect(minimum <= panel.width, "\(panel.name) 档下 \(code) 的页眉行需要 \(minimum)pt")
      }
    }
  }

  @Test("月历块在内容宽内排得下")
  func calendarFitsContentWidth() {
    #expect(UsageStatsMetrics.calendarWidth <= UsageStatsMetrics.contentWidth)
    // 7 列格子的几何自洽：格宽与间距之和就是月历块宽度。
    let derived =
      CGFloat(7) * UsageStatsMetrics.calendarCellWidth
      + CGFloat(6) * UsageStatsMetrics.calendarCellSpacing
    #expect(derived == UsageStatsMetrics.calendarWidth)
  }

  @Test("趋势卡首屏能整块看到（不用滚动就能读出形状）")
  func trendCardFitsViewportWithoutScrolling() {
    #expect(UsageStatsMetrics.trendCardHeight <= UsageStatsMetrics.sectionHeight)
    // 绘图区与横轴行都在卡片里，卡片高必须装得下它们。
    #expect(
      UsageStatsMetrics.trendCardHeight
        >= UsageStatsMetrics.chartPlotHeight + UsageStatsMetrics.chartXAxisHeight)
  }

  // MARK: - 热力图（近 53 周）

  @Test("热力图：真实排版高度 == 解析式；53 列等分格网宽、格是正方形")
  @MainActor
  func heatmapRendersAtItsAnalyticHeight() throws {
    // 面板高度的解析式用的是**标准档**那一份（`heatmapGridHeight`）。按标准档的卡片内宽
    // 渲染：真实排版必须与解析式逐值相符，否则面板高度与真实版面就开始漂移。
    // 用 ImageRenderer 而不是 `NSHostingView.fittingSize`：后者量的是**理想尺寸**，
    // 而这里要的是「在标准档宽度下真实排出来多高」——ImageRenderer 按给定 frame 出图。
    // 传的是**页面内容宽**（卡片自己再扣左右内边距），与页面里那一份同源。
    let width = UsageStatsMetrics.contentWidth
    let raster = try? renderedPixels(
      of: heatmapCard(days: [], metric: .tokens, now: Date(), calendar: .current, width: width))
    let measured = Double(raster?.height ?? 0) / 2
    #expect(
      abs(measured - Double(UsageStatsMetrics.heatmapCardHeight)) <= 1,
      "热力图实际排版 \(measured) ≠ 解析式 \(UsageStatsMetrics.heatmapCardHeight)")

    // 格网几何：一列 53 格（一年 52 周 + 1）、一行 7 格，正方形 + 统一间距。
    let columns = CGFloat(UsageStatsCalendar.heatmapWeekCount)
    let rows = CGFloat(UsageStatsCalendar.daysPerWeek)
    let gridWidth = UsageStatsMetrics.heatmapGridWidth(inPanelWidth: NotchMenuMetrics.panelWidthMax)
    let side = UsageStatsMetrics.heatmapCellSide(forGridWidth: gridWidth)
    #expect(side > 0)
    #expect(
      abs(columns * side + (columns - 1) * UsageStatsMetrics.heatmapCellSpacing - gridWidth) < 0.01,
      "53 列 + 间距没有正好铺满格网宽")
    #expect(
      abs(
        UsageStatsMetrics.heatmapGridHeight(forGridWidth: gridWidth)
          - (rows * side + (rows - 1) * UsageStatsMetrics.heatmapCellSpacing)) < 0.01,
      "格网高度 ≠ 7 行正方形 + 间距")
    // 标准档下格子是「几个点宽」的方块（448pt 的面板里塞一年就是这个量级），
    // 但也不能小到看不见：低于 4pt 就该重新考虑列数了。
    #expect(side >= 4, "标准档格子只剩 \(side)pt")

    // 悬停反查与绘制同一套几何：格网内的点能换成列 / 行，出界给 nil。
    let corner = UsageStatsMetrics.heatmapCell(at: .zero, gridWidth: gridWidth)
    #expect(corner?.column == 0 && corner?.row == 0)
    let last = UsageStatsMetrics.heatmapCell(
      at: CGPoint(x: gridWidth - 0.5, y: 0), gridWidth: gridWidth)
    #expect(last?.column == UsageStatsCalendar.heatmapWeekCount - 1)
    #expect(
      UsageStatsMetrics.heatmapCell(at: CGPoint(x: gridWidth + 1, y: 0), gridWidth: gridWidth)
        == nil)
    #expect(UsageStatsMetrics.heatmapCell(at: CGPoint(x: -1, y: 0), gridWidth: gridWidth) == nil)
    #expect(
      UsageStatsMetrics.heatmapCell(at: CGPoint(x: 0, y: gridWidth), gridWidth: gridWidth) == nil)
  }

  @Test("热力图的说明行 / 汇总行 / 图例 / 星期标签栏在两种面板宽度、两种语言下都排得下")
  func heatmapTextRowsFitWidths() {
    let panels: [(name: String, width: CGFloat)] = [
      ("standard", NotchMenuMetrics.panelWidthMax),
      ("compact", NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale),
    ]
    let scale = UsageStatsMetrics.heatmapSummaryMinimumScale
    for panel in panels {
      // 卡片内宽：说明行、汇总行与格网吃的都是这一份宽。
      let available =
        NotchMenuMetrics.contentAreaWidth(inPanelWidth: panel.width)
        - 2 * NotchMenuMetrics.rowHorizontalPadding
      for code in ["en", "zh-Hans"] {
        let bundle = LocalizationManager.bundle(for: code)
        func text(_ key: String) -> String {
          bundle.localizedString(forKey: key, value: nil, table: nil)
        }

        // 分组标题行 = 标题 + 8 + 说明行 + 8 + 分档控件（标题行吃的是页面内容宽，
        // 不是卡片内宽）。控件按「两格都跟最宽那档一样宽」conservative 估。
        let headerAvailable =
          NotchMenuMetrics.contentAreaWidth(inPanelWidth: panel.width)
          - 2 * NotchMenuMetrics.rowHorizontalPadding
        let subtitle = String(
          format: text("Last %lld weeks · one square per day"),
          UsageStatsCalendar.heatmapWeekCount)
        let switcher =
          labelWidth(text("Tokens"), size: 9) + labelWidth(text("Tool calls"), size: 9)
          + 4 * 7 + UsageStatsMetrics.heatmapMetricSwitcherSpacing
          + 2 * UsageStatsMetrics.heatmapMetricSwitcherPadding
        let headerNeeded =
          labelWidth(text("Usage heatmap"), size: 11)
          + 2 * UsageStatsMetrics.heatmapHeaderTextGap
          + labelWidth(subtitle, size: 10) * scale
          + switcher
        #expect(
          headerNeeded <= headerAvailable,
          "\(panel.name) 档下 \(code) 的标题行要 \(headerNeeded)pt，可用 \(headerAvailable)pt")

        // 汇总行 = 日期范围 + 8pt + 合计；日期按最长的形态量（跨年、两位月日）。
        let range = dateRangeLabel(code: code)
        let totals = String(
          format: text("%@ tokens · %@ tool calls"), "9999.99亿", "9999.99亿")
        let summaryNeeded = (labelWidth(range, size: 10) + 8 + labelWidth(totals, size: 11)) * scale
        #expect(
          summaryNeeded <= available,
          "\(panel.name) 档下 \(code) 的汇总行要 \(summaryNeeded)pt，可用 \(available)pt")

        // 图例（右下角）：少 + 5 格色阶 + 多。
        let legendNeeded =
          labelWidth(text("Less"), size: 9) + 5 * UsageStatsMetrics.heatmapLegendSwatchSize
          + 6 * UsageStatsMetrics.heatmapLegendSwatchSpacing
          + labelWidth(text("More"), size: 9)
        #expect(
          legendNeeded <= available,
          "\(panel.name) 档下 \(code) 的图例要 \(legendNeeded)pt，可用 \(available)pt")

        // 星期标签栏：最宽的那一档 + 与格网的间距 ≤ 栏宽——超了就会把格网挤窄、甚至顶出卡片。
        let widest = weekdaySymbols(code: code).map { labelWidth($0, size: 9) }.max() ?? 0
        #expect(
          widest + UsageStatsMetrics.heatmapWeekdayLabelGap
            <= UsageStatsMetrics.heatmapWeekdayGutterWidth,
          "\(code) 的星期标签最宽 \(widest)pt，栏宽只有 \(UsageStatsMetrics.heatmapWeekdayGutterWidth)pt")
      }
    }
  }

  @Test("悬停浮卡：排版 = 解析式；落点躲开右缘、并夹进卡片内容范围")
  @MainActor
  func heatmapHoverCardFitsAndAnchors() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    let date = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
    let raster = try #require(
      renderedPixels(
        of: UsageHeatmapHoverCard(
          date: date, usage: DayUsage(dayKey: "2026-07-05", total: 873_000_000, calls: 2398))))
    #expect(raster.width == Int(UsageStatsMetrics.heatmapHoverCardWidth * 2), "浮卡宽 \(raster.width)")
    #expect(
      abs(Double(raster.height) / 2 - Double(UsageStatsMetrics.heatmapHoverCardHeight)) <= 1,
      "浮卡高 \(Double(raster.height) / 2) ≠ 解析式 \(UsageStatsMetrics.heatmapHoverCardHeight)")

    let gridWidth = UsageStatsMetrics.heatmapGridWidth(inPanelWidth: NotchMenuMetrics.panelWidthMax)
    let side = UsageStatsMetrics.heatmapCellSide(forGridWidth: gridWidth)
    let pitch = side + UsageStatsMetrics.heatmapCellSpacing
    let cardWidth = UsageStatsMetrics.heatmapHoverCardWidth
    let gridHeight = UsageStatsMetrics.heatmapGridHeight(forGridWidth: gridWidth)
    let ceiling = -UsageStatsMetrics.heatmapSpaceAboveGrid
    let lowest = gridHeight + UsageStatsMetrics.heatmapSpaceBelowGrid
      - UsageStatsMetrics.heatmapHoverCardHeight

    // 中段的格子：浮卡放在它右侧。
    let middle = UsageStatsMetrics.heatmapHoverCardPosition(
      column: 10, row: 3, gridWidth: gridWidth)
    #expect(abs(middle.width - (10 * pitch + side + 6)) < 0.01)
    // 贴右缘：翻到左侧，且两种情况都不越出格网宽（浮卡不许被卡片裁掉）。
    let edge = UsageStatsMetrics.heatmapHoverCardPosition(
      column: UsageStatsCalendar.heatmapWeekCount - 1, row: 0, gridWidth: gridWidth)
    #expect(abs(edge.width - (52 * pitch - cardWidth - 6)) < 0.01)
    for position in [middle, edge] {
      #expect(position.width >= 0 && position.width + cardWidth <= gridWidth + 0.01)
    }
    // 纵向：任何一行都夹在卡片内容范围里（浮卡比格网高，光夹格网会顶出卡片）。
    for row in 0..<UsageStatsCalendar.daysPerWeek {
      let y = UsageStatsMetrics.heatmapHoverCardPosition(
        column: 20, row: row, gridWidth: gridWidth
      ).height
      #expect(y >= ceiling - 0.01, "第 \(row) 行浮卡顶到卡片外：\(y)")
      #expect(y <= max(lowest, ceiling) + 0.01, "第 \(row) 行浮卡掉到卡片外：\(y)")
    }
  }

  @Test("热力图：渲染出的格子与日期一一对应（行序 / 未来格 / 档位都对）")
  @MainActor
  func heatmapPixelsMatchGridGeometry() throws {
    // 固定「今天」= 2026-09-18（周五）15:00，周一起算：末列是 09-14（周一）… 09-20（周日），
    // 其中周六、周日是未来（不画）。唯一有量的一天是 09-16（周三 = 末列第 2 行）。
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    calendar.firstWeekday = 2
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 15)))
    // 非零日只有一天（少于档位数）⇒ 按 `UsageHeatmapScale` 的口径它是**最深**那一档。
    let days = [DayUsage(dayKey: "2026-09-16", total: 4_200_000, calls: 12)]

    let cardWidth = UsageStatsMetrics.contentWidth - 2 * NotchMenuMetrics.rowHorizontalPadding
    let raster = try #require(
      renderedPixels(
        of: heatmapCard(
          days: days, metric: .tokens, now: now, calendar: calendar,
          width: UsageStatsMetrics.contentWidth)))
    let scale = 2.0
    let gridWidth = UsageStatsMetrics.heatmapGridWidth(inPanelWidth: NotchMenuMetrics.panelWidthMax)
    let side = UsageStatsMetrics.heatmapCellSide(forGridWidth: gridWidth)
    let pitch = side + UsageStatsMetrics.heatmapCellSpacing
    // 格网左上角（视图坐标系）：左边是卡片内边距 + 星期标签栏；上面是卡片内边距 +
    // 汇总行 + 月份标签（`heatmapSpaceAboveGrid` 已经含卡片内边距，别再叠加一次）。
    let gridLeft = NotchMenuMetrics.rowHorizontalPadding + UsageStatsMetrics.heatmapWeekdayGutterWidth
    let gridTop = UsageStatsMetrics.heatmapSpaceAboveGrid
    let gridHeight = UsageStatsMetrics.heatmapGridHeight(forGridWidth: gridWidth)
    let lastColumn = UsageStatsCalendar.heatmapWeekCount - 1

    /// 一格中心的像素坐标（位图第 0 行对应图像顶部）。
    func center(column: Int, row: Int) -> (x: Int, y: Int) {
      let x = gridLeft + CGFloat(column) * pitch + side / 2
      let y = gridTop + CGFloat(row) * pitch + side / 2
      return (Int((x * scale).rounded()), Int((y * scale).rounded()))
    }
    func alpha(_ x: Int, _ y: Int) -> Int { Int(raster.pixels[(y * raster.width + x) * 4 + 3]) }
    func channels(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
      let offset = (y * raster.width + x) * 4
      return (
        Int(raster.pixels[offset]), Int(raster.pixels[offset + 1]), Int(raster.pixels[offset + 2])
      )
    }

    // 只在格网那一条带里找「不透明」的格子（最深档 alpha = 255；空档是 0.09 叠白 ≈ 23，
    // 未来格完全透明）——避开说明 / 汇总 / 图例里的文字与色块。
    let top = Int((gridTop * scale).rounded())
    let bottom = Int(((gridTop + gridHeight) * scale).rounded())
    var bright: [(x: Int, y: Int)] = []
    for y in top..<min(bottom, raster.height) {
      for x in 0..<raster.width where alpha(x, y) >= 230 {
        bright.append((x, y))
      }
    }
    #expect(!bright.isEmpty, "没有渲染出最深档的格子（像素阈值或色阶有问题）")

    let minX = bright.map(\.x).min() ?? 0
    let maxX = bright.map(\.x).max() ?? 0
    let minY = bright.map(\.y).min() ?? 0
    let maxY = bright.map(\.y).max() ?? 0
    let expected = center(column: lastColumn, row: 2)

    // 亮区的中心必须落在 09-16 那一格的几何位置上：行列写反、整列错位、日期与格子的
    // 对应算错，都会把它推到别处（格子小，容差按 ±3px ≈ 1.5pt 给）。
    #expect(
      abs(Double(minX + maxX) / 2 - Double(expected.x)) <= 3,
      "亮格横向中心 \((minX + maxX) / 2) ≠ 预期 \(expected.x)")
    #expect(
      abs(Double(minY + maxY) / 2 - Double(expected.y)) <= 3,
      "亮格纵向中心 \((minY + maxY) / 2) ≠ 预期 \(expected.y)")
    // 亮区大小 ≈ 一格：整列 / 整行变亮会让它明显更大。
    #expect(abs(CGFloat(maxX - minX + 1) - side * scale) <= 3)
    #expect(abs(CGFloat(maxY - minY + 1) - side * scale) <= 3)
    // 深色的色相来自「总量」那一路（浅蓝），不是随便一个高亮色。
    let brightColor = channels(expected.x, expected.y)
    #expect(brightColor.r > 120 && brightColor.g > 160 && brightColor.b > 220, "\(brightColor)")

    // 同列的周一（09-14）没有用量 ⇒ 空档轨道（弱白底）；周六 / 周日是未来 ⇒ 那一格不画，
    // 露出的只是卡片自己的底色（比空档轨道还淡）。
    let track = center(column: lastColumn, row: 0)
    let trackAlpha = alpha(track.x, track.y)
    #expect(trackAlpha >= 12 && trackAlpha <= 40, "空档格 alpha = \(trackAlpha)")
    for row in [5, 6] {
      let future = center(column: lastColumn, row: row)
      let futureAlpha = alpha(future.x, future.y)
      #expect(futureAlpha < trackAlpha - 3, "第 \(row) 行的未来格被画出来了：alpha = \(futureAlpha)")
    }
  }

  @Test("展开范围选择器后滚动视口仍留得下内容（不小于 200pt）")
  func rangePickerLeavesUsableViewport() {
    let viewport =
      UsageStatsMetrics.sectionHeight - UsageStatsMetrics.rangePickerHeight
      - UsageStatsMetrics.contentTopGap - NotchMenuMetrics.rowSpacing
    #expect(viewport >= 200, "展开选择器后只剩 \(viewport)pt")
  }

  @Test("图例五路在内容宽内排得下（各语言都试）")
  func legendFitsContentWidth() {
    let keys = ["Total tokens", "Input", "Output", "Cache read", "Cache write"]
    #expect(keys.count == StatsSeries.visibleOptions)

    let dots = CGFloat(StatsSeries.visibleOptions) * UsageStatsMetrics.chartLegendDotSize
    // 每格：圆点与文字之间 4pt，格与格之间 chartLegendGap。
    let spacing =
      CGFloat(StatsSeries.visibleOptions) * (4 + UsageStatsMetrics.chartLegendGap)
    let available =
      UsageStatsMetrics.contentWidth - 2 * NotchMenuMetrics.rowHorizontalPadding - dots - spacing

    for code in ["en", "zh-Hans"] {
      let bundle = LocalizationManager.bundle(for: code)
      let total = keys.reduce(CGFloat(0)) { running, key in
        running
          + labelWidth(bundle.localizedString(forKey: key, value: nil, table: nil), size: 10)
      }
      #expect(total <= available, "\(code) 的图例需要 \(total)pt，只有 \(available)pt")
    }
  }

  @Test("y 轴刻度栏按最长刻度文案放宽，且不越过上限")
  func yAxisGutterFitsWidestLabel() {
    let font = NSFont.systemFont(ofSize: UsageStatsMetrics.chartYAxisLabelSize)
    // 现实里最长的刻度文案：缩写值一律 2 位小数，所以大数会有 8–9 个字符
    // （`9999.99亿` / `1000.00B`），刻度栏必须按它们量出来。
    let labels = [
      "9,999", "1234.57万", "9999.99万", "695.39亿", "9999.99亿", "10000.00亿",
      "12.49K", "999.99K", "999.99M", "1000.00B",
    ]

    let widest =
      labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    // 上限必须容得下最长的那条（否则刻度会被截断成「99.9…」）。
    #expect(
      widest + UsageStatsMetrics.chartYAxisLabelPadding <= UsageStatsMetrics.chartYAxisMaximumWidth,
      "最长刻度要 \(widest + UsageStatsMetrics.chartYAxisLabelPadding)pt，上限只有 \(UsageStatsMetrics.chartYAxisMaximumWidth)pt"
    )

    for label in labels {
      let width = (label as NSString).size(withAttributes: [.font: font]).width
      let gutter = UsageStatsMetrics.chartYAxisWidth(forLabelWidths: [width])
      #expect(gutter >= UsageStatsMetrics.chartYAxisMinimumWidth)
      #expect(gutter <= UsageStatsMetrics.chartYAxisMaximumWidth)
      #expect(
        gutter
          >= min(
            UsageStatsMetrics.chartYAxisMaximumWidth,
            width + UsageStatsMetrics.chartYAxisLabelPadding))
    }

    // 还没有峰值（过渡帧）时给空数组：落在下限上，不会退化成 0 宽度。
    #expect(
      UsageStatsMetrics.chartYAxisWidth(forLabelWidths: [])
        == UsageStatsMetrics.chartYAxisMinimumWidth)

    // 最宽的刻度栏下，绘图区仍然排得开。
    let plotWidth =
      UsageStatsMetrics.contentWidth - 2 * NotchMenuMetrics.rowHorizontalPadding
      - UsageStatsMetrics.chartYAxisMaximumWidth
    #expect(plotWidth >= 200)
  }

  @Test("总览卡：最长的大数字与两个小计仍排得下")
  func summaryNumberFitsWithStats() {
    let available = UsageStatsMetrics.contentWidth - 2 * NotchMenuMetrics.rowHorizontalPadding

    // 缩写值一律 2 位小数，最长的那几档是 8–9 个字符（见 `tokenShortFormatKeepsTwoDecimals`）。
    let widestNumber =
      ["9,999", "9999.99万", "1234.57万", "9999.99亿", "10000.00亿", "1000.00B"]
      .map {
        monospacedWidth($0, size: UsageStatsMetrics.summaryNumberSize, weight: .semibold)
      }
      .max() ?? 0
    let statNumber = monospacedWidth(
      "9,999", size: UsageStatsMetrics.summaryStatSize, weight: .semibold)
    let sessions = max(statNumber, labelWidth("Sessions", size: 10))
    let calls = max(statNumber, labelWidth("Tool calls", size: 10))

    let needed =
      widestNumber + 8 + sessions + UsageStatsMetrics.summaryStatSpacing + calls
    #expect(needed <= available, "总览卡首行需要 \(needed)pt，只有 \(available)pt")
  }

  @Test("统计页在紧凑档面板宽度内不被裁切（曲线图不能按最宽档写死宽度）")
  @MainActor
  func statisticsPageFitsCompactWidth() {
    // 面板宽 = min(screenRect.width * 0.4, panelWidthMax) × 面板尺寸档，内容区再减容器的左右
    // 内边距（统计页是读数面、不显示侧栏，因此不再减侧栏）：紧凑档下是 480 × 0.88 − 2×(12 + 4) = 390.4pt。
    // 页面里只要有**按最宽档推出来的固定宽度**，整页就会比容器宽、被居中裁掉两侧（实测曲线图
    // 的固定绘图区宽度 380 → 整页 464，「Total tokens」标签的墨迹左缘从 12 掉到 0）。
    let compactContentWidth = NotchMenuMetrics.contentAreaWidth(
      inPanelWidth: NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale)

    let viewModel = UsageStatsViewModel()
    viewModel.snapshot = statisticsFixtureSnapshot()

    let leftMost = leftMostInk(
      of: UsageStatsView(viewModel: viewModel, contentWidth: compactContentWidth)
        .frame(width: compactContentWidth))

    // 渲染失败时会返回 0（页面左上角不可能一个墨迹都没有）：先钉住「真的量到了像素」，
    // 否则这条用例会在渲染失效时静默变成恒真断言。
    #expect(leftMost > 0, "没有量到墨迹：离屏渲染可能失效了")
    #expect(
      leftMost >= NotchMenuMetrics.rowHorizontalPadding - 0.5,
      "紧凑档（内容宽 \(compactContentWidth)pt）下页面左侧被裁 \(NotchMenuMetrics.rowHorizontalPadding - leftMost)pt"
    )
  }

  /// 统计页的固定夹具：各段都要有数据——空段不参与版面，量不到真正的宽度。
  @MainActor
  private func statisticsFixtureSnapshot() -> UsageStatsSnapshot {
    var snapshot = UsageStatsSnapshot(window: .preset(.all))
    let totals = UsageTotals(
      input: 1_000_000, output: 200_000, cacheRead: 900_000, cacheWrite: 50_000, sessions: 3,
      calls: 120)
    snapshot.totals = totals
    snapshot.agents = [
      AgentUsage(agent: .claudeCode, totals: totals),
      AgentUsage(agent: .ohMyPi, totals: UsageTotals(input: 500_000, sessions: 1, calls: 40)),
    ]
    snapshot.models = [
      ModelUsage(name: "claude-sonnet-4-5-20250929", totals: totals),
      ModelUsage(name: "deepseek-v4-flash", totals: UsageTotals(input: 400_000, sessions: 2)),
    ]
    snapshot.tools = [ToolUsage(name: "bash", calls: 40), ToolUsage(name: "read", calls: 30)]
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    snapshot.trend = (0..<30).map { index in
      TrendPoint(
        start: start.addingTimeInterval(Double(index) * 86_400), input: 10_000, output: 2_000,
        cacheRead: 5_000, cacheWrite: 500, calls: 4)
    }
    snapshot.indexedAt = start
    return snapshot
  }

  /// 视图离屏渲染后，左上角首个文字块的墨迹左缘（pt）。
  ///
  /// 页面比容器宽时 SwiftUI 会把它居中、裁掉两侧，因此这个值小于页内边距就说明被裁了。
  /// 用像素而不是 `NSHostingView.fittingSize`：理想宽包含可伸缩元素（脚注这类长文本的
  /// 不换行宽度，英文界面实测 448pt）——它超过容器并不等于被裁，判据会误报。
  @MainActor
  private func leftMostInk(of view: some View) -> CGFloat {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { return 0 }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // 位图第 0 行对应图像顶部（`CGContext` 画完 `CGImage` 后是自顶向下的行序）。
    func hasInk(_ x: Int, _ y: Int) -> Bool {
      let offset = (y * width + x) * 4
      return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 120
    }
    for y in 0..<height {
      for x in 0..<width where hasInk(x, y) { return CGFloat(x) / 2 }
    }
    return 0
  }

  /// 离屏渲染一张位图，返回 premultiplied RGBA 像素与尺寸（2x，与 `leftMostInk` 同一口径）。
  @MainActor
  private func renderedPixels(
    of view: some View, scale: CGFloat = 2
  ) -> (pixels: [UInt8], width: Int, height: Int)? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
  }

  @Test("模型榜两列排得开、token 列容得下最长文案")
  func modelRowFitsColumns() {
    // 模型行的 token 列用 11pt 等宽，缩写值一律 2 位小数后最长的是 9 个字符
    // （`10000.00亿` / `1000.00B`）——固定列宽必须容得下它们，否则会被截断。
    let widest =
      ["9,999", "1234.57万", "9999.99万", "10000.00亿", "1000.00B"]
      .map { monospacedWidth($0, size: 11, weight: .medium) }
      .max() ?? 0
    #expect(
      widest + 2 <= UsageStatsMetrics.modelTokenWidth,
      "最长 token 文案要 \(widest + 2)pt，列宽只有 \(UsageStatsMetrics.modelTokenWidth)pt")

    // 两列 + 占比条：占比条至少要有 40pt 才看得出差别（与工具榜同一判据）。
    let panels: [(name: String, width: CGFloat)] = [
      ("standard", NotchMenuMetrics.panelWidthMax),
      ("compact", NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale),
    ]
    for panel in panels {
      let rowWidth =
        UsageStatsMetrics.modelNameWidth + UsageStatsMetrics.modelTokenWidth
        + 2 * NotchMenuMetrics.rowHorizontalPadding + 2 * 10 + 40
      #expect(rowWidth <= panel.width, "\(panel.name) 档下模型行需要 \(rowWidth)pt")
    }
  }

  /// 与真实页面同构的热力图卡：`SettingsCard` + 左右内边距 + 页面内容宽。
  /// 用例按 `width` 出图（= 页面内容宽），因此格边长、格网高与解析式可以逐值对拍。
  @MainActor
  private func heatmapCard(
    days: [DayUsage], metric: StatsHeatmapMetric, now: Date, calendar: Calendar, width: CGFloat
  ) -> some View {
    SettingsCard {
      UsageHeatmap(
        days: days, metric: .constant(metric), contentWidth: width, now: now, calendar: calendar
      )
      .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
    }
    .frame(width: width)
  }

  /// 汇总行日期范围的最长形态（跨年、两位月日）：`2025年10月13日 – 2026年10月14日`。
  private func dateRangeLabel(code: String) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    let style = Date.FormatStyle.dateTime.year().month().day().locale(Locale(identifier: code))
    let from = calendar.date(from: DateComponents(year: 2025, month: 10, day: 13)) ?? Date()
    let to = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14)) ?? Date()
    return "\(from.formatted(style)) – \(to.formatted(style))"
  }

  /// 某语言的星期缩写（下标 0 = 周日，与 `Calendar.firstWeekday` 同一套编号）。
  private func weekdaySymbols(code: String) -> [String] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: code)
    return calendar.shortWeekdaySymbols
  }

  /// 等宽数字的排版宽度（总览卡的大数字与小计都用等宽字形）。
  private func monospacedWidth(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular
  ) -> CGFloat {
    (text as NSString).size(
      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight)]
    ).width
  }

  /// 芯片格宽：页内容宽减去设置页的内边距与卡片内边距，再按列数与列间距四等分。
  private func chipWidth(panelWidth: CGFloat) -> CGFloat {
    let gridWidth =
      panelWidth - 2 * NotchMenuMetrics.panelContentPadding
      - 2 * NotchMenuMetrics.rowHorizontalPadding
    let columns = CGFloat(UsageStatsMetrics.rangeChipColumns)
    return (gridWidth - UsageStatsMetrics.rangeChipSpacing * (columns - 1)) / columns
  }

  /// 标签的排版宽度；字号与视图一致（芯片 10 号、页眉标题 13 号 semibold）。
  private func labelWidth(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .medium
  ) -> CGFloat {
    (text as NSString).size(
      withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]
    ).width
  }

  @Test("统计入口：图表按钮进统计分组，两个入口的 xmark 不重叠")
  @MainActor
  func entryTogglesKeepFacesExclusive() {
    let model = makeModel()
    #expect(model.isShowingSettings == false)
    #expect(model.isShowingStatistics == false)

    // 图表按钮：进设置面板的统计分组。
    model.toggleStatistics()
    #expect(model.contentType == .menu)
    #expect(model.menuSection == .statistics)
    #expect(model.isShowingStatistics)
    // 只有图表按钮显示 xmark（齿轮对统计分组显示图标，不是 xmark）。
    #expect(model.isShowingSettings == false)

    // 齿轮按钮：从统计分组回到上一次待的设置分组。
    model.toggleMenu()
    #expect(model.contentType == .menu)
    #expect(model.menuSection == .general)
    #expect(model.isShowingSettings)

    // 在设置里点图表按钮：再进统计分组。
    model.toggleStatistics()
    #expect(model.menuSection == .statistics)

    // 再点一次图表按钮：退回会话列表。
    model.toggleStatistics()
    #expect(model.contentType == .instances)
  }

  @Test("齿轮按钮记得上一次待过的设置分组")
  @MainActor
  func gearReturnsToLastSettingsSection() {
    let model = makeModel()
    model.contentType = .menu
    model.menuSection = .agents

    model.toggleStatistics()
    #expect(model.menuSection == .statistics)

    model.toggleMenu()
    #expect(model.contentType == .menu)
    #expect(model.menuSection == .agents)
  }

  @Test("设置页的返回箭头离开设置面板")
  @MainActor
  func backChevronLeavesSettings() {
    let model = makeModel()
    model.contentType = .menu
    model.menuSection = .statistics

    model.exitMenu()
    #expect(model.contentType == .instances)
  }

  /// 统计页所在的模型（设备矩形取用户里把胶囊调宽后的宽度：300pt 时「点刘海收起」
  /// 的判定带会盖住头部按钮，见 NotchPanelClickTests）。
  @MainActor
  private func makeModel() -> NotchViewModel {
    NotchViewModel(
      deviceNotchRect: CGRect(x: 0, y: 0, width: 300, height: 32),
      screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowHeight: windowHeight,
      hasPhysicalNotch: false
    )
  }

  @Test("空态高度不超过分组可视内容区")
  func emptyStateFitsPanel() {
    // 页面顶部只剩一份间距（设置页给的 contentTopGap）：面板高度的解析式里也只算一次。
    #expect(
      UsageStatsMetrics.emptyStateMinHeight + UsageStatsMetrics.contentTopGap
        <= UsageStatsMetrics.sectionHeight)
    #expect(
      UsageStatsMetrics.emptyStateMinHeight
        >= UsageStatsMetrics.sectionHeight - UsageStatsMetrics.contentTopGap - 40)
  }

  @Test("不进统计的名单在两种面板宽度、两种语言下都只占一行")
  func excludedAgentNoteFitsOneLine() {
    // 统计页的高度是解析式预算，脚注里的这一行是「往整页新增的一行」
    // （见 `UsageStatsMetrics.sectionHeight`）：宽度上装不进最窄档，就得折行、高度预算失效。
    // 短名键与 `AgentKind.shortName` 一一对应；名单本身取扫描器现算的那一份，因此
    // 「改名单 / 改短名 / 加 Agent」都会让这条用例失败——那时要重算统计页的高度预算。
    let nameKeys = ["Gemini", "Kimi", "Cline", "Grok", "Trae", "Trae CLI", "DSH"]
    #expect(
      AgentKind.allCases.filter { TranscriptUsageScanner.agentsWithoutUsage.contains($0) }.count
        == nameKeys.count)

    let panels: [(name: String, width: CGFloat)] = [
      ("standard", NotchMenuMetrics.panelWidthMax),
      ("compact", NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale),
    ]
    for panel in panels {
      // 可用宽 = 面板内容宽 − 脚注自己的左右内边距（脚注是整页里最靠外的一行）。
      let available =
        panel.width - 2 * NotchMenuMetrics.panelContentPadding
        - 2 * NotchMenuMetrics.rowHorizontalPadding
      for code in ["en", "zh-Hans"] {
        let bundle = LocalizationManager.bundle(for: code)
        let names = nameKeys.map { bundle.localizedString(forKey: $0, value: nil, table: nil) }
        let note = String(
          format: bundle.localizedString(forKey: "Not counted: %@", value: nil, table: nil),
          names.joined(separator: ", "))
        // 用 medium 量（脚注实际是 regular）：量出来的偏宽，判据因此是保守的。
        let needed = labelWidth(note, size: 10)
        #expect(
          needed <= available,
          "\(panel.name) 档下 \(code) 的「\(note)」要 \(needed)pt，可用 \(available)pt")
      }
    }
  }

  @Test("额度入口：三个头部按钮的 xmark 互斥，且不污染上一次待过的设置分组")
  @MainActor
  func quotaEntryKeepsThreeFacesExclusive() {
    let model = makeModel()
    #expect(model.isShowingQuota == false)

    // 额度按钮：进设置面板的额度分组。
    model.toggleQuota()
    #expect(model.contentType == .menu)
    #expect(model.menuSection == .quota)
    #expect(model.isShowingQuota)
    // 额度页上只有额度按钮显示 xmark（图表与齿轮都显示自己的图标）。
    #expect(model.isShowingStatistics == false)
    #expect(model.isShowingSettings == false)

    // 齿轮按钮：从额度分组回到上一次待的设置分组。
    model.toggleMenu()
    #expect(model.contentType == .menu)
    #expect(model.menuSection == .general)
    #expect(model.isShowingSettings)

    // 在设置里点额度按钮：再进额度分组；再点一次退回会话列表。
    model.toggleQuota()
    #expect(model.menuSection == .quota)
    model.toggleQuota()
    #expect(model.contentType == .instances)

    // 额度页不污染「上一次待过的设置分组」：先进智能体页，再从额度页用齿轮回来。
    let other = makeModel()
    other.contentType = .menu
    other.menuSection = .agents
    other.toggleQuota()
    #expect(other.menuSection == .quota)
    other.toggleMenu()
    #expect(other.menuSection == .agents)
  }

  /// 额度页之外，设置页给的那一段固定开销（上下内边距 + 页眉 + 顶部间距）。
  /// 分组切换是竖向侧栏，不占垂直固定开销。
  private var quotaPageChrome: CGFloat {
    NotchMenuMetrics.listPaddingHeight + NotchMenuMetrics.pageHeaderHeight
      + NotchMenuMetrics.rowSpacing + NotchMenuMetrics.contentTopGap
  }

  @Test("额度页读数态：真实排版高度 = 解析式 + 账号列表窗口 + 详情卡可选行")
  @MainActor
  func quotaPageHeightMatchesMetrics() throws {
    // 运行时状态是共享单例（面板高度按它算），测量前显式归位；偏好域也换成独立的：
    // 这一页读账号列表，用真实偏好域会让测量结果取决于用户本机存了几个账号。
    NewAPIAccountPageState.shared.isEditingCredentials = false
    NewAPIAccountPageState.shared.setAccountCount(1)
    NewAPIAccountPageState.shared.setOptionalDetailRowCount(0)
    let defaults = try #require(UserDefaults(suiteName: "quota-layout-\(UUID().uuidString)"))

    let contentWidth = NotchMenuMetrics.contentAreaWidth
    let view = QuotaSettingsPage(viewModel: NewAPIBalanceViewModel(defaults: defaults))
      .frame(width: contentWidth)
    let measured = NSHostingView(rootView: view).fittingSize.height

    // 账号行与详情卡的可选行都是**运行时**行：解析式里没有它们，按状态对象的增量加回来。
    let expected =
      NotchMenuMetrics.contentHeight(for: .quota) - quotaPageChrome
      + NewAPIAccountPageState.shared.runtimeHeight

    #expect(measured == expected, "额度页实际排版 \(measured) ≠ 解析式 \(expected)")
  }

  @Test("额度页编辑凭据态：真实排版高度 = 解析式 + 折叠后的运行时增量")
  @MainActor
  func quotaPageEditingHeightMatchesMetrics() throws {
    // 这一条钉的是「编辑态的真实排版」：账号列表折叠成一行、详情卡的基准行换成五行凭据
    // 表单（可选行完全不画）。表单行数与 `credentialFormHeight` 一旦漂移（加字段忘了改
    // 预算、行高被改），这里就红——而读数态是看不出来的。
    let defaults = try #require(UserDefaults(suiteName: "quota-editing-\(UUID().uuidString)"))
    AppSettings.setNewAPIAccounts(
      [NewAPIAccount(label: "a"), NewAPIAccount(label: "b")], defaults: defaults)
    let model = NewAPIBalanceViewModel(defaults: defaults)
    NewAPIAccountPageState.shared.setAccountCount(model.accounts.count)
    NewAPIAccountPageState.shared.setOptionalDetailRowCount(2)
    NewAPIAccountPageState.shared.isEditingCredentials = true
    defer {
      NewAPIAccountPageState.shared.isEditingCredentials = false
      NewAPIAccountPageState.shared.setOptionalDetailRowCount(0)
      NewAPIAccountPageState.shared.setAccountCount(1)
    }

    let contentWidth = NotchMenuMetrics.contentAreaWidth
    let view = QuotaSettingsPage(viewModel: model).frame(width: contentWidth)
    let measured = NSHostingView(rootView: view).fittingSize.height

    let expected =
      NotchMenuMetrics.contentHeight(for: .quota) - quotaPageChrome
      + NewAPIAccountPageState.shared.runtimeHeight

    // 编辑态比读数态的最坏组合矮：编辑时列表折叠成一行、也不画可选行，两个运行时项
    // 因此不会叠加（上面故意把可选行写成 2，编辑态也不该把它算进高度）。
    #expect(
      NewAPIAccountPageState.shared.runtimeHeight == NewAPIAccountPageState.editingRuntimeHeight)
    #expect(measured == expected, "编辑凭据态实际排版 \(measured) ≠ 解析式 \(expected)")
  }

  /// 凭据表单的文本框宽度：理想上限与行的可用宽取小，紧凑档因此不会把标签列挤没
  /// （真机实测：写死 246pt 时紧凑档的标签列只剩约 38pt，标题与副标题都变成省略号）。
  @Test("凭据行的文本框按行的可用宽收窄：紧凑档下标签列仍有它的下限")
  @MainActor
  func credentialFieldNarrowsAtCompactWidth() {
    // 行的可用宽 = 面板内容宽 − 行左右内边距 − 徽标块（`SettingsRowLabel` 的排版）：
    // 它才是文本框与标签列争的那块宽度。
    func rowAvailableWidth(contentWidth: CGFloat) -> CGFloat {
      contentWidth - 2 * NotchMenuMetrics.rowHorizontalPadding
        - NotchMenuMetrics.badgeSize - NotchMenuMetrics.badgeGap
    }
    let standard = rowAvailableWidth(
      contentWidth: NotchMenuMetrics.contentAreaWidth)
    let compact = rowAvailableWidth(
      contentWidth: NotchMenuMetrics.contentAreaWidth(
        inPanelWidth: NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale))

    // 账号名 / 服务器地址两行的理想上限就是 `credentialFields` 里的 246：标准档下它必须
    // 原样保住——标准档的排版与改造前逐点一致。
    #expect(
      BalanceConfigRow.fieldWidth(preferred: 246, available: standard, isSecret: false)
        == 246,
      "标准档下长字段应当仍然拿满 246pt（可用宽 \(standard)pt）")

    // 紧凑档：按可用宽收窄，标签列至少留下它自己的下限（130pt）+ 尾部间隙（8pt）。
    let compactField = BalanceConfigRow.fieldWidth(
      preferred: 246, available: compact, isSecret: false)
    #expect(compactField < 246, "紧凑档下长字段必须收窄，否则标签列会被挤成省略号")
    #expect(
      abs(compactField - (compact - 138)) < 0.01,
      "紧凑档下文本框应当收到 \(compact - 138)pt，实际 \(compactField)pt")
    #expect(
      compact - compactField >= 130 - 0.01,
      "紧凑档下标签列只剩 \(compact - compactField)pt，低于下限就会变成省略号")

    // 密钥行尾部还挂着显示 / 隐藏按钮（间距 6 + 命中框 28），那一段也要先扣掉：
    // 可用宽够时（用 246 的长字段试）收到 `可用宽 − 标签列下限 − 尾部间隙 − 34`。
    #expect(
      abs(
        BalanceConfigRow.fieldWidth(preferred: 246, available: compact, isSecret: true)
          - (compact - 138 - 34)) < 0.01,
      "密钥行的文本框宽度没有扣掉显示 / 隐藏按钮那一段")
    // 扣完之后仍装得下理想上限（短字段 150pt）时按上限来，不被可用宽改写。
    #expect(
      BalanceConfigRow.fieldWidth(preferred: 150, available: compact, isSecret: true) == 150)

    // 理想上限本身就短（`sk-…` / 令牌 / 用户 ID）时按上限走，不受可用宽影响。
    #expect(
      BalanceConfigRow.fieldWidth(preferred: 150, available: compact, isSecret: false) == 150)
  }

  // MARK: - 额度页：详情卡按「有没有数据」增减行

  /// 详情卡的可选行（身份 / 密钥额度）随「这一槽取不取得到数据」增减：平台只给 `sk-` 时
  /// 不画账号段、只给访问令牌时不画密钥段、两个都没配就只剩「凭据」那一行。
  ///
  /// 这一条既钉**规则**（可选行数），又钉**版面**（真实排版 == 解析式）——页面渲染与写回
  /// 走同一个函数，因此两者不会各自漂移。
  @Test("额度页详情卡：拿不到数据的行不画，真实排版 = 解析式")
  @MainActor
  func quotaPageDetailRowsFollowData() async throws {
    let contentWidth = NotchMenuMetrics.contentAreaWidth

    struct Scenario {
      let name: String
      let config: NewAPIConfig
      let served: [String: (status: Int, body: String)]
      let expectedOptionalRows: Int
    }

    let scenarios: [Scenario] = [
      Scenario(
        name: "空账号（什么都没填）",
        config: NewAPIConfig(),
        served: [:],
        expectedOptionalRows: 0),
      Scenario(
        name: "只有访问令牌",
        config: NewAPIConfig(serverURL: "https://h.example.com", accessToken: "t"),
        served: [
          "/api/user/self": (200, Self.accountBody),
          "/api/status": (200, Self.statusBody),
        ],
        expectedOptionalRows: 1),
      Scenario(
        name: "只有 API 密钥",
        config: NewAPIConfig(serverURL: "https://h.example.com", apiKey: "sk-x"),
        served: [
          "/api/usage/token/": (200, Self.keyBody),
          "/api/status": (200, Self.statusBody),
        ],
        expectedOptionalRows: 1),
      Scenario(
        name: "两者都有",
        config: NewAPIConfig(serverURL: "https://h.example.com", apiKey: "sk-x", accessToken: "t"),
        served: [
          "/api/user/self": (200, Self.accountBody),
          "/api/usage/token/": (200, Self.keyBody),
          "/api/status": (200, Self.statusBody),
        ],
        expectedOptionalRows: 2),
    ]

    defer {
      NewAPIAccountPageState.shared.isEditingCredentials = false
      NewAPIAccountPageState.shared.setOptionalDetailRowCount(0)
      NewAPIAccountPageState.shared.setAccountCount(1)
    }

    for scenario in scenarios {
      QuotaLayoutStub.reset(scenario.served)
      let defaults = try #require(UserDefaults(suiteName: "quota-rows-\(UUID().uuidString)"))
      AppSettings.setNewAPIAccounts(
        [NewAPIAccount(label: "case", config: scenario.config)], defaults: defaults)
      let model = NewAPIBalanceViewModel(
        client: NewAPIBalanceClient(session: QuotaLayoutStub.session()), defaults: defaults)
      model.refresh()
      for _ in 0..<300 where model.isRefreshing {
        try? await Task.sleep(for: .milliseconds(20))
      }

      // 页面在 onAppear / 读数变化时就是这么写回的（同一个函数），这里手工走一遍。
      NewAPIAccountPageState.shared.setAccountCount(model.accounts.count)
      NewAPIAccountPageState.shared.setOptionalDetailRowCount(
        QuotaReadingSelection.optionalDetailRowCount(model.selectedReading))
      #expect(
        NewAPIAccountPageState.shared.optionalDetailRowCount == scenario.expectedOptionalRows,
        "\(scenario.name)：详情卡可选行数应为 \(scenario.expectedOptionalRows)")

      let view = QuotaSettingsPage(viewModel: model).frame(width: contentWidth)
      let measured = NSHostingView(rootView: view).fittingSize.height
      let expected =
        NotchMenuMetrics.contentHeight(for: .quota) - quotaPageChrome
        + NewAPIAccountPageState.shared.runtimeHeight
      #expect(
        measured == expected,
        "\(scenario.name)：实际排版 \(measured) ≠ 解析式 \(expected)（可选行 \(NewAPIAccountPageState.shared.optionalDetailRowCount)）"
      )
    }
  }

  // MARK: - 夹具

  /// 响应体与 `NewAPIBalanceTests` 的夹具同形（那边是纯解码用例，这边要真跑一次取数）。
  private static let accountBody = """
    {"data":{"quota":175134432,"used_quota":8274865568,"display_name":"tester","id":7,
    "group":"default","request_count":9},"message":"","success":true}
    """
  private static let keyBody = """
    {"data":{"total_granted":1000,"total_available":600,"total_used":400,
    "unlimited_quota":false},"message":"","success":true}
    """
  private static let statusBody = """
    {"data":{"version":"v9.9.9","display_in_currency":true,"quota_display_type":"USD",
    "quota_per_unit":500000,"usd_exchange_rate":1},"message":"","success":true}
    """
}

// MARK: - 额度页版面用例的私有桩

/// 最小 `URLProtocol` 桩：只为额度页的版面用例提供「这一槽能读 / 那一槽缺凭据」的读数。
///
/// **不复用** `NewAPIBalanceTests.BalanceStubProtocol`——它是那个套件私有的共享状态，而
/// 套件之间是并行跑的，跨套件共用会互相清表（那边注释里记了这次事故）。
nonisolated final class QuotaLayoutStub: URLProtocol {
  nonisolated(unsafe) private static var responses: [String: (status: Int, body: String)] = [:]
  private static let lock = NSLock()

  static func reset(_ table: [String: (status: Int, body: String)]) {
    lock.lock()
    responses = table
    lock.unlock()
  }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuotaLayoutStub.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    // `URL.path` 会吃掉尾斜杠（`/api/usage/token/` → `/api/usage/token`），两种写法都要认。
    let path = request.url?.path ?? ""
    Self.lock.lock()
    let hit = Self.responses[path] ?? Self.responses[path + "/"]
    Self.lock.unlock()

    guard let hit, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let response = HTTPURLResponse(
      url: url, statusCode: hit.status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(hit.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
