//
//  AgentAnimationsRenderTests.swift
//  AgentIslandTests
//
//  「标记动态」页的版面判据：它是**固定高**的整块预览（状态行 + 画廊），渲染出的高度
//  必须与 `NotchMenuMetrics` 的解析式一致——否则面板高度与实际排版脱钩，画廊底部会被
//  面板下边缘裁掉，或者下方留出一块空白。
//

import AppKit
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("标记动态页渲染")
struct AgentAnimationsRenderTests {
    /// 面板内容宽（面板 480 − 左右内边距 16）。
    private let contentWidth: CGFloat = 464

    @MainActor
    @Test("渲染出的高度等于版面表给出的内容高，且真的画出了东西")
    func pageHeightMatchesMetrics() {
        let page = AgentAnimationsSettingsPage()
            .frame(width: contentWidth)
            .environment(\.locale, Locale(identifier: "en"))

        let renderer = ImageRenderer(content: page)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer 没有产出图像")
            return
        }

        // 页面 = 卡片（状态行 + 画廊）+ 脚注（含它上方的间距）。版面表把脚注记成
        // `footnoteHeight` 一行，这里按同一口径核对。
        let expected =
            NotchMenuMetrics.animationsSectionHeight + NotchMenuMetrics.footnoteHeight
        #expect(
            abs(CGFloat(image.height) - expected) <= 2,
            "渲染高 \(image.height) 与版面 \(expected) 不一致（画廊会被裁或留白）")

        // 画廊窗口 = `animationGalleryHeight`：页面高度减去两行预览控件与脚注后应当就是它。
        let gallery =
            CGFloat(image.height) - 2 * NotchMenuMetrics.rowHeight
            - NotchMenuMetrics.footnoteHeight
        #expect(
            abs(gallery - NotchMenuMetrics.animationGalleryHeight) <= 2,
            "画廊实际占高 \(gallery) 与预算 \(NotchMenuMetrics.animationGalleryHeight) 不一致")

        // 下半部分必须有墨迹（黑色舞台 + 标记画在里面），否则等于渲染成空白。
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            Issue.record("无法建立位图上下文")
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var ink = 0
        for y in (height / 2)..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset + 3] > 0 {
                    ink += 1
                }
            }
        }
        #expect(ink > 0, "画廊下半部分没有画出任何东西")
    }
}
