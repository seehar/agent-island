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
import Testing

@testable import AgentIsland

@Suite("统计页版面")
struct UsageStatsLayoutTests {
  /// 宿主窗口高度（与 `NotchWindowController` 一致）。
  private let windowHeight: CGFloat = 750
  /// 有真实刘海的机型上头部行的高度（macOS 菜单栏区）。
  private let notchHeight: CGFloat = 38
  /// 面板底部内边距（与 `NotchView` 给面板留的间距一致）。
  private let bottomPadding: CGFloat = 12

  /// 统计分组在默认固定开销下的面板高度（固定开销 = 头部行 + 面板底部内边距）。
  private var statisticsPanelHeight: CGFloat {
    NotchMenuMetrics.panelHeight(
      for: .statistics, expandedPickerHeight: 0,
      chromeHeight: max(24, notchHeight) + bottomPadding)
  }

  @Test("统计分组的面板连同底部内边距一起装得进窗口")
  func panelFitsWindow() {
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
          2 * 8 + UsageStatsMetrics.headerActionSize + labelWidth(title, size: 13, weight: .semibold)
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

  /// 芯片格宽：页内容宽减去设置页的内边距与卡片内边距，再按列数与列间距四等分。
  private func chipWidth(panelWidth: CGFloat) -> CGFloat {
    let gridWidth =
      panelWidth - NotchMenuMetrics.listPaddingHeight
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
}
