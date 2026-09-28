//
//  TraeMascot.swift
//  AgentIsland
//
//  Trae（与 Trae CLI 共用这一枚）的像素角色 TraeBot：一颗圆角终端屏——外圈亮绿壳、内嵌一块
//  暗屏，屏上两只带微光的绿点眼睛，底下两条深绿短腿。配色是终端绿（#22C55E）在暗底上发光。
//  三套场景各自在做什么：
//    · 空闲：整颗屏缓慢上下漂浮（两条不可通约的周期叠加，所以漂浮永远不完全重复），
//      腿跟着飘 30%，眼睛半睁、偶尔眨一下，头顶飘三个绿 Z；
//    · 处理中：在键盘后面砸键（每约 13 秒停一拍读输出），按键时整颗屏起伏、按下的那颗键亮成绿色；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮），跳起来时整颗屏随脉冲鼓一下、横向抖一抖，
//      头顶惊叹号。
//
//  场景视口（SVG 单位）：空闲 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）——
//  视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的 `Sources/CodeIsland/TraeView.swift`，
//  坐标常量与配色逐值保留。
//

import SwiftUI

struct TraeMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 配色：终端绿的壳与眼睛、压深一档的腿、内嵌的暗屏，键盘三档暗绿。
    private static let shell = Color(mascotHex: 0x22C55E)
    private static let shellDark = Color(mascotHex: 0x108F51)
    private static let screen = Color(red: 0.14, green: 0.20, blue: 0.14)
    private static let eye = Color(mascotHex: 0x22C55E)
    private static let alert = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.10, green: 0.14, blue: 0.10)
    private static let kbKey = Color(red: 0.20, green: 0.30, blue: 0.20)
    private static let kbFlash = Color(mascotHex: 0x22C55E)

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 7, svgTop: 3)

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

    // MARK: - 部件

    /// 终端屏本体：圆角的外壳 + 内嵌一圈的暗屏。`dy` 是整颗屏的纵向位移，
    /// 压扁 / 拉长只改宽高（屏幕居中，所以压扁时上下同时收）。
    private func drawBody(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        squashX: CGFloat = 1, squashY: CGFloat = 1
    ) {
        let centerX: CGFloat = 7.5
        let bodyWidth: CGFloat = 10 * squashX
        let bodyHeight: CGFloat = 7 * squashY
        let bodyLeft = centerX - bodyWidth / 2
        let bodyTop: CGFloat = 7 + (7 - bodyHeight) / 2

        let outerRect = sprite.r(bodyLeft, bodyTop, bodyWidth, bodyHeight, dy: dy)
        context.fill(
            Path(roundedRect: outerRect, cornerRadius: 1.5 * sprite.block),
            with: .color(Self.shell))

        // 内嵌的暗屏
        let inset: CGFloat = 1.2
        let innerRect = sprite.r(
            bodyLeft + inset, bodyTop + inset, bodyWidth - inset * 2, bodyHeight - inset * 2,
            dy: dy)
        context.fill(
            Path(roundedRect: innerRect, cornerRadius: 0.8 * sprite.block),
            with: .color(Self.screen))
    }

    /// 脸：两只绿点眼睛（外面一圈更淡的光晕，眨眼到很扁时连光晕一起收掉）。
    private func drawFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        eyeScale: CGFloat = 1.0, blinkPhase: CGFloat = 1.0
    ) {
        let eyeHeight: CGFloat = 1.8 * eyeScale * blinkPhase
        let eyeWidth: CGFloat = 1.8 * eyeScale
        let eyeY: CGFloat = 10.0 + (1.8 - eyeHeight) / 2

        // 微光：眼睛睁开时才画
        if blinkPhase > 0.3 {
            let leftGlow = sprite.r(4.5, eyeY - 0.5, eyeWidth + 1, eyeHeight + 1, dy: dy)
            context.fill(Path(ellipseIn: leftGlow), with: .color(Self.eye.opacity(0.2)))
            let rightGlow = sprite.r(8.2, eyeY - 0.5, eyeWidth + 1, eyeHeight + 1, dy: dy)
            context.fill(Path(ellipseIn: rightGlow), with: .color(Self.eye.opacity(0.2)))
        }

        context.fill(
            Path(ellipseIn: sprite.r(5.0, eyeY, eyeWidth, max(0.3, eyeHeight), dy: dy)),
            with: .color(Self.eye))
        context.fill(
            Path(ellipseIn: sprite.r(8.7, eyeY, eyeWidth, max(0.3, eyeHeight), dy: dy)),
            with: .color(Self.eye))
    }

    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite,
        width: CGFloat = 7, opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两条深绿短腿：只跟 30% 的上下位移（身体飘起来时腿像被拉住一样留在低处）。
    private func drawLegs(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat = 0
    ) {
        let legDy = dy * 0.3
        context.fill(
            Path(sprite.r(5.5, 14, 1, 2, dy: legDy)),
            with: .color(Self.shellDark.opacity(0.7)))
        context.fill(
            Path(sprite.r(8.5, 14, 1, 2, dy: legDy)),
            with: .color(Self.shellDark.opacity(0.7)))
    }

    // MARK: - 空闲：漂浮打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)

            // 两条不可通约的漂浮周期：叠加起来永远不完全重复，同屏的多枚角色也因此不同相。
            let float = sin(t * 2 * .pi / 3.94) * 0.68 + sin(t * 2 * .pi / 6.29) * 0.36
            // 半睁的眼睛每 4 秒眨一下（眨的那 0.2 秒压到 0.15）。
            let blinkCycle = t.truncatingRemainder(dividingBy: 4.0)
            let blinkPhase: CGFloat = (blinkCycle > 3.5 && blinkCycle < 3.7) ? 0.15 : 0.5

            drawShadow(&context, sprite, width: 6 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(&context, sprite, dy: float)
            drawBody(&context, sprite, dy: float, squashX: 1.0, squashY: 0.95)
            drawFace(&context, sprite, dy: float, blinkPhase: blinkPhase)
            // Z 锚在圆角屏顶边：睡眠档 squashY 0.95 → 7 + (7 − 7 × 0.95) / 2 = 7.175。
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: 7.175, t: t, size: size, color: Self.shell)
        }
    }

    // MARK: - 处理中：在键盘后面砸键

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 打字：整颗屏随按键起落，按下的键闪一下；每约 13 秒停一拍——那一下在「读输出」，
    /// 而不是一直砸键，节奏因此是一阵一阵的。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let workPause = MascotMotion.quirk(t, cycle: 12.9, duration: 1.2, seed: 0x9C7)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let blink = max(0.1, MascotMotion.blink(t, seed: 0x9C8))
        let keyPhase = Int(t / 0.1) % 6

        let shadowWidth: CGFloat = 7 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (7 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        drawLegs(&context, sprite, dy: bounce)

        // 键盘（画在腿前面，把腿挡住）
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 13.5 + CGFloat(row) * 1.2
            for column in 0..<6 {
                let keyX = 0.5 + CGFloat(column) * 2.4
                context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
            }
        }
        let flashRow = keyPhase / 3
        let flashColumn = keyPhase % 6
        context.fill(
            Path(sprite.r(0.5 + CGFloat(flashColumn) * 2.4, 13.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
            with: .color(Self.kbFlash.opacity(0.9)))

        drawBody(&context, sprite, dy: bounce)
        drawFace(&context, sprite, dy: bounce, blinkPhase: blink)
    }

    // MARK: - 待审批：三连跳

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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。
    /// 影子留在地上（腿只跟 30% 的位移），惊叹号的位置按跳跃高度做阻尼。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        let jumpY = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: -1), (at: 0.15, value: 1.5),
                (at: 0.175, value: -8), (at: 0.20, value: -8), (at: 0.25, value: 1.5),
                (at: 0.275, value: -6), (at: 0.30, value: -6), (at: 0.35, value: 1.0),
                (at: 0.375, value: -4), (at: 0.40, value: -4), (at: 0.45, value: 0.8),
                (at: 0.475, value: -2), (at: 0.50, value: -2), (at: 0.55, value: 0.3),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)

        // 上游的顶点会把身体整个抛出视口（实拍只剩腿与影子）：整条曲线等比缩到身体
        // 顶边不越出视口上边缘，跳得起来、也永远看得见。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 横向抖动与「整颗屏鼓一下」都只在起跳那一段。
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        let pulseScale: CGFloat =
            (pct > 0.03 && pct < 0.55) ? 1.0 + sin(pct * 20) * 0.08 : 1.0

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

        // 腿：只跟 30% 的位移，看起来像被身体拉住（身体升得比腿高）。
        drawLegs(&context, sprite, dy: rise)

        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawBody(&context, sprite, dy: rise, squashX: pulseScale, squashY: pulseScale)
        drawFace(
            &context, sprite, dy: rise, eyeScale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
        context.translateBy(x: -shakeX * sprite.block, y: 0)

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
}