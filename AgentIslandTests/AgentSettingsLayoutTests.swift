//
//  AgentSettingsLayoutTests.swift
//  AgentIslandTests
//
//  「智能体」设置页的离屏渲染取证：版面判据全部来自像素，不靠肉眼；同时把两张渲染图
//  与一份量值清单写到 /tmp/agents-page-probe 供人工核对（不写进仓库）。
//
//  两条渲染通道的差别（本仓库实测，决定了下面每个判据走哪条）：
//  * `ImageRenderer` **不画 `ScrollView` 的内容**（卡片里的 Agent 行在滚动容器里，
//    整块不产生像素），但它是同步、可复现的：页面外框与滚动窗口的高度都照画。
//  * `NSHostingView.cacheDisplay` 会画滚动区内容与 AppKit 控件（开关），人工核对用的
//    PNG 走它；它的新鲜度由两条自检钉住——左上角墨迹必须与 `ImageRenderer` 一致，
//    且展开前后的墨迹高度差必须正好等于编辑器高度（陈旧快照给出的是 0）。
//
//  判据：
//  1. 不横向裁切：左上角首块墨迹的左缘 == 页内边距（标准档与紧凑档都成立）。
//  2. 展开确实长高：展开态比收起态多出一份 `AgentDirSelector.expandedPickerHeight`
//     （页面高度与墨迹高度两条都量）。
//  3. 动作条两枚按钮都在：动作条那一行的 y 带里，左右各有墨迹簇（两档都成立）。
//
//  用例串行执行（`.serialized`）：展开态是 `AgentDirSelector.shared` 上的全局状态，
//  并行跑会互相把编辑器打开/收起，量出来的版面就不是各自那条用例声明的那一份。
//

import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("智能体设置页版面", .serialized)
struct AgentSettingsLayoutTests {
  /// 渲染结果的落点：`/tmp`（探针产物不入库）。
  private let probeDirectory = URL(fileURLWithPath: "/tmp/agents-page-probe", isDirectory: true)

  /// 标准档面板的内容宽：面板宽上限减设置页的横向内边距（`NotchMenuView` 左右各 8）。
  private var standardContentWidth: CGFloat {
    NotchMenuMetrics.panelWidthMax - NotchMenuMetrics.listPaddingHeight
  }

  /// 紧凑档面板的内容宽：面板宽按档位缩放后再减同一份内边距（480 × 0.88 − 16 = 406.4）。
  private var compactContentWidth: CGFloat {
    NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale - NotchMenuMetrics.listPaddingHeight
  }

  /// 卡片第一行（批量动作条）在页面里的 y 带。
  ///
  /// 页面顶部是分组标题行 + 它与卡片之间的间距（`SettingsGroup` 的排版），卡片的
  /// 第一行就是动作条，行高由版面表钉成 `rowHeight`。
  private var bulkActionsBand: ClosedRange<CGFloat> {
    let top = NotchMenuMetrics.sectionHeaderHeight + NotchMenuMetrics.sectionHeaderGap
    return top...(top + NotchMenuMetrics.rowHeight)
  }

  // MARK: - 判据 1：不横向裁切

