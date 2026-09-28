//
//  GrokMascot.swift
//  AgentIsland
//
//  Grok（xAI）的像素角色就是**那枚商标本体**：2025 年 2 月的黑白几何标记（两道斜划围出来的
//  断环）。上游对它的口径是「商标几何逐值保留、不施加变换」，这里照办——整帧**只做平移**，
//  不旋转、不缩放、不斜切，标记永远是白色；三档靠「位置 + 装饰物」区分：
//    · 空闲：标记放低（底边落在接地线 y = 15 上），随呼吸抬起 ≤ 0.6 个单位，
//      底下一条很淡的影子，头顶飘三个 Z——位低 + 睡着飘 Z 就是「打盹」这一档；
//    · 处理中：标记悬空，按打字般上下平移（总幅度 ≤ 0.8 个单位，任何时刻都在动），
//      正下方三个**装填点**依次亮灭（槽位走 `MascotMotion.beat`，确定性），像在跑任务；
//    · 待审批：三连跳（一跳比一跳矮，位移按视口截顶）+ 头顶惊叹号 + 由 `t` 决定的警报光晕，
//      影子留在地上、跳得越高越窄越淡。
//
//  场景视口（SVG 单位）：打盹 15×12（上边缘 y=4）、处理中与待审批 16×14（上边缘 y=3）；
//  接地线在 y = 15，与其余角色同一行。
//
//  标记几何来自上游 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/GrokView.swift`（源 SVG 为 Grok-feb-2025-logo.svg）：两条 `#mark`
//  路径与 viewBox 逐值保留。**三套场景与动效是本仓补的**（上游只有一枚静态标记）；
//  标记填白沿用上游，警报色沿用本仓各角色共用的琥珀色（上游这套标记没有警报配色）。
//

import SwiftUI

