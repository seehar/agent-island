//
//  MascotKit.swift
//  AgentIsland
//
//  角色共用的绘制工具：SVG 单位的坐标映射、绕轴心旋转的部件、睡眠时飘的 Z、取色。
//
//  坐标口径（这是整套角色看起来「像一套」的关键）：每一枚角色都在**同一套 SVG 单位**上作画
//  （`MascotSprite`），按 `min(宽比, 高比)` 等比缩放并居中。一套场景自带一个视口
//  （`svgWidth` / `svgHeight` / `svgTop`）：视口只决定这一套场景里角色的位置与大小，
//  同一个 `svgWidth = 16` 的视口在各枚角色之间是同一个口径——角色因此不会「有的胖有的瘦」。
//
//  角色自己的画法（有哪些部件、什么颜色、怎么动）写在各自文件里。
//
//  来源：本目录下的 15 枚角色移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/*View.swift`，坐标常量与配色逐值保留；`Text("z")` 的睡眠 Z 改为
//  这里用像素块画（本仓禁止 `Text("…")` 字面量，且像素块与角色同一套笔触）。
//

import SwiftUI

/// 角色的绘制坐标系：把一套 SVG 单位的「场景视口」映射到画布，按 `min(宽比, 高比)` 等比缩放并居中。
struct MascotSprite {
    /// 缩放后的视口左上角在画布上的位置。
    let origin: CGPoint
    /// 一个 SVG 单位在画布上的边长。
    let block: CGFloat
    /// 视口上边缘对应的 SVG 纵坐标：内容里比它小的 y 会被画到视口上边缘之外（被 `clipped()` 裁掉）。
    let svgTop: CGFloat

    init(_ canvas: CGSize, svgWidth: CGFloat = 15, svgHeight: CGFloat = 10, svgTop: CGFloat = 6) {
        block = min(canvas.width / svgWidth, canvas.height / svgHeight)
        origin = CGPoint(
            x: (canvas.width - svgWidth * block) / 2,
            y: (canvas.height - svgHeight * block) / 2)
        self.svgTop = svgTop
    }

