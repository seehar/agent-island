//
//  PiMascot.swift
//  AgentIsland
//
//  Pi / Oh My Pi 的像素角色：一台深青绿的小终端，屏幕上是一枚像素 π（π 的左右两竖就是
//  它的眼睛），头顶顶着一片青色的叶子。
//    · 空闲：坐在地上打盹——两个互不整除的漂移周期把机身托起又放下，眼睛每 4 秒眯一下，
//      头顶飘三个 Z；
//    · 处理中：坐在键盘前打字——机身随按键起伏，键帽上有一格在亮，眼睛叠自然眨眼；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮）+ 左右发抖 + π 脸转成警报橙 + 头顶惊叹号
//      + 警报光晕。
//
//  场景视口（SVG 单位）：打盹 16×12（上边缘 y=4）、打字 16×14（上边缘 y=3）、
//  起跳 16×14（上边缘 y=3）——视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的 `Sources/CodeIsland/PiView.swift`，
//  坐标常量与配色逐值保留；时间改为显式传参（`t`），每一帧因此都是 `t` 的纯函数。
//

import SwiftUI

struct PiMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 深青绿外壳 + 亮青叶面：不像「常见的绿色 CLI」，但一眼认得出是 Pi。
    private static let shellC = Color(red: 0.14, green: 0.49, blue: 0.53)
    private static let shellDk = Color(red: 0.09, green: 0.30, blue: 0.34)
    private static let leafC = Color(red: 0.44, green: 0.90, blue: 0.95)
    private static let faceC = Color(red: 0.05, green: 0.12, blue: 0.13)
    private static let alertC = Color(red: 1.0, green: 0.35, blue: 0.14)
    private static let kbBase = Color(red: 0.08, green: 0.13, blue: 0.16)
    private static let kbKey = Color(red: 0.13, green: 0.23, blue: 0.27)
    private static let kbHi = Color(red: 0.72, green: 0.96, blue: 1.0)

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 7.5, bodyTop: 6.2, svgTop: 3)

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

    // MARK: - 部件（三套场景共用）

    /// 地上的一格影子（宽度与浓度由各场景给）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 7,
        opacity: Double = 0.28
    ) {
        context.fill(
            Path(sprite.r(8 - width / 2, 15, width, 1)), with: .color(.black.opacity(opacity)))
    }

    /// 两只脚：跟着身体走 25% 的位移，所以跳起来时脚还留在地上。
    private func drawFeet(_ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat) {
        let footDy = dy * 0.25
        context.fill(
            Path(sprite.r(5.5, 13.8, 1.2, 1.5, dy: footDy)),
            with: .color(Self.shellDk.opacity(0.75)))
        context.fill(
            Path(sprite.r(9.3, 13.8, 1.2, 1.5, dy: footDy)),
            with: .color(Self.shellDk.opacity(0.75)))
    }

    /// 头顶的两片叶子（先后插在机身上）+ 中间的叶柄。
    private func drawLeaf(_ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat) {
        context.fill(
            Path(ellipseIn: sprite.r(5.7, 2.2, 2.2, 1.3, dy: dy)), with: .color(Self.leafC))
        context.fill(
            Path(ellipseIn: sprite.r(8.0, 1.8, 2.6, 1.5, dy: dy)), with: .color(Self.leafC))
        context.fill(Path(sprite.r(7.8, 2.8, 0.4, 1.0, dy: dy)), with: .color(Self.shellDk))
    }

    /// 机身：一块圆角终端（`scale` 用于打盹时压得矮一点），顶上一道高光、底下一道暗边。
    private func drawBody(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        scale: CGFloat = 1.0
    ) {
        let cx: CGFloat = 8
        let cy: CGFloat = 9.5
        let bw: CGFloat = 8.8 * scale
        let bh: CGFloat = 6.6 * scale
        let bodyRect = sprite.r(cx - bw / 2, cy - bh / 2, bw, bh, dy: dy)
        context.fill(
            Path(roundedRect: bodyRect, cornerRadius: 1.6 * sprite.block),
            with: .color(Self.shellC))
        context.fill(
            Path(sprite.r(cx - bw / 2 + 0.6, cy - bh / 2 + 0.6, bw - 1.2, 0.7, dy: dy)),
            with: .color(.white.opacity(0.18)))
        context.fill(
            Path(sprite.r(cx - bw / 2, cy + bh / 2 - 1.2, bw, 1.2, dy: dy)),
            with: .color(Self.shellDk.opacity(0.8)))
        drawLeaf(&context, sprite, dy: dy)
    }

    /// 像素 π 脸：左右两竖是眼睛（`eyeScale` 是睁眼程度），上面一横、下面两竖是 π 的字形。
    private func drawPiFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        eyeScale: CGFloat = 1.0, color: Color = Self.faceC
    ) {
        let eyeH = max(0.2, 1.0 * eyeScale)
        context.fill(
            Path(sprite.r(5.4, 8.0 + (1 - eyeH) * 0.3, 1.3, eyeH, dy: dy)), with: .color(color))
        context.fill(
            Path(sprite.r(9.3, 8.0 + (1 - eyeH) * 0.3, 1.3, eyeH, dy: dy)), with: .color(color))
        context.fill(Path(sprite.r(6.2, 9.8, 3.6, 0.6, dy: dy)), with: .color(color))
        context.fill(Path(sprite.r(6.6, 9.4, 0.6, 2.0, dy: dy)), with: .color(color))
        context.fill(Path(sprite.r(8.8, 9.4, 0.6, 2.0, dy: dy)), with: .color(color))
    }

    // MARK: - 空闲：坐在地上打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 16, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite)
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 6.4, t: t, size: size)
        }
    }

    /// 打盹：两个互不整除的漂移周期（4.04s / 6.87s）叠出「永远差一点才重复」的起伏；
    /// 眼睛每 4 秒眯一下（第 3.5–3.7 秒），机身压得比站立时矮一点（0.94）。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let float = sin(t * 2 * .pi / 4.04) * 0.59 + sin(t * 2 * .pi / 6.87) * 0.32
        let blinkPhase = t.truncatingRemainder(dividingBy: 4.0)
        let blink: CGFloat = (blinkPhase > 3.5 && blinkPhase < 3.7) ? 0.15 : 1.0

        drawShadow(&context, sprite, width: 6.4 + abs(float) * 0.3, opacity: 0.18)
        drawFeet(&context, sprite, dy: float)
        drawBody(&context, sprite, dy: float, scale: 0.94)
        drawPiFace(&context, sprite, dy: float, eyeScale: blink)
    }

    // MARK: - 处理中：坐在键盘前打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 打字：机身随按键起伏，键盘上有一格键在亮，眼睛叠自然眨眼。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let bounce = sin(t * 2 * .pi / 0.42) * 0.9
        let blink = max(0.1, MascotMotion.blink(t, seed: 0x9bb))
        let keyPhase = Int(t / 0.1) % 6

        drawShadow(
            &context, sprite, width: 7 - abs(bounce) * 0.25,
            opacity: max(0.1, 0.32 - abs(bounce) * 0.02))
        drawFeet(&context, sprite, dy: bounce)

        // 键盘 + 两行 × 六列键帽
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 13.45 + CGFloat(row) * 1.15
            for column in 0..<6 {
                context.fill(
                    Path(sprite.r(0.5 + CGFloat(column) * 2.4, keyY, 1.8, 0.68)),
                    with: .color(Self.kbKey))
            }
        }
        // 亮着的那一格：位置随 0.1 秒的节拍在 6 格里轮换（确定性）。
        context.fill(
            Path(
                sprite.r(
                    0.5 + CGFloat(keyPhase % 6) * 2.4, 13.45 + CGFloat(keyPhase / 3) * 1.15, 1.8,
                    0.68)),
            with: .color(Self.kbHi.opacity(0.95)))

        drawBody(&context, sprite, dy: bounce)
        drawPiFace(&context, sprite, dy: bounce, eyeScale: blink)
    }

    // MARK: - 待审批：三连跳 + 抖 + 惊叹号

    private var alertScene: some View {
        ZStack {
            // 警报光晕：常亮一点余晖，随安静段慢慢呼吸。用径向渐变而不是 `blur`
            // （20fps 下模糊的离屏渲染太贵），强度是 `t` 的纯函数。
            RadialGradient(
                colors: [
                    Self.alertC.opacity(0.05 + 0.07 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.0))),
                    Self.alertC.opacity(0),
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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。
    /// 影子与脚留在地上，π 脸在惊慌时转成警报橙，惊叹号按跳跃高度做 15% 的阻尼位移。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        let jumpY = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.18, value: -7.5),
                (at: 0.26, value: 1.3), (at: 0.34, value: -5.5), (at: 0.42, value: 0.8),
                (at: 0.5, value: -2.5), (at: 0.58, value: 0.2), (at: 0.68, value: 0),
                (at: 1.0, value: 0),
            ], at: pct)

        // 上游的顶点会把机身整个抛出视口：整条曲线等比缩到机身顶边不越出视口上边缘。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 左右发抖：包络逐值保留（只在起跳那一段抖）。
        let shakeX: CGFloat = (pct > 0.16 && pct < 0.56) ? sin(pct * 80) * 0.55 : 0

        let bangOpacity = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 1), (at: 0.56, value: 1), (at: 0.64, value: 0),
                (at: 1.0, value: 0),
            ], at: pct)

        // 惊叹号亮着的时候 π 脸转成警报橙（在喊你，不是平常的样子）。
        let faceColor = bangOpacity > 0.4 ? Self.alertC : Self.faceC

        // 影子：跳得越高越窄越淡，但**留在原地**。
        drawShadow(
            &context, sprite, width: 7 * (1.0 - abs(min(0, rise)) * 0.04),
            opacity: max(0.08, 0.4 - abs(min(0, rise)) * 0.04))
        drawFeet(&context, sprite, dy: rise)

        // 抖的是机身与脸，脚和影子不抖。
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawBody(&context, sprite, dy: rise)
        drawPiFace(&context, sprite, dy: rise, color: faceColor)
        context.translateBy(x: -shakeX * sprite.block, y: 0)

        // 惊叹号：在机身右上方，位移只有跳跃的 15%（不会飞出画布）。
        if bangOpacity > 0.01 {
            context.fill(
                Path(sprite.r(12.8, 4 + rise * 0.15, 1.8, 3.4)),
                with: .color(Self.alertC.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(12.8, 8.1 + rise * 0.15, 1.8, 1.3)),
                with: .color(Self.alertC.opacity(bangOpacity)))
        }
    }
}