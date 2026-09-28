//
//  HermesMascot.swift
//  AgentIsland
//
//  Hermes（Nous Research）的像素角色：兜帽罩头、只露一对亮白发光眼的神秘小人。
//  深紫机身（#7A58B0）配亮白眼，兜帽是压在机身上的三角尖顶，警报色是橙红。
//    · 空闲：两条不成比例的漂移周期叠加，整只悬着轻轻起伏（因此读起来不像节拍器），
//      眼睛时而眯成一条缝，头顶飘三个 Z；
//    · 处理中：趴在键盘上敲字，身体随按键起伏，按下的键亮一下，偶尔停下来一轮；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮）+ 左右抖动 + 头顶惊叹号。
//
//  场景视口（SVG 单位）：睡觉 15×12（上边缘 y=4）、打字 16×14（上边缘 y=3）、
//  起跳 16×14（上边缘 y=3）——视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的 `Sources/CodeIsland/HermesView.swift`，
//  坐标常量与配色逐值保留。
//

import SwiftUI

struct HermesMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 配色：中紫机身、更暗的腿、兜帽、亮白眼、警报橙、键盘三档深色。
    private static let bodyC = Color(mascotHex: 0x7A58B0)
    private static let bodyDk = Color(red: 0.380, green: 0.260, blue: 0.580)
    private static let hoodC = Color(red: 0.400, green: 0.280, blue: 0.620)
    private static let eyeC = Color(red: 1.0, green: 1.0, blue: 1.0)
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.12, green: 0.08, blue: 0.18)
    private static let kbKey = Color(red: 0.24, green: 0.18, blue: 0.34)
    private static let kbHi = Color(red: 0.85, green: 0.85, blue: 0.95)

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 4.5, svgTop: 3)

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

    // MARK: - 空闲：悬着打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite)
            // Z 从趴姿兜帽尖上方升起（兜帽尖 = cy − 6·0.9/2 − 3·0.9 = 10.5 − 2.7 − 2.7），
            // 不压到兜帽与机身上。
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 5.1, t: t, size: size)
        }
    }

    /// 打盹：两条不成比例的漂移周期叠出的呼吸（漂移几乎不重复），机身缩到 90% 摊着，
    /// 影子随漂移变宽变淡，眼睛眯成半条缝——睡是睡着的，但还在呼吸。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let float = sin(t * 2 * .pi / 3.92) * 0.68 + sin(t * 2 * .pi / 7.04) * 0.36

        // 每 4 秒眯一下眼（0.15 → 只留一道光），其余时间半睁。
        let blinkCycle = t.truncatingRemainder(dividingBy: 4.0)
        let blink: CGFloat = (blinkCycle > 3.5 && blinkCycle < 3.7) ? 0.15 : 0.5

        drawShadow(&context, sprite, width: 6 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(&context, sprite, dy: float)
        drawBody(&context, sprite, dy: float, scale: 0.9)
        drawFace(&context, sprite, dy: float, blinkPhase: blink)
    }

    // MARK: - 处理中：趴在键盘上打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 打字：身体随按键快速起伏，停下来那一轮换成缓慢的摆动；按下的键亮一下
    /// （亮哪一格按 `t` 的槽位确定，因此同一时刻永远亮同一格）。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let workPause = MascotMotion.quirk(t, cycle: 11.3, duration: 1.2, seed: 0xCDC)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let blink = max(0.1, MascotMotion.blink(t, seed: 0xCDD))
        let keyPhase = Int(t / 0.1) % 6

        // 1. 影子（起伏越大越窄越淡）
        let shadowWidth: CGFloat = 7 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (7 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        // 2. 短腿（在键盘后面）
        drawLegs(&context, sprite, dy: bounce)

        // 3. 键盘（盖在腿上）+ 2 行 × 6 列的键帽
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 13.5 + CGFloat(row) * 1.2
            for column in 0..<6 {
                context.fill(
                    Path(sprite.r(0.5 + CGFloat(column) * 2.4, keyY, 1.8, 0.7)),
                    with: .color(Self.kbKey))
            }
        }
        context.fill(
            Path(
                sprite.r(
                    0.5 + CGFloat(keyPhase % 6) * 2.4, 13.5 + CGFloat(keyPhase / 3) * 1.2, 1.8, 0.7)),
            with: .color(Self.kbHi.opacity(0.9)))

        // 4. 机身与脸（整体跟着敲击起伏）
        drawBody(&context, sprite, dy: bounce)
        drawFace(&context, sprite, dy: bounce, blinkPhase: blink)
    }

    // MARK: - 待审批：三连跳 + 抖动 + 惊叹号

    private var alertScene: some View {
        ZStack {
            // 警报光晕：常亮一点余晖、随安静段慢慢呼吸。用径向渐变而不是 `blur`
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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，跳到顶点时整只左右抖动。
    /// 影子留在地上（只有机身与腿跟着跳），惊叹号的位置按跳跃高度做阻尼。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        // 三连跳：一跳比一跳矮。
        let jumpY = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.175, value: -8),
                (at: 0.25, value: 1.5), (at: 0.275, value: -6), (at: 0.35, value: 1),
                (at: 0.375, value: -4), (at: 0.45, value: 0.8), (at: 0.475, value: -2),
                (at: 0.55, value: 0.3), (at: 0.62, value: 0), (at: 1, value: 0),
            ], at: pct)

        // 上游的顶点会把身体整个抛出视口（兜帽尖到视口上边缘只有 1.5 个单位）：
        // 整条曲线等比缩到兜帽尖不越出视口上边缘，跳得起来、也永远看得见。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 顶点最抖：横向的抖动与跳幅无关（不会把身体推出画布），因此不随截顶缩放。
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // 惊叹号：起跳一开始亮起，安静下来淡出。
        let bangOpacity = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 1), (at: 0.55, value: 1), (at: 0.62, value: 0),
                (at: 1, value: 0),
            ], at: pct)

        // 影子：跳得越高越窄越淡，但**留在原地**。
        let shadowWidth: CGFloat = 7 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(4 + (7 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, rise)) * 0.04))))

        // 腿（跟着机身跳，幅度仍是机身的 30%）
        drawLegs(&context, sprite, dy: rise)

        // 机身与脸：整体左右抖，抖完再挪回去（让惊叹号留在原地）
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawBody(&context, sprite, dy: rise)
        drawFace(&context, sprite, dy: rise)
        context.translateBy(x: -shakeX * sprite.block, y: 0)

        // 惊叹号：在头顶上方，位移只有跳跃的 15%（不会飞出画布）。
        if bangOpacity > 0.01 {
            let x: CGFloat = 13
            let y: CGFloat = 4 + rise * 0.15
            context.fill(
                Path(sprite.r(x, y, 2, 3.5)),
                with: .color(Self.alertC.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(x, y + 4.0, 2, 1.5)),
                with: .color(Self.alertC.opacity(bangOpacity)))
        }
    }

    // MARK: - 画法

    /// 机身：圆角矩形 + 压在肩上的三角尖顶兜帽。`scale` 只缩机身（睡觉时摊小一圈）。
    private func drawBody(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        scale: CGFloat = 1.0
    ) {
        let cx: CGFloat = 7.5, cy: CGFloat = 10.5
        let bodyWidth: CGFloat = 9 * scale
        let bodyHeight: CGFloat = 6 * scale

        // 机身
        let bodyRect = sprite.r(cx - bodyWidth / 2, cy - bodyHeight / 2 + 1, bodyWidth, bodyHeight, dy: dy)
        context.fill(
            Path(roundedRect: bodyRect, cornerRadius: 1.5 * sprite.block),
            with: .color(Self.bodyC))

        // 兜帽（肩上的尖顶三角）
        var hood = Path()
        let top = sprite.point(cx, cy - bodyHeight / 2 - 3 * scale, dy: dy)
        let left = sprite.point(cx - bodyWidth / 2 - 0.5, cy - bodyHeight / 2 + 2, dy: dy)
        let right = sprite.point(cx + bodyWidth / 2 + 0.5, cy - bodyHeight / 2 + 2, dy: dy)
        hood.move(to: top)
        hood.addLine(to: right)
        hood.addLine(to: left)
        hood.closeSubpath()
        context.fill(hood, with: .color(Self.hoodC))
    }

    /// 脸：兜帽下的一对发光眼。`blinkPhase` 收窄眼高（→0 时眼睛闭成一条线）；
    /// 半睁以上时在眼外再罩一层 15% 的白光晕，暗底上读作「在发光」。
    private func drawFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        blinkPhase: CGFloat = 1.0
    ) {
        let eyeHeight: CGFloat = 1.2 * blinkPhase
        let eyeWidth: CGFloat = 1.8
        let eyeY: CGFloat = 10.5 + (1.2 - eyeHeight) / 2

        if blinkPhase > 0.3 {
            context.fill(
                Path(sprite.r(4.8, eyeY - 0.3, eyeWidth + 0.6, eyeHeight + 0.6, dy: dy)),
                with: .color(Self.eyeC.opacity(0.15)))
            context.fill(
                Path(sprite.r(8.4, eyeY - 0.3, eyeWidth + 0.6, eyeHeight + 0.6, dy: dy)),
                with: .color(Self.eyeC.opacity(0.15)))
        }
        context.fill(
            Path(sprite.r(5.1, eyeY, eyeWidth, max(0.2, eyeHeight), dy: dy)),
            with: .color(Self.eyeC))
        context.fill(
            Path(sprite.r(8.7, eyeY, eyeWidth, max(0.2, eyeHeight), dy: dy)),
            with: .color(Self.eyeC))
    }

    /// 影子：落地的那条 1 单位高的黑带，宽度与深浅由调用方给（跳得越高越窄越淡）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 7,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15, width, 1)), with: .color(.black.opacity(opacity)))
    }

    /// 两条短腿：只跟随机身 30% 的纵向位移（机身先动、腿后跟——整块一起平移就不像在蹬地了）。
    private func drawLegs(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat = 0
    ) {
        let legDy = dy * 0.3
        context.fill(
            Path(sprite.r(5.5, 14, 1, 2, dy: legDy)), with: .color(Self.bodyDk.opacity(0.7)))
        context.fill(
            Path(sprite.r(8.5, 14, 1, 2, dy: legDy)), with: .color(Self.bodyDk.opacity(0.7)))
    }
}