  @Test("智能体页在标准档与紧凑档都不被横向裁切（左上角墨迹左缘落在页内边距上）")
  @MainActor
  func pageDoesNotClipAtEitherPanelWidth() {
    for panel in panelWidths() {
      let ink = inkBox(of: ImageRendererProbe.raster(agentsPage(width: panel.width)))
      print(
        "[裁切] \(panel.name) 内容宽 \(panel.width) 墨迹左缘 \(ink.left) 上缘 \(ink.top) 像素 \(ink.pixels)")
      // 渲染失效时墨迹为空（左缘 -1）：先钉住「真的量到了像素」，否则下面的判据会
      // 在渲染失效时静默变成恒真断言。
      #expect(ink.pixels > 0, "\(panel.name) 档没有量到墨迹：离屏渲染可能失效了")
      #expect(
        abs(ink.left - NotchMenuMetrics.rowHorizontalPadding) <= 1,
        "\(panel.name) 档（内容宽 \(panel.width)pt）左上角墨迹左缘 \(ink.left)pt ≠ 页内边距 \(NotchMenuMetrics.rowHorizontalPadding)pt")
    }
  }

  // MARK: - 判据 2：展开确实长高

  @Test("展开某行的目录编辑器后，页面与墨迹都正好长高一份编辑器高度")
  @MainActor
  func directoryExpansionGrowsPageByEditorHeight() {
    withExpandedKind(nil) {
      let collapsed = pageSize(width: standardContentWidth)
      let collapsedInk = inkBox(of: NSHostingViewProbe.raster(agentsPage(width: standardContentWidth)))

      withExpandedKind(.codex) {
        let editorHeight = AgentDirSelector.shared.expandedPickerHeight
        let expanded = pageSize(width: standardContentWidth)
        let expandedInk = inkBox(
          of: NSHostingViewProbe.raster(agentsPage(width: standardContentWidth)))

        print(
          "[展开] 页面 收起 \(collapsed) → 展开 \(expanded)（增量 \(expanded.height - collapsed.height)）"
            + "；墨迹 收起高 \(collapsedInk.height) → 展开高 \(expandedInk.height)"
            + "（增量 \(expandedInk.height - collapsedInk.height)）；编辑器 \(editorHeight)pt")

        // 编辑器高度与版面表同源：`AgentDirSelector.visibleOptions` 就是卡片窗口按它撑高的行数。
        #expect(
          editorHeight
            == NotchMenuMetrics.pickerOptionsHeight(visibleOptions: AgentDirSelector.visibleOptions))
        #expect(collapsedInk.pixels > 0 && expandedInk.pixels > 0, "没有量到墨迹：离屏渲染可能失效了")
        #expect(expanded.width == collapsed.width, "展开不该改变页面宽度")
        // 页面高度：卡片可视窗口按编辑器高度撑高，整页因此长高同一份（同步通道，不受
        // 「`ImageRenderer` 不画滚动区内容」影响）。
        #expect(
          abs((expanded.height - collapsed.height) - editorHeight) <= 2,
          "页面高度只长了 \(expanded.height - collapsed.height)pt，编辑器是 \(editorHeight)pt")
        // 墨迹高度：编辑器在滚动窗口里，展开后它下面的内容整体下移同一份（走 cacheDisplay，
        // 它能画出滚动区内容）；陈旧快照在这里会得到 0。
        #expect(
          abs((expandedInk.height - collapsedInk.height) - editorHeight) <= 2,
          "墨迹高度只长了 \(expandedInk.height - collapsedInk.height)pt，编辑器是 \(editorHeight)pt")
      }
    }
  }

  // MARK: - 判据 3：动作条两枚按钮都在

  @Test("批量动作条那一行左右各有一枚按钮（两个墨迹簇），两档都成立")
  @MainActor
  func bulkActionRowShowsBothButtons() {
    for panel in panelWidths() {
      let clusters = inkClusters(
        of: ImageRendererProbe.raster(agentsPage(width: panel.width)), in: bulkActionsBand)
      print("[动作条] \(panel.name) 档 y 带 \(bulkActionsBand) 簇 \(clusters)")

      #expect(clusters.count >= 2, "\(panel.name) 档动作条那一行只量到 \(clusters.count) 个墨迹簇")
      #expect(
        clusters.contains { $0.lowerBound < panel.width / 2 },
        "\(panel.name) 档左侧没有墨迹簇：\(clusters)")
      #expect(
        clusters.contains { $0.upperBound > panel.width / 2 },
        "\(panel.name) 档右侧没有墨迹簇：\(clusters)")
    }
  }

  // MARK: - 人工核对用的两张 PNG 与量值清单

  @Test("写到 /tmp 的两张页面渲染图 + 量值清单（人工核对用，不入库）")
  @MainActor
  func writesRenderingsForVisualReview() throws {
    try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)

    var report: [String] = []
    report.append("# 智能体设置页离屏渲染取证（AgentSettingsLayoutTests 产出）")
    report.append("# 生成时间 \(ISO8601DateFormatter().string(from: Date()))")
    report.append("# 内容宽：标准档 \(standardContentWidth)pt，紧凑档 \(compactContentWidth)pt"
      + "（= 面板宽上限 \(NotchMenuMetrics.panelWidthMax) × 紧凑档缩放 \(PanelSize.compact.scale) − 面板内边距 \(NotchMenuMetrics.listPaddingHeight)）")
    report.append("# 页内边距 rowHorizontalPadding = \(NotchMenuMetrics.rowHorizontalPadding)pt")

    report.append("")
    report.append("## 判据 1：左上角首块墨迹的左缘（应 == 页内边距）")
    var leftInk: [String: CGFloat] = [:]
    for panel in panelWidths() {
      let ink = inkBox(of: ImageRendererProbe.raster(agentsPage(width: panel.width)))
      leftInk[panel.name] = ink.left
      report.append(
        "- \(panel.name)（内容宽 \(panel.width)pt）：左缘 \(ink.left)pt，上缘 \(ink.top)pt，像素 \(ink.pixels)"
          + "，偏差 \(ink.left - NotchMenuMetrics.rowHorizontalPadding)pt")
    }

    report.append("")
    report.append("## 判据 2：展开 .codex 的目录编辑器前后的高度")
    var collapsedInk = InkBox()
    var expandedInk = InkBox()
    var collapsedPage: CGSize = .zero
    var expandedPage: CGSize = .zero
    var editorHeight: CGFloat = 0
    withExpandedKind(nil) {
      collapsedPage = pageSize(width: standardContentWidth)
      collapsedInk = inkBox(
        of: NSHostingViewProbe.raster(agentsPage(width: standardContentWidth)))
    }
    withExpandedKind(.codex) {
      editorHeight = AgentDirSelector.shared.expandedPickerHeight
      expandedPage = pageSize(width: standardContentWidth)
      expandedInk = inkBox(of: NSHostingViewProbe.raster(agentsPage(width: standardContentWidth)))
      report.append(
        "- expandedPickerHeight = \(editorHeight)pt"
          + "（卡片窗口按它撑高；`AgentDirSelector.visibleOptions` = \(AgentDirSelector.visibleOptions) 行）")
    }
    report.append("- 收起：页面 \(collapsedPage)，墨迹高 \(collapsedInk.height)（\(collapsedInk.top)…\(collapsedInk.bottom)）")
    report.append("- 展开：页面 \(expandedPage)，墨迹高 \(expandedInk.height)（\(expandedInk.top)…\(expandedInk.bottom)）")
    report.append(
      "- 增量：页面 \(expandedPage.height - collapsedPage.height)pt，墨迹 \(expandedInk.height - collapsedInk.height)pt")

    report.append("")
    report.append("## 判据 3：动作条那一行的墨迹簇（左/右各一枚按钮）")
    var bandClusters: [String: [ClosedRange<CGFloat>]] = [:]
    for panel in panelWidths() {
      let clusters = inkClusters(
        of: ImageRendererProbe.raster(agentsPage(width: panel.width)), in: bulkActionsBand)
      bandClusters[panel.name] = clusters
      report.append("- \(panel.name)（内容宽 \(panel.width)pt）y 带 \(bulkActionsBand)：\(clusters)")
    }

    report.append("")
    report.append("## 两张 PNG（走 cacheDisplay：会画滚动区内容与开关）")
    var pngNotes: [String] = []
    for state in ["collapsed", "expanded"] {
      withExpandedKind(state == "expanded" ? .codex : nil) {
        let rendered = NSHostingViewProbe.raster(agentsPage(width: standardContentWidth))
        #expect(rendered != nil, "\(state) 的 cacheDisplay 没有产出位图")
        guard let image = rendered else { return }
        let ink = inkBox(of: image)
        let file = probeDirectory.appendingPathComponent("\(state).png")
        // 先删掉上一轮的图：下面的存在性判据才是「这一轮真的写出来了」，而不是遗留文件冒充。
        try? FileManager.default.removeItem(at: file)
        try? ImageWriter.write(image, to: file)

        // 新鲜度自检：另一条通道（`ImageRenderer`）也画页面外框与顶部文字，两者的
        // 左上角墨迹必须落在同一处——`cacheDisplay` 给出陈旧图层快照时这条会失败，
        // 而不是把一张空白图写成「人工核对的证据」。
        let reference = inkBox(of: ImageRendererProbe.raster(agentsPage(width: standardContentWidth)))
        #expect(
          abs(reference.left - ink.left) <= 1.5,
          "\(state) 的 cacheDisplay 墨迹左缘 \(ink.left) 与 ImageRenderer 的 \(reference.left) 对不上")
        #expect(ink.pixels > 0, "\(state) 渲染图是空白的")

        let describe =
          "- \(state).png：像素 \(image.width)×\(image.height)（\(CGFloat(image.width) / 2)×\(CGFloat(image.height) / 2)pt）"
          + "，墨迹 左 \(ink.left) 上 \(ink.top) 右 \(ink.right) 下 \(ink.bottom)（高 \(ink.height)），"
          + "md5 \(ImageWriter.md5(image))"
        pngNotes.append("\(file.path) \(describe)")
        report.append(describe)
      }
    }

    report.append("")
    report.append("## 读图须知（都不是缺陷）")
    report.append("- 墨迹右缘 ≈ 页面右缘：卡片 0.06 叠白描边与行分隔线 0.08 叠白在同一列相交处")
    report.append("  亮度约 (47,47,47)（合计 141 > 判据阈值 120），是这两条线的交点，不是内容越界。")
    report.append("- 墨迹下缘：页面最下方那张卡片（审批闸门）的最后一行。")
    report.append("- 滚动窗口按 visibleAgentRows = \(NotchMenuMetrics.visibleAgentRows) 行封顶："
      + "收起态窗口里是 5 行（共 \(AgentKind.allCases.count) 行，其余在卡内滚动）。")

    print(
      "智能体页判据：左缘 标准 \(leftInk["standard"] ?? -1)pt / 紧凑 \(leftInk["compact"] ?? -1)pt"
        + "（页内边距 \(NotchMenuMetrics.rowHorizontalPadding)pt，内容宽 标准 \(standardContentWidth) / 紧凑 \(compactContentWidth)）；"
        + "页面高 收起 \(collapsedPage.height) → 展开 \(expandedPage.height)（+\(expandedPage.height - collapsedPage.height)）；"
        + "墨迹高 收起 \(collapsedInk.height) → 展开 \(expandedInk.height)（+\(expandedInk.height - collapsedInk.height)，"
        + "编辑器 \(editorHeight)pt）")
    print("动作条簇：标准 \(bandClusters["standard"] ?? [])；紧凑 \(bandClusters["compact"] ?? [])")
    for note in pngNotes { print("PNG \(note)") }

    let reportURL = probeDirectory.appendingPathComponent("measurements.txt")
    let text = report.joined(separator: "\n") + "\n"
    try text.write(to: reportURL, atomically: true, encoding: .utf8)
    print("[量值] \(reportURL.path)")
    // 通过用例的 stdout **不会**出现在 xcodebuild 日志里（实测 print 与直接写 stderr
    // 都被测试框架吞掉），量值因此以「测试附件」随结果一起落进 xcresult：
    // `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>` 可取回。
    Attachment.record(text, named: "agents-page-probe-measurements.txt")

    #expect(FileManager.default.fileExists(atPath: reportURL.path))
    for state in ["collapsed", "expanded"] {
      let file = probeDirectory.appendingPathComponent("\(state).png")
      #expect(FileManager.default.fileExists(atPath: file.path), "\(state).png 没写出来")
    }
  }

  // MARK: - 夹具

  private func panelWidths() -> [(name: String, width: CGFloat)] {
    [("standard", standardContentWidth), ("compact", compactContentWidth)]
  }

  /// 被渲染的页面：真实产品视图 + 黑色底（面板就是黑底，人工核对时看得清层级）。
  @MainActor
  private func agentsPage(width: CGFloat) -> some View {
    AgentsSettingsPage()
      .frame(width: width)
      .background(Color.black)
  }

  /// 页面的渲染尺寸（`ImageRenderer` 按内容自然高度出图）。
  @MainActor
  private func pageSize(width: CGFloat) -> CGSize {
    ImageRendererProbe.size(agentsPage(width: width))
  }

  /// 在给定的展开态下跑一段渲染，跑完恢复原值（展开态是 `AgentDirSelector.shared`
  /// 上的全局状态，用例之间不能互相留状态）。
  @MainActor
  private func withExpandedKind(_ kind: AgentKind?, _ body: () -> Void) {
    let previous = AgentDirSelector.shared.expandedKind
    AgentDirSelector.shared.expandedKind = kind
    defer { AgentDirSelector.shared.expandedKind = previous }
    body()
  }
}

