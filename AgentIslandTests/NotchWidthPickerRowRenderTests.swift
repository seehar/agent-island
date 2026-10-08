//
//  NotchWidthPickerRowRenderTests.swift
//  AgentIslandTests
//
//  胶囊宽度选择行的离屏渲染判据（渲染的是**真实产品视图**）：
//
//  1. 展开后的行高 == 行高 + `pickerOptionsHeight(visibleOptions:)`——预览行必须算进那笔账，
//     少算一行面板就会把最后一行裁掉。
//  2. 预览剪影**随数值变宽**：这是「实时」的可见证据——面板打开时关闭态胶囊被展开卡片
//     整块盖住，这一行是宽度唯一的反馈。用墨迹量：三级文字色的描边在深色卡片上就是墨迹。
//
//  两张 PNG 落到 /tmp/width-picker-probe 供人工核对（探针产物不入库）。它们用
//  `NSHostingViewProbe` 出图：断言用的 `ImageRenderer` **画不了 `TextField`**（会画成
//  琥珀色占位块），它的图里输入框那一格是空的——判据只看预览行的墨迹与整行高度，
//  因此不受影响，给人看的图则要真的把输入框画出来。
//
//  用例传**独立偏好域**里的选择器（行支持注入，见它的 `init`）：不碰用户的真实设置，
//  也不会与并行跑的其它用例抢共享实例的展开态。
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@MainActor
@Suite("胶囊宽度选择行渲染", .serialized)
struct NotchWidthPickerRowRenderTests {
    /// 渲染结果的落点：`/tmp`（探针产物不入库）。
    private let probeDirectory = URL(fileURLWithPath: "/tmp/width-picker-probe", isDirectory: true)

    /// 渲染宽度取设置详情列在标准档下的宽：真实排版里一行选项拿到的就是它减去选项缩进。
    private var renderWidth: CGFloat { NotchMenuMetrics.settingsDetailWidth }

    @Test("展开后按「行 + 3 行选项区」排版；预览剪影随数值变宽")
    func expandedHeightAndLivePreview() throws {
        try FileManager.default.createDirectory(
            at: probeDirectory, withIntermediateDirectories: true)

        let suiteName = "agent-island-width-row-render-\(UUID().uuidString)"
        let selector = NotchWidthSelector(defaults: try #require(UserDefaults(suiteName: suiteName)))
        selector.setWidth(200, on: nil)
        selector.isPickerExpanded = true

        let expectedHeight =
            NotchMenuMetrics.rowHeight
            + NotchMenuMetrics.pickerOptionsHeight(
                visibleOptions: NotchWidthSelector.visibleOptions)
        // 预览行的 y 带：行之后是选项区的上留白，再过 2 行选项（「自动」+ 微调行）就是它。
        let previewTop =
            NotchMenuMetrics.rowHeight + NotchMenuMetrics.optionListTopPadding
            + 2 * NotchMenuMetrics.optionRowHeight
        let previewBand = previewTop...(previewTop + ClosedCapsulePreview.rowHeight)

        var report: [String] = []
        var silhouetteWidths: [CGFloat] = []
        for (value, name) in [(CGFloat(200), "narrow"), (CGFloat(500), "wide")] {
            selector.setWidth(value, on: nil)

            let row = ZStack {
                Color.black
                NotchWidthPickerRow(selector: selector)
            }
            .frame(width: renderWidth)

            guard let image = ImageRendererProbe.raster(row) else {
                Issue.record("\(name) 没有出图")
                return
            }
            let size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            let clusters = inkClusters(of: image, in: previewBand)
            let silhouette =
                clusters.isEmpty
                ? 0
                : (clusters.map(\.upperBound).max()! - clusters.map(\.lowerBound).min()!)
            silhouetteWidths.append(silhouette)

            print(
                "[宽度行] \(name)（\(Int(value))pt）渲染 \(size)，期望高 \(expectedHeight)，"
                    + "预览行墨迹簇 \(clusters.map { "\($0.lowerBound)…\($0.upperBound)" })")

            #expect(
                abs(size.height - expectedHeight) <= 1,
                "\(name) 行高 \(size.height) ≠ 解析式 \(expectedHeight)（预览行没有算进选项区）")
            #expect(clusters.count == 1, "\(name) 预览行应只有一个剪影：\(clusters)")

            let file = probeDirectory.appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(at: file)
            if let appKitImage = NSHostingViewProbe.raster(row) {
                try ImageWriter.write(appKitImage, to: file)
            }
            #expect(FileManager.default.fileExists(atPath: file.path), "\(name).png 没写出来")
            report.append(
                "- \(name).png：\(Int(value))pt → 行高 \(size.height)pt，剪影宽 \(silhouette)pt")
        }

        // 「实时」的判据：数值从 200 加到 500，同一个预览盒里的剪影必须明显变宽。
        #expect(
            silhouetteWidths.count == 2 && silhouetteWidths[1] > silhouetteWidths[0] + 10,
            "预览没有跟着数值变宽：\(silhouetteWidths)")

        let reportURL = probeDirectory.appendingPathComponent("measurements.txt")
        try (report.joined(separator: "\n") + "\n").write(
            to: reportURL, atomically: true, encoding: .utf8)
        print("[宽度行] 量值 \(reportURL.path)")
    }
}
