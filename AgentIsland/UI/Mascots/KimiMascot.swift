//
//  KimiMascot.swift
//  AgentIsland
//
//  Kimi 的像素角色（上游名 KimiBot）：一颗圆角小方块（Kimi 蓝，自上而下由亮到暗的竖向
//  渐变），头顶一根小天线，脸上两颗白色方点眼睛。
//    · 空闲：方块轻轻浮着打盹（两个不可通约的周期叠加，浮沉几乎不会正好重复），天线与
//      方块一起浮、腿留在地上，眼睛眯到一半、每 4 秒眨一下，头顶飘三个 Z；
//    · 处理中：坐在键盘前敲字——方块随按键起伏，眼睛按快门眨，按下的键帽亮一下，
//      每约 10.8 秒停一拍（像在等输出）；
//    · 待审批：三连跳（一跳比一跳矮）+ 方块脉冲式鼓缩 + 眼睛瞪大 + 头顶惊叹号 + 警报光晕。
//
//  场景视口（SVG 单位）：趴姿 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）。
//
//  来源：移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/KimiView.swift`，坐标常量与配色逐值保留。
//

import SwiftUI

struct KimiMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（机身蓝）。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = body

    /// Kimi 品牌蓝：方块自上而下由亮到暗渐变（明亮档 / 主蓝 / 压暗档），眼睛取纯白，
    /// 警报橙用来喊人；键盘是深蓝灰的键座与键帽、按下去的那一格取纯白。
    private static let body = Color(mascotHex: 0x4A90FF)
    private static let bodyDk = Color(red: 0.20, green: 0.42, blue: 0.90)
    private static let bodyLt = Color(red: 0.42, green: 0.68, blue: 1.0)
    private static let eye = Color.white
    private static let alert = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.18, green: 0.24, blue: 0.34)
    private static let kbKey = Color(red: 0.38, green: 0.50, blue: 0.64)
    private static let kbFlash = Color.white

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 5.5, svgTop: 3)

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

    // MARK: - 空闲：浮着打盹

    /// 趴姿方块的几何：块体顶边（= 9 − 7 × 0.9 ÷ 2；Z 从这里往上飘）。天线是细附件，不作为锚点。
    private static let sleepBodyTop: CGFloat = 5.85

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite)
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: Self.sleepBodyTop, t: t, size: size, color: Self.sleepZ)
        }
    }

    /// 浮沉：两条不可通约的周期叠加，浮沉几乎不会正好重复；天线与方块跟着浮、腿留在地上
    /// （只给 30% 的位移，像被拖着）。方块缩到 0.9 倍、眼睛眯成一条缝，每 4 秒眨一下。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let float = sin(t * 2 * .pi / 3.78) * 0.68 + sin(t * 2 * .pi / 6.23) * 0.36
        let blinkPhase = t.truncatingRemainder(dividingBy: 4.0)
        let lid: CGFloat = (blinkPhase > 3.5 && blinkPhase < 3.7) ? 0.15 : 0.5

        drawShadow(&context, sprite, width: 6 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(&context, sprite, dy: float)
        drawBody(&context, sprite, dy: float, scale: 0.9)
        drawFace(&context, sprite, dy: float, blinkPhase: lid)
    }

    // MARK: - 处理中：坐在键盘前敲字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 敲字：方块随按键起伏，每约 10.8 秒停一拍（像在等输出，不是一路敲个不停）；
    /// 眼睛自然眨眼，键帽按拍号亮一格（确定性，不随机）。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pause = MascotMotion.quirk(t, cycle: 10.8, duration: 1.2, seed: 0x35E)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - pause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * pause
        let blinkPhase = max(0.1, MascotMotion.blink(t, seed: 0x35F))
        let keyPhase = Int(t / 0.1) % 6

        // 1. 影子（起伏越大越窄越淡）
        let shadowWidth: CGFloat = 7 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (7 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        // 2. 腿（在键盘后面）
        drawLegs(&context, sprite, dy: bounce)

        // 3. 键盘 + 6 列 × 2 行的键帽
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            for column in 0..<6 {
                context.fill(
                    Path(
                        sprite.r(
                            0.5 + CGFloat(column) * 2.4, 13.5 + CGFloat(row) * 1.2, 1.8, 0.7)),
                    with: .color(Self.kbKey))
            }
        }
        // 按下的那一格亮一下（拍号同时决定行列）
        context.fill(
            Path(
                sprite.r(
                    0.5 + CGFloat(keyPhase % 6) * 2.4, 13.5 + CGFloat(keyPhase / 3) * 1.2, 1.8,
                    0.7)),
            with: .color(Self.kbFlash.opacity(0.9)))

        // 4. 方块 + 眼睛（一起随按键起伏）
        drawBody(&context, sprite, dy: bounce, scale: 1.0)
        drawFace(&context, sprite, dy: bounce, blinkPhase: blinkPhase)
    }

    // MARK: - 待审批：三连跳 + 鼓缩 + 瞪眼 + 惊叹号

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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。影子留在地上
    /// （腿只跟 30% 的位移），方块在起跳段脉冲式鼓缩、眼睛瞪大，惊叹号在头顶按
    /// 跳跃高度做阻尼。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

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

        // 上游的顶点会把整个角色抛出视口：整条曲线等比缩到「方块顶边」不越出视口上边缘
        // （天线本来就有半截在视口外，所以截顶的基准取方块顶边，而不是天线尖端）。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 起跳段整体左右抖一下（横向位移，与截顶无关）。
        let shake: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // 方块脉冲式鼓缩（起跳段），越大越「跳脚」。
        let pulseScale: CGFloat =
            (pct > 0.03 && pct < 0.55) ? 1.0 + sin(pct * 20) * 0.15 : 1.0

        // 刚被惊到时眼睛放大。
        let startled = pct > 0.03 && pct < 0.15

        // 惊叹号：起跳一开始亮起，安静下来淡出。
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

        // 影子：跳得越高越窄越淡，但**留在原地**。
        let shadowWidth: CGFloat = 7 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(4 + (7 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, rise)) * 0.04))))

        // 腿（跟在机身后面，只给 30% 的位移）
        drawLegs(&context, sprite, dy: rise)

        context.translateBy(x: shake * sprite.block, y: 0)
        drawBody(&context, sprite, dy: rise, scale: pulseScale)
        drawFace(&context, sprite, dy: rise, eyeScale: startled ? 1.3 : 1.0)
        context.translateBy(x: -shake * sprite.block, y: 0)

        // 惊叹号：在头顶上方，位移只有跳跃的 15%（不会飞出画布）。
        if bangOpacity > 0.01 {
            let width: CGFloat = 2 * bangScale
            let x: CGFloat = 13
            let y: CGFloat = 4 + rise * 0.15
            context.fill(
                Path(sprite.r(x, y, width, 3.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(x, y + 4.0 * bangScale, width, 1.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
        }
    }

    // MARK: - 画法

    /// 方块：从亮到暗的竖向渐变 + 圆角，头顶一根天线（细杆 + 亮端）。
    ///
    /// - Parameters:
    ///   - dy: 方块的纵向位移（SVG 单位，负值向上）
    ///   - scale: 方块整体的缩放（趴着时缩到 0.9，起跳时脉冲鼓缩）
    private func drawBody(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        scale: CGFloat = 1.0
    ) {
        let centerX: CGFloat = 7.5
        let centerY: CGFloat = 9
        let width: CGFloat = 9 * scale
        let height: CGFloat = 7 * scale
        let corner: CGFloat = 2 * scale
        let top = centerY - height / 2

        let rect = sprite.r(centerX - width / 2, top, width, height, dy: dy)
        context.fill(
            Path(roundedRect: rect, cornerRadius: corner * sprite.block),
            with: .linearGradient(
                Gradient(colors: [Self.bodyLt, Self.body, Self.bodyDk]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)))

        // 天线：细杆 + 顶端一块亮方块（尖端本来就在视口上边缘之外）
        context.fill(
            Path(sprite.r(centerX - 0.5, top - 2.5, 1, 2.5, dy: dy)), with: .color(Self.bodyDk))
        context.fill(
            Path(sprite.r(centerX - 1, top - 3.5, 2, 1.5, dy: dy)), with: .color(Self.bodyLt))
    }

    /// 眼睛：两颗白色方点。`eyeScale` 瞪大，`blinkPhase` 合眼（1 = 睁满）。
    private func drawFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        eyeScale: CGFloat = 1.0, blinkPhase: CGFloat = 1.0
    ) {
        let eyeHeight: CGFloat = 1.8 * eyeScale * blinkPhase
        let eyeY: CGFloat = 8.5 + (1.8 - eyeHeight) / 2
        context.fill(
            Path(sprite.r(5.0, eyeY, 1.3, max(0.3, eyeHeight), dy: dy)), with: .color(Self.eye))
        context.fill(
            Path(sprite.r(8.7, eyeY, 1.3, max(0.3, eyeHeight), dy: dy)), with: .color(Self.eye))
    }

    /// 腿：两条压暗的单块短腿，`dy` 只给 30%——腿比方块慢半拍，像被拖着的。
    private func drawLegs(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat = 0
    ) {
        let legDy = dy * 0.3
        let color = Self.bodyDk.opacity(0.7)
        context.fill(Path(sprite.r(5.0, 13.5, 1, 2, dy: legDy)), with: .color(color))
        context.fill(Path(sprite.r(9.0, 13.5, 1, 2, dy: legDy)), with: .color(color))
    }

    /// 影子：接地线上的一条黑带，`width` 是它的宽度（随浮沉伸缩）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 7,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15, width, 1)),
            with: .color(.black.opacity(opacity)))
    }
}