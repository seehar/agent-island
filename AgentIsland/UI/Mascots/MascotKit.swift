//
//  MascotKit.swift
//  AgentIsland
//
//  角色共用的绘制工具：SVG 单位的坐标映射、绕轴心旋转的部件、睡眠时飘的 Z、取色。
//
//  坐标口径（这是整套角色看起来「像一套」的关键）：每一枚角色都在**同一套 SVG 单位**上作画
//  （`MascotSprite`），按全应用共用的**参照跨度**（`MascotSprite.referenceSpan`）缩放。
//  一套场景自带一个视口（`svgWidth` / `svgHeight` / `svgTop`）：视口只决定这一套场景里
//  角色的位置与大小，同一个视口在各枚角色之间是同一个口径——角色因此不会「有的胖有的瘦」。
//
//  三套场景之间的**大小与基线**也必须一致：单位边长不按各场景自己的视口算（那样同一只角色
//  在打盹 / 干活 / 起跳之间会换三个大小，26pt 舞台上从 1.53pt 变到 1.73pt，看起来像换了
//  一只角色），纵向位置则按同一个参照方框换算——脚踩在同一条基线上，切状态时不会突然
//  变大或上浮。视口本身（坐标常量）仍是各场景自己的，不参与这件事。
//
//  画布坐标一律吸附到**整设备像素**（`MascotPixelGrid`）：块边长按参照跨度算出来多半是小数，
//  不吸附的话每个像素块都落在半像素上、整只角色都是抗锯齿的糊边，不像像素画。
//
//  角色自己的画法（有哪些部件、什么颜色、怎么动）写在各自文件里。
//
//  来源：本目录下的 15 枚角色移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/*View.swift`，坐标常量与配色逐值保留；`Text("z")` 的睡眠 Z 改为
//  这里用像素块画（本仓禁止 `Text("…")` 字面量，且像素块与角色同一套笔触）。
//

import AppKit
import SwiftUI

/// 像素块吸附到的**设备像素网格**。
///
/// 为什么是一个进程内的值：`MascotSprite` 由各角色的绘制代码在 `Canvas` 的闭包里直接构造
/// （调用点不在本层），而「一个点等于多少设备像素」只存在于渲染环境里。视图层
/// （`AgentMascot`）在求值时把环境的 `displayScale` 写进来，绘制时读——于是同一份坐标常量
/// 在 1× 与 2× 屏上都落在整设备像素上。
///
/// 默认 2：本机（arm64 MacBook）与离屏渲染（`ImageRenderer`、探针、单测）都没有窗口环境值
/// 时的取值。猜错的后果只是「少吸附半像素」，不会画错内容。
enum MascotPixelGrid {
    /// 设备像素 / 点（2× 屏是 1 点 = 2 设备像素）。
    static var scale: CGFloat = 2

    /// 一个设备像素在点坐标里的边长。
    static var pixel: CGFloat { 1 / scale }

    /// 把点坐标吸到**最近**的整设备像素上。
    static func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
}

/// 角色的绘制坐标系：把一套 SVG 单位的「场景视口」映射到画布。
struct MascotSprite {
    /// 缩放后的视口左上角在画布上的位置。
    let origin: CGPoint
    /// 一个 SVG 单位在画布上的边长（三套场景取同一个值，见 `referenceSpan`）。
    let block: CGFloat
    /// 视口上边缘对应的 SVG 纵坐标：内容里比它小的 y 会被画到视口上边缘之外（被 `clipped()` 裁掉）。
    let svgTop: CGFloat

    /// 全应用共用的参照跨度（SVG 单位）：同一只角色在各套场景里取同一个单位边长。
    ///
    /// 各场景的视口是**各自**的（趴姿 17×7、打字 16×11、起跳 15×12……），按视口自己的
    /// `min(宽比, 高比)` 适配就会拿到三个不同的单位边长——同一只角色在打盹、干活、待审批
    /// 之间仿佛换了大小。取各场景视口跨度的上界（现有最宽的一档 17）当参照，单位边长在三套
    /// 场景里就始终一致。将来某套场景的视口比参照还大时退回按它自己适配（见 `init`）：
    /// 宁可这只角色大一点，也不要被 `clipped()` 裁掉外面的部件。
    static let referenceSpan: CGFloat = 17

