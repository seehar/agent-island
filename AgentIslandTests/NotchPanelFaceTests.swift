//
//  NotchPanelFaceTests.swift
//  AgentIslandTests
//
//  面板高度与内容面的关系：换个面（会话列表 / 设置面板的统计分组）时 `openedSize`
//  立刻跟着换，收起则回到会话列表。钉这条是因为一次误判——「点图表按钮进统计分组后
//  面板还是会话列表那么矮，要收起再展开才变高」：实际是那次点击落在了头部条带上
//  （收起 → 鼠标没离开胶囊 → 悬停又自动展开成会话列表），高度本身一直是跟着面走的。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("面板高度与内容面")
struct NotchPanelFaceTests {
  /// 夹具：设备矩形按「用户把胶囊调宽到 300pt」取（与 UsageStatsLayoutTests 同款，
  /// 那一套的 makeModel 是私有的，不便跨文件共用）。
  @MainActor
  private func makeModel() -> NotchViewModel {
    NotchViewModel(
      deviceNotchRect: CGRect(x: 0, y: 0, width: 300, height: 32),
      screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowHeight: 750,
      hasPhysicalNotch: false
    )
  }

  @Test("面板高跟着内容面换：会话列表 320、统计分组被夹到上限、收起回到会话列表")
  @MainActor
  func panelHeightFollowsContentFace() {
    let model = makeModel()

    // 会话列表：固定 320（`NotchViewModel.openedSize` 的 `.instances` 分支）。
    #expect(model.contentType == .instances)
    #expect(model.openedSize.height == 320)

    // 切到统计页：高度立刻跟着换过去，不需要收起再展开。它现在是**读数面**——不套
    // 设置面的 640 上限，高度就是解析值（固定开销 + 内容高），整页一次看全。
    // 夹具的 deviceNotchRect 高 32 ⇒ 固定开销 max(24, 32) + 12 = 44。
    model.toggleStatistics()
    #expect(model.isShowingStatistics)
    #expect(NotchMenuSection.railSelection(for: .statistics) == nil, "读数面不显示侧栏")
    #expect(
      model.openedSize.height
        == max(24, 32) + 12 + NotchMenuMetrics.contentHeight(for: .statistics))

    // 齿轮按钮：从读数面回到上一次待过的设置分组——那一页有侧栏（设置面与读数面由
    // 同一份映射决定，`railSelection`）。
    model.toggleMenu()
    #expect(model.isShowingSettings)
    #expect(NotchMenuSection.railSelection(for: model.menuSection) != nil)
    #expect(model.openedSize.height <= NotchMenuMetrics.maxPanelHeight)

    // 收起：回到会话列表（既定行为——面板关掉不保留设置面，见 NotchPanelClickTests）。
    model.notchClose()
    #expect(model.contentType == .instances)
    #expect(model.openedSize.height == 320)
  }
}
