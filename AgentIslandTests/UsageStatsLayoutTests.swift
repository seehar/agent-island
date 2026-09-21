//
//  UsageStatsLayoutTests.swift
//  AgentIslandTests
//
//  统计页的版面不变量。统计页现在是设置面板的一个分组：面板高度由
//  `NotchMenuMetrics` 的解析式给出（`sectionHeight` 是其中一项），宿主窗口高固定 750
//  （`NotchWindowController`）——两者都要装得下，且行内两列 + 柱图要排得开。
//

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

  @Test("柱子间距随桶数变密，但始终为正")
  func barSpacingTightensWithDensity() {
    let week = UsageStatsMetrics.chartBarSpacing(barCount: 7)
    let month = UsageStatsMetrics.chartBarSpacing(barCount: 24)
    let all = UsageStatsMetrics.chartBarSpacing(barCount: 60)

    #expect(week > 0)
    #expect(month > 0)
    #expect(all > 0)
    #expect(month <= week)
    #expect(all <= month)
  }

  @Test("最密的窗口也能在面板内容宽内排下柱子")
  func denseChartFitsContentWidth() {
    // 工具榜/柱图共用页面内容宽；最密一档（「全部」按天，最多 60 个桶）也要放得下。
    let contentWidth = UsageStatsMetrics.contentWidth
    let barCount = 60
    let spacing = UsageStatsMetrics.chartBarSpacing(barCount: barCount)
    let barWidth = (contentWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)

    #expect(barWidth > 0)
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
    let viewport =
      UsageStatsMetrics.sectionHeight - UsageStatsMetrics.tabBarHeight
      - NotchMenuMetrics.rowSpacing - UsageStatsMetrics.contentTopGap
    #expect(UsageStatsMetrics.emptyStateMinHeight <= viewport)
  }
}