    /// 参照方框下边缘的 SVG 纵坐标：各场景的视口下沿（`svgTop + svgHeight`）都落在它之上
    /// （现有取值是 16…18），角色因此落在同一张 SVG→画布映射上——脚踩在同一条基线上。
    static let referenceBottom: CGFloat = 18

    init(_ canvas: CGSize, svgWidth: CGFloat = 15, svgHeight: CGFloat = 10, svgTop: CGFloat = 6) {
        block = min(canvas.width, canvas.height) / max(Self.referenceSpan, svgWidth, svgHeight)
        // 横向：视口自己居中（角色的左右重心不随场景改变）。
        // 纵向：把参照方框（边长 `referenceSpan`、下边缘 `referenceBottom`）放在画布正中，
        // 各场景的视口按自己的 `svgTop` 落进这张映射——于是「同一个 SVG 纵坐标」在每套场景里
        // 都落在画布的同一个点上。
        let referenceTop = Self.referenceBottom - Self.referenceSpan
        origin = CGPoint(
            x: (canvas.width - svgWidth * block) / 2,
            y: (canvas.height - Self.referenceSpan * block) / 2 + (svgTop - referenceTop) * block)
        self.svgTop = svgTop
    }

    /// SVG 矩形 → 画布矩形。`dx` / `dy` 是**SVG 单位**的局部位移（角色的局部动作——起跳、
    /// 抬手、眨眼时的纵向压缩都靠它，而不是改坐标常量）。
    ///
    /// 四条边都吸到整设备像素：只吸边、**不吸块边长本身**。把块边长取整是不行的——22pt 的
    /// 入口缩略图上它落在 2 与 3 设备像素之间，取 2 得缩水 23%、取 3 得溢出 16%（边角被
    /// `clipped()` 裁掉）；吸边则整只角色的尺寸不变，块宽在相邻整像素之间取值（26pt 舞台上
    /// 约 16 块里才有一块宽 1 设备像素），肉眼是均匀的。
    func r(
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
        dx: CGFloat = 0, dy: CGFloat = 0
    ) -> CGRect {
        let leading = MascotPixelGrid.snap(origin.x + (x + dx) * block)
        let top = MascotPixelGrid.snap(origin.y + (y - svgTop + dy) * block)
        // 至少一个设备像素：细部件（0.7 单位的键帽那种）在极小舞台上会被吸成 0 宽而整个消失。
        let trailing = max(
            MascotPixelGrid.snap(origin.x + (x + dx + width) * block),
            leading + MascotPixelGrid.pixel)
        let bottom = max(
            MascotPixelGrid.snap(origin.y + (y - svgTop + dy + height) * block),
            top + MascotPixelGrid.pixel)
        return CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
    }

