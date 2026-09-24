//
//  ShortcutRecorderRowRenderTests.swift
//  AgentIslandTests
//
//  快捷键行的渲染判据：已绑定时右端画出清空按钮，置空后那枚按钮消失。
//

import AppKit
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("快捷键行渲染")
struct ShortcutRecorderRowRenderTests {
    /// 行宽取设置页的内容宽（面板 480 − 左右内边距 16）。
    private let rowWidth: CGFloat = 464

    /// 渲染一次，返回右半行的墨迹列数（连通簇数量）：按键块与清空按钮是两个分离的簇。
    ///
    /// 不能用「最右一帯的墨迹像素数」区分：置空后行内只剩标签，而标签会铺满整行，
    /// 「未设置」文字同样会落进最右一帯（实测就是这样误判的）。改数**簇**：清空按钮是
    /// 独立的一簇，且与按键块之间隔着行内边距，簇间必有一个 ≥6px 的空列带。
    @MainActor
    private func rightHalfInkClusters(of view: some View) -> (clusters: Int, totalInk: Int) {
        let renderer = ImageRenderer(content: view.frame(width: rowWidth))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return (0, 0) }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func columnHasInk(_ x: Int) -> Bool {
            for y in 0..<height {
                let offset = (y * width + x) * 4
                if Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 120 {
                    return true
                }
            }
            return false
        }

        // 只数右半行：左半是图标块与标题，右半是按键块 +（可选）清空按钮。
        let start = width / 2
        var clusters = 0
        var gap = 0
        var totalInk = 0
        var inCluster = false
        for x in start..<width {
            if columnHasInk(x) {
                totalInk += 1
                if !inCluster {
                    clusters += 1
                    inCluster = true
                }
                gap = 0
            } else if inCluster {
                gap += 1
                if gap >= 6 {
                    inCluster = false
                }
            }
        }
        return (clusters, totalInk)
    }

    @MainActor
    @Test("清空按钮只在已绑定时画出：绑定态比置空态多一个独立墨迹簇")
    func clearButtonRendersOnlyWhenBound() {
        let defaults = UserDefaults(suiteName: "shortcut-row-render-\(UUID().uuidString)")!
        let bindings = ShortcutBindings(defaults: defaults)
        let action = ShortcutAction.dismiss
        let row = ShortcutRecorderRow(action: action, showsSeparator: false, bindings: bindings)

        bindings.set(action.defaultChord, for: action)
        let bound = rightHalfInkClusters(of: row)

        bindings.clear(action)
        let unbound = rightHalfInkClusters(of: row)

        // 两种状态都要真的画出东西：渲染失效时两边都是 0，下面的判据就没有意义了。
        #expect(bound.totalInk > 0, "已绑定的行右半渲染是空白")
        #expect(unbound.totalInk > 0, "置空后的行右半渲染是空白")

        #expect(
            bound.clusters == unbound.clusters + 1,
            "绑定态 \(bound.clusters) 簇 vs 置空态 \(unbound.clusters) 簇：清空按钮应当正好多出一簇")
    }
}
