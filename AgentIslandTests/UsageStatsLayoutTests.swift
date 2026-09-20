//
//  UsageStatsLayoutTests.swift
//  AgentIslandTests
//
//  统计页的尺寸不变量。宿主窗口高固定 750（`NotchWindowController`），而设置面板那条
//  `NotchMenuMetrics.maxPanelHeight` 夹取只作用于 `.menu`；统计页的高度是自己定的，
//  一旦有人把它调大就会在真实屏幕上被裁掉顶部/底部，所以用测试守住。
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

  @Test("面板高度连同头部行与底部内边距一起装得进窗口")
  func panelFitsWindow() {
    let occupied = UsageStatsMetrics.panelHeight + max(24, notchHeight) + bottomPadding
    #expect(occupied <= windowHeight)
  }

  @Test("面板宽度不超过窗口内容宽度")
  func panelWidthFitsScreen() {
    // 面板宽度取 min(屏幕宽 × 0.4, 上限)；这里守住上限本身与视图内容的可用宽度匹配。
    let contentWidth = UsageStatsMetrics.panelWidthMax - UsageStatsMetrics.pagePadding * 2
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
    let contentWidth = UsageStatsMetrics.panelWidthMax - UsageStatsMetrics.pagePadding * 2
    let barCount = 60
    let spacing = UsageStatsMetrics.chartBarSpacing(barCount: barCount)
    let barWidth = (contentWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)

    #expect(barWidth > 0)
  }

  @Test("统计入口的互斥规则：只切自己的面，不动设置面板")
  @MainActor
  func entryToggleKeepsFacesExclusive() {
    let model = NotchViewModel(
      deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 38),
      screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowHeight: windowHeight,
      hasPhysicalNotch: false
    )

    model.toggleStats()
    #expect(model.contentType == .stats)

    // 从统计页点设置：直接切到设置面板（不是回到列表）。
    model.toggleMenu()
    #expect(model.contentType == .menu)

    // 从设置面板点统计：直接切到统计页。
    model.toggleStats()
    #expect(model.contentType == .stats)

    // 再从统计页点统计：回到会话列表。
    model.toggleStats()
    #expect(model.contentType == .instances)
  }

  @Test("统计页尺寸由常量给出，且不与设置面板的夹取混淆")
  @MainActor
  func openedSizeUsesStatsMetrics() {
    let model = NotchViewModel(
      deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 38),
      screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowHeight: windowHeight,
      hasPhysicalNotch: false
    )
    model.contentType = .stats
    let size = model.openedSize

    #expect(size.height == UsageStatsMetrics.panelHeight)
    #expect(size.width == min(1920 * 0.4, UsageStatsMetrics.panelWidthMax))
  }

  @Test("空态高度不超过面板内容区")
  func emptyStateFitsPanel() {
    let contentHeight =
      UsageStatsMetrics.panelHeight - UsageStatsMetrics.pagePadding * 2
      - UsageStatsMetrics.tabBarHeight - UsageStatsMetrics.contentTopGap
    #expect(UsageStatsMetrics.emptyStateMinHeight <= contentHeight)
  }
}