    /// 网格点 → 画布点（旋转后的顶点、连线用）。**不吸附**：绕轴心旋转的部件本来就不是
    /// 轴对齐的像素块（举钳、挥臂那几处），把顶点吸到网格上只会把形状压变形。
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
    /// 睡眠时飘的三个 Z：排成一条**向右上的斜梯**（经典「💤」的排布），三枚的相位各错开
    /// 三分之一、每枚只在自己的窗口里淡入淡出——任一时刻最多两枚亮着，所以不会糊成一坨
    /// （旧版是三枚挤在同一条中轴线上一起淡出，在 26pt 的头部与 44pt 的「标记动态」画廊里
    /// 都是一块白斑）。
    ///
    /// 字形大小先按画布定（`size` 的约 5.5%，即画布高的一成六），再按**身体顶边之上真正
    /// 可用的高度**收窄：趴姿的视口是扁的（15×12），头顶往往只剩画布的两成高，按画布尺寸
    /// 单独算的字形会被 `.clipped()` 削掉上缘。斜梯放不下时**压平**（`rise` 归零、变成横向
    /// 一排）而不是缩小字形；连一枚都放不下的极小舞台（14pt 的头部）干脆不画。
    ///
    /// - Parameters:
    ///   - sprite: 该场景的坐标系（用来把 `bodyTop` 换算成画布纵坐标）
    ///   - bodyTop: 身体**主体**（不含天线 / 叶子 / 触须这类细附件）顶边的 SVG 纵坐标
    ///   - size: 舞台边长：字形大小、斜梯步距与上浮行程都按它换算
    ///   - color: 该角色的**主题色**（路由传的是 `AgentKind.brandColor`）。Z 是黑舞台上的小字形，
    ///     偏暗的品牌色（cursor / opencode / kimi 这类）会糊进背景，所以这里一律先提亮一档
    ///     （`ZLadder.sleepZLift`）再画——角色、刘海上的计数徽标与睡眠 Z 因此仍是同一个主题色。
    static func floatingZs(
        _ context: inout GraphicsContext, sprite: MascotSprite, bodyTop: CGFloat,
        t: CGFloat, size: CGFloat, color: Color = .white
    ) {
        guard let ladder = zLadder(bodyTopY: sprite.r(0, bodyTop, 0, 0).minY, size: size) else {
            return
        }
        let zColor = color.liftedTowardWhite(ZLadder.sleepZLift)
        for slot in ladder.visibleSlots(t: t) {
            let envelope = ladder.envelope(slot: slot, t: t)
            zGlyph(
                &context, center: ladder.center(slot: slot, float: envelope),
                edge: ladder.ghosts[slot].edge,
                color: zColor.opacity(ZLadder.peakOpacity * envelope))
        }
    }

    /// 算一条睡眠 Z 斜梯；身体顶边之上连一枚 Z 都放不下时返回 `nil`（`floatingZs` 就不画）。
    static func zLadder(bodyTopY: CGFloat, size: CGFloat) -> ZLadder? {
        // 单块边长：先按画布定，再让「三块高的字形 + 一点空隙」在身体顶边之上放得下。
        let ideal = max(1, (size * 0.055).rounded())
        let edge = min(ideal, max(1, (bodyTopY / 3.2).rounded(.down)))
        let glyph = edge * 3
        let floatRise = edge * 0.4
        // 每往右一枚抬多少：把算出来的余量对半分给两段抬升；余量为负就压平（rise = 0）。
        let rise = min(edge * 0.6, max(0, (bodyTopY - glyph - 2 * floatRise) / 2))
        // 最低那枚贴着身体顶边（留一点缝），整条斜梯若会顶出画布上缘就整体下移。`zGlyph` 会把
        // 落点吸到整设备像素（最多往上蹭半个设备像素），所以留 0.5pt 的余量。
        let lowest = bodyTopY - glyph / 2 - edge * 0.3
        let shift = max(0, 0.5 - (lowest - 2 * rise - glyph / 2 - floatRise))
        // 要下移超过一个块边长，说明头顶本来就没有位置：这一档不画 Z（姿态本身就说明了在睡）。
        guard shift <= edge else { return nil }
        let stepX = glyph + edge
        let ghosts: [(center: CGPoint, edge: CGFloat)] = (0..<3).map { slot in
            (
                center: CGPoint(
                    x: size / 2 + (CGFloat(slot) - 1) * stepX,
                    y: lowest + shift - CGFloat(slot) * rise),
                edge: edge
            )
        }
        return ZLadder(ghosts: ghosts, floatRise: floatRise)
    }

    /// 一条睡眠 Z 斜梯的布局与相位。抽成类型是为了让单测直接断言「三枚不重叠、都没出画布、
    /// 任一时刻不会三枚全亮」——这几条在渲染出的像素里很难取证（Z 可能压在同色身体上，
    /// 按颜色阈值找脚印会漏）。
    struct ZLadder {
        /// 三枚 Z 的落点（画布坐标，`slot` 越大越靠右上）与块边长。
        let ghosts: [(center: CGPoint, edge: CGFloat)]
        /// 淡出时的上浮行程（画布点）。
        let floatRise: CGFloat