// MARK: - 像素探针

/// 墨迹包围盒（pt，原点在左上）。
struct InkBox {
  var left: CGFloat = -1
  var top: CGFloat = -1
  var right: CGFloat = -1
  var bottom: CGFloat = -1
  var pixels: Int = 0

  var height: CGFloat { pixels == 0 ? 0 : bottom - top }
}

enum ImageRendererProbe {
  /// `ImageRenderer` 出图（同步、可复现；不画 `ScrollView` 内容）。
  @MainActor
  static func raster(_ view: some View) -> CGImage? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    return renderer.cgImage
  }

  @MainActor
  static func size(_ view: some View) -> CGSize {
    guard let image = raster(view) else { return .zero }
    return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
  }
}

enum NSHostingViewProbe {
  /// `NSHostingView` + `cacheDisplay` 出图：会画滚动区内容与 AppKit 控件。
  @MainActor
  static func raster(_ view: some View, settle: TimeInterval = 0.2) -> CGImage? {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
    host.layoutSubtreeIfNeeded()
    // 让 SwiftUI 完成一次布局与 AppKit 控件（开关）的挂载：尺寸要按内容自然高度量。
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage
  }
}

enum ImageWriter {
  @MainActor
  static func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    // 原子写：测试可能被并行派到两个宿主进程，同一份探针产物不能写一半。
    try data.write(to: url, options: .atomic)
  }

  @MainActor
  static func md5(_ image: CGImage) -> String {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return "-" }
    let digest = Insecure.MD5.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - 墨迹

