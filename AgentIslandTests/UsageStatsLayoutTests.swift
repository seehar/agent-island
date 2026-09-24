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
    // 面板宽 = min(screenRect.width * 0.4, panelWidthMax) × 面板尺寸档，内容宽再减列表内边距：
    // 紧凑档下是 480 × 0.88 − 16 = 406.4pt。页面里只要有**按最宽档推出来的固定宽度**，
    // 整页就会比容器宽、被居中裁掉两侧（实测曲线图的固定绘图区宽度 380 → 整页 464，
    // 紧凑档左右各裁 15.5pt：「Total tokens」标签的墨迹左缘从 12 掉到 0）。
    let compactContentWidth =
      NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale - NotchMenuMetrics.listPaddingHeight

    let viewModel = UsageStatsViewModel()
    viewModel.snapshot = statisticsFixtureSnapshot()

    let leftMost = leftMostInk(
      of: UsageStatsView(viewModel: viewModel).frame(width: compactContentWidth))

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

  /// 额度页之外，设置页给的那一段固定开销（上下内边距 + 页眉 + 分段条 + 顶部间距）。
  private var quotaPageChrome: CGFloat {
    NotchMenuMetrics.listPaddingHeight + NotchMenuMetrics.pageHeaderHeight
      + NotchMenuMetrics.rowSpacing + NotchMenuMetrics.tabBarHeight
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

    let contentWidth = NotchMenuMetrics.panelWidthMax - NotchMenuMetrics.listPaddingHeight
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

    let contentWidth = NotchMenuMetrics.panelWidthMax - NotchMenuMetrics.listPaddingHeight
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

  // MARK: - 额度页：详情卡按「有没有数据」增减行

  /// 详情卡的可选行（身份 / 密钥额度）随「这一槽取不取得到数据」增减：平台只给 `sk-` 时
  /// 不画账号段、只给访问令牌时不画密钥段、两个都没配就只剩「凭据」那一行。
  ///
  /// 这一条既钉**规则**（可选行数），又钉**版面**（真实排版 == 解析式）——页面渲染与写回
  /// 走同一个函数，因此两者不会各自漂移。
  @Test("额度页详情卡：拿不到数据的行不画，真实排版 = 解析式")
  @MainActor
  func quotaPageDetailRowsFollowData() async throws {
    let contentWidth = NotchMenuMetrics.panelWidthMax - NotchMenuMetrics.listPaddingHeight

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