        /// 三枚共用的周期（秒）。
        static let cycle: CGFloat = 3.6
        /// 一枚 Z 的可见窗口占周期的比例：一半。三枚错开三分之一，因此最多两枚同时在亮。
        static let visibleFraction: CGFloat = 0.5
        /// 淡入淡出的峰值不透明度。彩色的主题色比白色暗一截，峰值取 0.8 才看得出是哪一支
        /// （白色 Z 时代是 0.55；降回 0.55 时提亮档只剩三成亮度，读不出颜色）。
        static let peakOpacity: CGFloat = 0.80
        /// 往白里提亮的比例：传进来的主题色按它混入白色（0 = 原色，1 = 纯白）。偏暗的品牌色
        /// （cursor 的灰、kimi 的蓝）画在近黑舞台上会糊掉；提亮后既读得出「这是谁的主题色」，
        /// 又不会淡成一块白——比例再大（如 0.42）色相会被白吃掉，读起来像浅灰而不是品牌色。
        static let sleepZLift: Double = 0.30

        /// 一枚 Z 在某时刻的包络（0 = 不可见，1 = 最亮）。
        func envelope(slot: Int, t: CGFloat) -> CGFloat {
            var phase = t / Self.cycle - CGFloat(slot) / CGFloat(ghosts.count)
            phase -= phase.rounded(.down)
            guard phase < Self.visibleFraction else { return 0 }
            return sin(phase / Self.visibleFraction * .pi)
        }

        /// 某时刻该画的槽位。
        func visibleSlots(t: CGFloat) -> [Int] {
            ghosts.indices.filter { envelope(slot: $0, t: t) > 0.01 }
        }

        /// 一枚 Z 的落点；`float` 是 0…1 的上浮量（把 `envelope` 直接传进来即可）。
        func center(slot: Int, float: CGFloat) -> CGPoint {
            let point = ghosts[slot].center
            return CGPoint(x: point.x, y: point.y - floatRise * min(max(float, 0), 1))
        }

        /// 一枚 Z 的外接矩形（`float` 同上）。
        func rect(slot: Int, float: CGFloat) -> CGRect {
            MascotDraw.zGlyphRect(center: center(slot: slot, float: float), edge: ghosts[slot].edge)
        }
    }

    /// 一枚像素 Z 的外接矩形：`zGlyph` 与上面的布局单测共用，两者因此不会各算一套。
    ///
    /// 落点与角色部件同一套吸附（`MascotPixelGrid.snap`）：块是方的，落在半像素上会被抗锯齿
    /// 糊掉，看起来就不像像素画了。`edge` 本身是整数点（见 `zLadder`），所以三块字形内部
    /// 仍落在网格上。
    static func zGlyphRect(center: CGPoint, edge: CGFloat) -> CGRect {
        CGRect(
            x: MascotPixelGrid.snap(center.x - edge * 1.5),
            y: MascotPixelGrid.snap(center.y - edge * 1.5),
            width: edge * 3,
            height: edge * 3)
    }

    /// 一枚像素 Z：三块宽的顶边、中间一块的对角、三块宽的底边。`center` 是它的中心。
    ///
    /// 落点按整设备像素对齐（`MascotPixelGrid.snap`，见 `zGlyphRect`）：块是方的，落在半像素上
    /// 会被抗锯齿糊掉，看起来就不像像素画了。
    static func zGlyph(
        _ context: inout GraphicsContext, center: CGPoint, edge: CGFloat, color: Color
    ) {
        let block = max(1, edge)
        let rect = zGlyphRect(center: center, edge: block)
        for row in 0..<3 {
            let width: CGFloat = row == 1 ? 1 : 3
            let x = row == 1 ? rect.minX + block : rect.minX
            context.fill(
                Path(
                    CGRect(
                        x: x, y: rect.minY + CGFloat(row) * block,
                        width: width * block, height: block)),
                with: .color(color))
        }
    }
}

extension Color {
    /// 往白里提一档（**保持色相**）：深色舞台上画小元素时用。`amount` 是混入白色的比例
    /// （0 = 原色，1 = 纯白）。
    func liftedTowardWhite(_ amount: Double) -> Color {
        let mix = min(max(amount, 0), 1)
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        func lifted(_ component: CGFloat) -> Double {
            Double(component) + (1 - Double(component)) * mix
        }
        return Color(
            red: lifted(srgb.redComponent),
            green: lifted(srgb.greenComponent),
            blue: lifted(srgb.blueComponent),
            opacity: Double(srgb.alphaComponent))
    }

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
