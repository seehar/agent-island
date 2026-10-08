//
//  NotchMenuSidebarRenderTests.swift
//  AgentIslandTests
//
//  设置侧栏（分组导航）的离屏渲染判据。侧栏是自绘视图，宽度与档位都从
//  `NotchMenuMetrics` 推出来，因此三条判据都要落在像素上：
//
//  1. 渲染宽度 == `sidebarWidth(inContentWidth:)`（两档都核）。
//  2. 渲染高度 == 条目表算出来的理想高（4 个配置页 + 收尾的「关于」）——
//     `sidebarFitsShortestSettingsPage` 只核算术，这里核视图真的按它排版。
//  3. **带标签档的标签真的画在标签列里，图标档不画**：档位是视图按内容宽现算的
//     （`sidebarShowsLabels`），把它算反了不会让上面两条失败（宽度跟着一起变），
//     只有逐行看墨迹才发现「紧凑档也把标签挤进去 / 宽档没画标签」。
//
//  两张 PNG 写到 /tmp/sidebar-probe 供人工核对（探针产物不入库）。
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("设置侧栏渲染")
struct NotchMenuSidebarRenderTests {
    /// 渲染结果的落点：`/tmp`（探针产物不入库）。
    private let probeDirectory = URL(fileURLWithPath: "/tmp/sidebar-probe", isDirectory: true)

    @MainActor
    @Test("两档都按常量出图，标签只在带标签档出现")
    func railGeometryAndLabelsRenderPerMode() throws {
        try FileManager.default.createDirectory(
            at: probeDirectory, withIntermediateDirectories: true)
        var report: [String] = []

        for (name, contentWidth) in modeSamples() {
            let showsLabels = NotchMenuMetrics.sidebarShowsLabels(inContentWidth: contentWidth)
            #expect(
                showsLabels == (name == "labeled"),
                "\(name) 档（内容宽 \(contentWidth)pt）的档位判定反了")

            let railWidth = NotchMenuMetrics.sidebarWidth(inContentWidth: contentWidth)
            let tableHeight = idealRailHeight(showsLabels: showsLabels)
            guard let image = ImageRendererProbe.raster(rail(contentWidth: contentWidth)) else {
                Issue.record("\(name) 档没有出图")
                return
            }
            let size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            print(
                "[侧栏] \(name) 档（内容宽 \(contentWidth)）渲染 \(size)，栏宽 \(railWidth)，条目表 \(tableHeight)")

            #expect(size.width == railWidth, "\(name) 档渲染宽 \(size.width) ≠ 栏宽 \(railWidth)")
            #expect(
                abs(size.height - tableHeight) <= 1,
                "\(name) 档渲染高 \(size.height) ≠ 条目表 \(tableHeight)（侧栏会被裁或留白）")