/// 位图按亮度判定墨迹（与 `UsageStatsLayoutTests` 同一套取法：r+g+b > 120）。
private func inkMask(_ image: CGImage) -> (width: Int, height: Int, hasInk: (Int, Int) -> Bool) {
  let width = image.width
  let height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  // 位图第 0 行对应图像顶部（`CGContext` 画完 `CGImage` 后是自顶向下的行序）。
  let buffer = pixels
  let hasInk: (Int, Int) -> Bool = { x, y in
    let offset = (y * width + x) * 4
    return Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2]) > 120
  }
  return (width: width, height: height, hasInk: hasInk)
}

/// 图像里全部墨迹的包围盒（pt）。
func inkBox(of image: CGImage?) -> InkBox {
  guard let image else { return InkBox() }
  let (width, height, hasInk) = inkMask(image)
  var box = InkBox(pixels: 0)
  var minX = width, maxX = -1, minY = height, maxY = -1
  for y in 0..<height {
    for x in 0..<width where hasInk(x, y) {
      box.pixels += 1
      if x < minX { minX = x }
      if x > maxX { maxX = x }
      if y < minY { minY = y }
      if y > maxY { maxY = y }
    }
  }
  guard box.pixels > 0 else { return InkBox() }
  box.left = CGFloat(minX) / 2
  box.top = CGFloat(minY) / 2
  box.right = CGFloat(maxX) / 2
  box.bottom = CGFloat(maxY) / 2
  return box
}

/// 指定 y 带内按列切出的墨迹簇（pt 区间）。
func inkClusters(of image: CGImage?, in band: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
  guard let image else { return [] }
  let (width, height, hasInk) = inkMask(image)
  let lower = max(0, Int(band.lowerBound * 2))
  let upper = min(height - 1, Int(band.upperBound * 2))
  guard lower <= upper else { return [] }

  var clusters: [ClosedRange<CGFloat>] = []
  var runStart: Int?
  for x in 0..<width {
    var columnInk = false
    for y in lower...upper where hasInk(x, y) {
      columnInk = true
      break
    }
    if columnInk {
      if runStart == nil { runStart = x }
    } else if let start = runStart {
      clusters.append(CGFloat(start) / 2...CGFloat(x - 1) / 2)
      runStart = nil
    }
  }
  if let start = runStart { clusters.append(CGFloat(start) / 2...CGFloat(width - 1) / 2) }
  return clusters
}