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
    /// 清空按钮占据行的最右 28pt：只量最右 8% 就能把它单拎出来
    /// （左侧的按键块在行的内边距之内，落在这一带之外）。
    private let clearZoneRatio = 0.92

    /// 渲染一次，返回最右一帯的墨迹像素数与全行墨迹像素数。
    @MainActor
    private func ink(of view: some View) -> (clearZone: Int, total: Int) {
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

        let clearZoneStart = Int(Double(width) * clearZoneRatio)
        var clearZone = 0
        var total = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let bright =
                    Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 120
                if bright {
                    total += 1
                    if x >= clearZoneStart { clearZone += 1 }
                }
            }
        }
        return (clearZone, total)
    }

    @MainActor
    @Test("清空按钮只在已绑定时画出；置空后那一带变空")
    func clearButtonRendersOnlyWhenBound() {
        let defaults = UserDefaults(suiteName: "shortcut-row-render-\(UUID().uuidString)")!
        let bindings = ShortcutBindings(defaults: defaults)
        let action = ShortcutAction.dismiss
        let row = ShortcutRecorderRow(action: action, showsSeparator: false, bindings: bindings)

        bindings.set(action.defaultChord, for: action)
        let bound = ink(of: row)

        bindings.clear(action)
        let unbound = ink(of: row)

        // 两种状态都要真的画出东西：渲染失效时两边都是 0，下面的判据就没有意义了。
        #expect(bound.total > 0, "已绑定的行渲染是空白")
        #expect(unbound.total > 0, "置空后的行渲染是空白")

        #expect(bound.clearZone > 20, "已绑定的行右端没有清空按钮（只量到 \(bound.clearZone) 像素）")
        #expect(unbound.clearZone == 0, "置空后右端仍有 \(unbound.clearZone) 像素的控件")
    }
}