    /// SVG 矩形 → 画布矩形。`dx` / `dy` 是**SVG 单位**的局部位移（角色的局部动作——起跳、
    /// 抬手、眨眼时的纵向压缩都靠它，而不是改坐标常量）。
    func r(
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
        dx: CGFloat = 0, dy: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: origin.x + (x + dx) * block,
            y: origin.y + (y - svgTop + dy) * block,
            width: width * block,
            height: height * block)
    }

    /// 网格点 → 画布点（旋转后的顶点、连线用）。
    func point(_ x: CGFloat, _ y: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        CGPoint(
            x: origin.x + (x + dx) * block,
            y: origin.y + (y - svgTop + dy) * block)
    }

    /// 绕轴心旋转的矩形（举钳、挥臂、张开翅膀这类：部件绕自己与身体的连接点转）。
    ///
    /// - Parameters:
    ///   - angle: 旋转角（度，正值顺时针）
    ///   - pivotX/pivotY: 轴心（SVG 单位，一般取部件与身体的连接点）
    ///   - dy: 部件相对身体的纵向位移（SVG 单位）
    func rotatedRect(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
        pivotX: CGFloat, pivotY: CGFloat, angle: CGFloat, dy: CGFloat = 0
    ) -> Path {
        let radians = angle * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        let corners: [(CGFloat, CGFloat)] = [
            (x, y), (x + width, y), (x + width, y + height), (x, y + height),
        ]
        var path = Path()
        for (index, corner) in corners.enumerated() {
            let offsetX = corner.0 - pivotX
            let offsetY = corner.1 - pivotY
            let rotatedX = offsetX * cosA - offsetY * sinA + pivotX
            let rotatedY = offsetX * sinA + offsetY * cosA + pivotY
            let target = point(rotatedX, rotatedY, dy: dy)
            if index == 0 {
                path.move(to: target)
            } else {
                path.addLine(to: target)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// 角色共用的绘制动作。
enum MascotDraw {
    /// 睡眠时往上飘的三个 Z：从 `bodyTop` 上方升起（**按身体顶边定位**，不是按画布中心——
    /// 按中心定位时，身体占中间那几枚（Cursor 的宝石、Qoder 的气泡、Codex 的云）的 Z 会
    /// 压在脸上/身上），错开周期与相位，越飘越淡（`t` 的纯函数，同一时刻画出同一帧）。
    ///
    /// - Parameters:
    ///   - sprite: 该场景的坐标系（用来把 `bodyTop` 换算成画布纵坐标）
    ///   - bodyTop: 身体**主体**（不含天线 / 叶子 / 触须这类细附件）顶边的 SVG 纵坐标
    ///   - size: 舞台边长：Z 的大小、横向偏移与上升行程都按它换算
    static func floatingZs(
        _ context: inout GraphicsContext, sprite: MascotSprite, bodyTop: CGFloat,
        t: CGFloat, size: CGFloat, color: Color = .white
    ) {
        // 基准点取两者中更高的那个：身体顶边上方一点，或画布中心之上（身体本来就低时——
        // 例如趴在地上的那几枚——就用后者，Z 才飘得开）。行程不超过「基准点到画布上缘」，
        // 所以 Z 永远不会飘出画布。
        let bodyTopY = sprite.r(0, bodyTop, 0, 0).minY
        // 预留的是**字形真实半高**：`zGlyph` 的块边长是 `edge = max(1, (height / 3).rounded())`
        // （`height` 最大 0.28×size），半高 1.5×edge 在小尺寸（14…26pt 的头部）里是 3pt，
        // 比按比例算的 0.14×size 还大——按比例算的话字形上缘会被画到画布外。
        let edge = max(1, (max(6, size * 0.28) / 3).rounded())
        let half = 1.5 * edge
        let base = max(half, min(size * 0.35, bodyTopY - size * 0.02))
        let travel = max(0, min(size * 0.38, base - half))
        for index in 0..<3 {
            let step = CGFloat(index)
            let cycle = 2.8 + step * 0.3
            let delay = step * 0.9
            let phase = max(0, (t - delay).truncatingRemainder(dividingBy: cycle) / cycle)
            let height = max(6, size * (0.18 + phase * 0.10))
            let baseOpacity = 0.7 - step * 0.1
            let opacity = phase < 0.8 ? baseOpacity : (1 - phase) * 3.5 * baseOpacity
            guard opacity > 0.01 else { continue }
            let center = CGPoint(
                x: size / 2 + size * (0.08 + step * 0.06 + sin(phase * .pi * 2) * 0.03),
                y: base - travel * phase)
            zGlyph(&context, center: center, height: height, color: color.opacity(opacity))
        }
    }

    /// 一枚像素 Z：三块宽的顶边、中间一块的对角、三块宽的底边。`center` 是它的中心。
    ///
    /// 落点按整点像素对齐（`rounded()`）：块是方的，落在半像素上会被抗锯齿糊掉，
    /// 看起来就不像像素画了。
    static func zGlyph(
        _ context: inout GraphicsContext, center: CGPoint, height: CGFloat, color: Color
    ) {
        let edge = max(1, (height / 3).rounded())
        let left = (center.x - edge * 1.5).rounded()
        let top = (center.y - edge * 1.5).rounded()
        for row in 0..<3 {
            let width: CGFloat = row == 1 ? 1 : 3
            let x = row == 1 ? left + edge : left
            context.fill(
                Path(CGRect(x: x, y: top + CGFloat(row) * edge, width: width * edge, height: edge)),
                with: .color(color))
        }
    }
}

extension Color {
    /// 十六进制取色（`0xRRGGBB`）。角色配色表的条目多，写十六进制比写三个浮点好核对。
    /// 这只是**作者入口**：Agent 的品牌色仍以 `AgentPalette` 为准，角色配色里至少要有一处
    /// 与 `AgentKind.brandColor` 同色系，刘海上的角色才认得出是哪个 Agent。
    init(mascotHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