struct GrokMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 标记填白（上游取值）；琥珀是警报色，灰白两点是干活时脚下的装填点。
    private static let mark = Color.white
    private static let alert = Color(mascotHex: 0xFF3D00)
    private static let dot = Color(mascotHex: 0x617080)
    private static let dotLit = Color.white

    /// 标记的边长（SVG 单位）：上游是画布的 0.68，与其它角色本体（10~11 个单位）同一量级。
    private static let markScale: CGFloat = 0.68
    /// 源 viewBox 的高宽比（33.6964 × 32）。给 `GrokMark` 的矩形按它算，墨迹才正好填满外框。
    private static let markAspect: CGFloat = 32.0 / 33.6964
    /// 趴姿（空闲档）：标记的边长与**身体顶边**的 SVG 纵坐标——底边落在接地线 y = 15 上。
    /// 趴姿的标记与飘 Z 都取这两个数，位置只有一个来源。
    private static let sleepSide: CGFloat = 15 * markScale
    private static let sleepBodyTop: CGFloat = 15 - sleepSide * markAspect

    /// 起跳截顶的入参：静息顶边就是标记落在接地线上时的顶边（`15 - 16 × markScale × markAspect`）。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 15 - 16 * markScale * markAspect, svgTop: 3)

    var body: some View {
        ZStack {
            switch status {
            case .idle:
                sleepScene
            case .working:
                workScene
            case .alert:
                alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    // MARK: - 空闲：放低了打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite)
            // 飘 Z 从标记顶边（趴姿身体主体的顶边）上方升起。
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: Self.sleepBodyTop, t: t, size: size)
        }
    }

    /// 打盹：标记贴地放着（底边在接地线上），呼吸只把它**抬起**一点——标记不能变形，
    /// 所以这一档的「睡着了」全靠位低 + 头顶飘的 Z。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let breathe = MascotMotion.breathe(t, period: 4.5)
        let lift = -0.6 * breathe

        let shadowWidth: CGFloat = 9.5 + breathe * 0.4
        context.fill(
            Path(sprite.r(7.5 - shadowWidth / 2, 15, shadowWidth, 1)),
            with: .color(.black.opacity(0.18 + breathe * 0.06)))

        drawMark(
            &context, sprite, centerX: 7.5, top: Self.sleepBodyTop + lift, side: Self.sleepSide)
    }

    // MARK: - 处理中：悬空干活 + 装填点

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 干活：标记悬空上下平移——底子是一条正弦（因此任何时刻都在动），再叠按敲击拍子的
    /// 下压；脚下三个装填点依次亮起，读起来像任务队列在推进。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let side = 16 * Self.markScale

        let tap = MascotMotion.typingBeat(t, cadence: 0.11, seed: 0x6B01)
        let bob = 0.3 * sin(t * 2 * .pi / 1.1) + (tap.active ? 0.1 : 0)

        context.fill(
            Path(sprite.r(8 - 9 / 2, 15, 9, 1)), with: .color(.black.opacity(0.22)))

        // 装填点：三个点依次亮灭（槽位走 beat，确定性），亮着的那个带一点呼吸。
        let slot = MascotMotion.beat(t, beat: 0.22)
        let glow = 0.55 + 0.45 * MascotMotion.pulse(t, period: 0.66)
        for index in 0..<3 {
            let lit = index == slot % 3
            context.fill(
                Path(sprite.r(5.9 + CGFloat(index) * 1.5, 14.15, 1.2, 0.7)),
                with: .color(lit ? Self.dotLit.opacity(glow) : Self.dot))
        }

        // 悬空的标记：静息时顶边在 y = 3.25，往下弹最多 0.4 个单位（不会顶出视口上边缘）。
        drawMark(&context, sprite, centerX: 8, top: 3.25 + bob, side: side)
    }

    // MARK: - 待审批：三连跳 + 惊叹号 + 警报光晕

    private var alertScene: some View {
        ZStack {
            // 警报光晕：常亮一点余晖、随安静段慢慢呼吸。用径向渐变而不是 `blur`
            // （20fps 下模糊的离屏渲染太贵），强度是 `t` 的纯函数。
            RadialGradient(
                colors: [
                    Self.alert.opacity(0.05 + 0.07 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.0))),
                    Self.alert.opacity(0),
                ],
                center: .center,
                startRadius: 0,
                endRadius: size * 0.45
            )
            .frame(width: size * 0.9, height: size * 0.9)

            Canvas { context, canvas in
                drawAlert(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
            }
        }
        .frame(width: size, height: size)
    }

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮（与其余角色同一套节奏），然后安静到下一轮。
    /// 标记只跟着位移走（影子留在地上），惊叹号挂在头顶右上方。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        // 三连跳的位移表（-8 / -6 / -4 / -2 是三次起跳的顶点）。
        let jumpY = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: -1),
                (at: 0.15, value: 1.5),
                (at: 0.175, value: -8), (at: 0.20, value: -8), (at: 0.25, value: 1.5),
                (at: 0.275, value: -6), (at: 0.30, value: -6), (at: 0.35, value: 1.0),
                (at: 0.375, value: -4), (at: 0.40, value: -4), (at: 0.45, value: 0.8),
                (at: 0.475, value: -2), (at: 0.50, value: -2), (at: 0.55, value: 0.3),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)

        let side = 16 * Self.markScale
        // 静息时标记落在接地线上（底边 y = 15）。最大跳幅 8 个单位，截顶到标记顶边
        // 不越出视口上边缘——否则顶点那一帧整枚标记都会飞出画布（入参见 `alertSpec`）。
        let restTop = Self.alertSpec.bodyTop
        let rise = jumpY * Self.alertSpec.riseFactor

        // 影子：跳得越高越窄越淡，但**留在原地**
        let shadowWidth: CGFloat = 9 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(8 - shadowWidth / 2, 15, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.45 - abs(min(0, rise)) * 0.04))))

        // 标记（只平移）
        drawMark(&context, sprite, centerX: 8, top: restTop + rise, side: side)

        // 惊叹号：起跳一开始亮起，安静下来淡出；纵向位移只有跳跃的 15%（不会飞出画布），
        // 横向落在标记右缘之外（标记最宽处到 x = 13.44），因此不会压在标记上。
        let bangOpacity = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 1), (at: 0.10, value: 1), (at: 0.55, value: 1),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)
        let bangScale = MascotMotion.lerp(
            [
                (at: 0, value: 0.3), (at: 0.03, value: 1.3), (at: 0.10, value: 1.0),
                (at: 0.55, value: 1.0), (at: 0.62, value: 0.6), (at: 1.0, value: 0.6),
            ], at: pct)
        if bangOpacity > 0.01 {
            let width: CGFloat = 2 * bangScale
            let x: CGFloat = 13.4
            let y: CGFloat = 4.4 + rise * 0.15
            context.fill(
                Path(sprite.r(x, y, width, 3.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(x, y + 4.0 * bangScale, width, 1.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
        }
    }

    // MARK: - 共用的部件

    /// 把标记画进画布：`centerX` 是水平中心、`top` 是**墨迹外框**的上边缘（都是 SVG 单位）。
    /// 矩形的高宽比由 `markAspect` 固定，因此任何一帧都不改宽高比、不旋转、不斜切。
    private func drawMark(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, centerX: CGFloat, top: CGFloat,
        side: CGFloat
    ) {
        let rect = sprite.r(centerX - side / 2, top, side, side * Self.markAspect)
        context.fill(GrokMark().path(in: rect), with: .color(Self.mark))
    }
}

/// Grok 2025 年 2 月的黑白几何标记（源 SVG 为 Grok-feb-2025-logo.svg）。上游 SVG 的
/// 两条 `#mark` 路径与源 viewBox（x: 0...33.6964，y: 0.5...32.5）**逐值保留**：
/// `path(in:)` 按这个 viewBox 把标记等比归一到传入的矩形并在其中居中（与上游同写法）。
private struct GrokMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceWidth: CGFloat = 33.6964
        let sourceHeight: CGFloat = 32.0
        let sourceMinY: CGFloat = 0.5
        let scale = min(rect.width / sourceWidth, rect.height / sourceHeight)
        let offsetX = rect.midX - sourceWidth * scale / 2
        let offsetY = rect.midY - sourceHeight * scale / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: offsetX + x * scale,
                y: offsetY + (y - sourceMinY) * scale
            )
        }

        var path = Path()

        path.move(to: point(13.2371, 21.0407))
        path.addLine(to: point(24.3186, 12.8506))
        path.addCurve(
            to: point(25.8973, 13.2294),
            control1: point(24.8619, 12.4491),
            control2: point(25.6384, 12.6057)
        )
        path.addCurve(
            to: point(23.9403, 23.1851),
            control1: point(27.2597, 16.5185),
            control2: point(26.651, 20.4712)
        )
        path.addCurve(
            to: point(14.0108, 25.1386),
            control1: point(21.2297, 25.8989),
            control2: point(17.4581, 26.4941)
        )
        path.addLine(to: point(10.2449, 26.8843))
        path.addCurve(
            to: point(26.304, 25.5601),
            control1: point(15.6463, 30.5806),
            control2: point(22.2053, 29.6665)
        )
        path.addCurve(
            to: point(29.6205, 13.8673),
            control1: point(29.5551, 22.3051),
            control2: point(30.562, 17.8683)
        )
        path.addLine(to: point(29.629, 13.8758))
        path.addCurve(
            to: point(33.449, 0.844576),
            control1: point(28.2637, 7.99809),
            control2: point(29.9647, 5.64871)
        )
        path.addCurve(
            to: point(33.6964, 0.5),
            control1: point(33.5314, 0.730667),
            control2: point(33.6139, 0.616757)
        )
        path.addLine(to: point(29.1113, 5.09055))
        path.addLine(to: point(29.1113, 5.07631))
        path.addLine(to: point(13.2343, 21.0436))
        path.closeSubpath()

        path.move(to: point(10.9503, 23.0313))
        path.addCurve(
            to: point(11.0498, 10.2763),
            control1: point(7.07343, 19.3235),
            control2: point(7.74185, 13.5853)
        )
        path.addCurve(
            to: point(21.0021, 8.2971),
            control1: point(13.4959, 7.82722),
            control2: point(17.5036, 6.82767)
        )
        path.addLine(to: point(24.7595, 6.55998))
        path.addCurve(
            to: point(22.2195, 5.17313),
            control1: point(24.0826, 6.07017),
            control2: point(23.215, 5.54334)
        )
        path.addCurve(
            to: point(8.67479, 7.90126),
            control1: point(17.7198, 3.31926),
            control2: point(12.3326, 4.24192)
        )
        path.addCurve(
            to: point(5.94992, 21.4622),
            control1: point(5.15635, 11.4239),
            control2: point(4.0499, 16.8403)
        )
        path.addCurve(
            to: point(2.69884, 29.826),
            control1: point(7.36924, 24.9165),
            control2: point(5.04257, 27.3598)
        )
        path.addCurve(
            to: point(0.36364, 32.5),
            control1: point(1.86829, 30.7002),
            control2: point(1.0349, 31.5745)
        )
        path.addLine(to: point(10.9474, 23.0341))
        path.closeSubpath()

        return path
    }
}