            // 探针行取**未被选中**的第一项（`.general`）：选中行铺着 `segmentedThumb`
            // （0.16 叠白 → r+g+b ≈ 122，刚刚越过墨迹阈值 120），它会把整行的墨迹并成
            // 一个横跨栏宽的簇，量不出「标签在不在」。未选中行没有底色（静态渲染也没有
            // 悬停态），只有图标与标签本身的墨迹。
            let band = probeRowBand(showsLabels: showsLabels)
            let clusters = inkClusters(of: image, in: band)
            let labelColumnStarts =
                NotchMenuMetrics.sidebarIconLeading + NotchMenuMetrics.sidebarIconSize
            let inkOutsideGlyph = clusters.filter { $0.lowerBound >= labelColumnStarts }
            print("[侧栏] \(name) 档探针行 y 带 \(band) 的墨迹簇 \(clusters)")
            if showsLabels {
                #expect(!inkOutsideGlyph.isEmpty, "带标签档没有画出标签：\(clusters)")
            } else {
                #expect(inkOutsideGlyph.isEmpty, "图标档不该画标签：\(clusters)")
                // 光断言「标签列没有墨迹」的话，整行空白也会通过：图标档还要正面钉住
                // 「画出了一个居中的图标」（只有一个簇，且中心落在栏中线上）。
                #expect(clusters.count == 1, "图标档探针行应只有图标一个墨迹簇：\(clusters)")
                #expect(
                    abs(clusters[0].lowerBound + clusters[0].upperBound - railWidth) <= 3,
                    "图标档的图标没有在栏内居中：\(clusters)")
            }

            // 选中行的底色形状（`segmentedThumb` 的 0.16 叠白刚好越过墨迹阈值，因此它就是墨迹）：
            // 图标档取 `sidebarItemBox` 见方的瓦片 ⇒ 铺满栏宽；带标签档是一条整行圆角矩形
            // ⇒ 两端各内缩 `sidebarThumbInset`。「底色铺满行高的竖长方」这个观感回归只有这条
            // 判据抓得到——底色层拿到的是整个条目框（栏宽 × 行高 40），漏给方形 frame 就是 28 × 36。
            let thumbClusters = inkClusters(
                of: image,
                in: rowBand(
                    of: NotchMenuSection.sidebarSections.firstIndex(of: .agents) ?? 0,
                    showsLabels: showsLabels))
            let expectedInset = showsLabels ? NotchMenuMetrics.sidebarThumbInset : 0
            print("[侧栏] \(name) 档选中行底色墨迹簇 \(thumbClusters)")
            #expect(
                thumbClusters.count == 1
                    && abs(thumbClusters[0].lowerBound - expectedInset) <= 1
                    && abs(thumbClusters[0].upperBound - (railWidth - expectedInset)) <= 1,
                "\(name) 档选中行底色 \(thumbClusters) 与预期 [\(expectedInset)…\(railWidth - expectedInset)] 不符"
            )

            let file = probeDirectory.appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(at: file)
            try ImageWriter.write(image, to: file)
            #expect(FileManager.default.fileExists(atPath: file.path), "\(name).png 没写出来")
            report.append(
                "- \(name).png：像素 \(image.width)×\(image.height)（\(size.width)×\(size.height)pt）"
                    + "，栏宽 \(railWidth)pt，条目表 \(tableHeight)pt，"
                    + "选中行墨迹簇 \(clusters.map { "\($0.lowerBound)…\($0.upperBound)" })")
        }

        let reportURL = probeDirectory.appendingPathComponent("measurements.txt")
        try (report.joined(separator: "\n") + "\n").write(
            to: reportURL, atomically: true, encoding: .utf8)
        print("[侧栏] 量值 \(reportURL.path)")
    }

    // MARK: - 夹具

    /// 两档样本：标准档（带标签）与紧凑档（内容宽装不下标签）。
    private func modeSamples() -> [(name: String, contentWidth: CGFloat)] {
        [
            ("labeled", NotchMenuMetrics.contentAreaWidth),
            (
                "icon",
                NotchMenuMetrics.contentAreaWidth(
                    inPanelWidth: NotchMenuMetrics.panelWidthMax * PanelSize.compact.scale)
            ),
        ]
    }

    /// 被渲染的侧栏：真实产品视图 + 黑色底（面板就是黑底，人工核对时看得清层级）。
    @MainActor
    private func rail(contentWidth: CGFloat) -> some View {
        NotchMenuSidebar(selection: .agents, contentWidth: contentWidth) { _ in }
            .background(Color.black)
    }

    /// 侧栏的理想高：上下内边距 + 4 个配置页 + 收尾的「关于」+ 条目之间的间距。
    private func idealRailHeight(showsLabels: Bool) -> CGFloat {
        let item = NotchMenuMetrics.sidebarItemHeight(showsLabels: showsLabels)
        let rows = NotchMenuSection.sidebarSections.count
        // 子视图就是这 5 个条目 ⇒ 4 个间距（没有分隔线、也没有弹性 `Spacer`）。
        return CGFloat(rows) * item + CGFloat(rows - 1) * NotchMenuMetrics.sidebarItemSpacing
            + 2 * NotchMenuMetrics.sidebarVerticalPadding
    }

    /// 某一项（`index`）在渲染图里的 y 带（pt，原点在顶部）。
    private func rowBand(of index: Int, showsLabels: Bool) -> ClosedRange<CGFloat> {
        let item = NotchMenuMetrics.sidebarItemHeight(showsLabels: showsLabels)
        let top =
            NotchMenuMetrics.sidebarVerticalPadding
            + CGFloat(index) * (item + NotchMenuMetrics.sidebarItemSpacing)
        return top...(top + item)
    }

    /// 带标签档的探针行：第一项 `.general`（**未被选中**）。选中行铺着 `segmentedThumb`
    /// （0.16 叠白 → r+g+b ≈ 122，刚刚越过墨迹阈值 120），它会把整行的墨迹并成一个横跨
    /// 栏宽的簇，量不出「标签在不在」；未选中行没有底色（静态渲染也没有悬停态）。
    private func probeRowBand(showsLabels: Bool) -> ClosedRange<CGFloat> {
        rowBand(
            of: NotchMenuSection.sidebarSections.firstIndex(of: .general) ?? 0,
            showsLabels: showsLabels)
    }
}
