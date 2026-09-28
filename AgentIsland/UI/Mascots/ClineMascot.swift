//
//  ClineMascot.swift
//  AgentIsland
//
//  Cline 的像素角色 ClineBot：一台亮绿的小机器人——圆角机身（自上而下由亮绿渐变到深绿）、
//  头顶一枚半圆天线、两侧各一只小耳朵、两只纯白方眼。
//    · 空闲：机身在地面上轻轻漂浮，两条腿跟着浮（只跟三成），眼睛半阖、每 4 秒眨一下，
//      头顶从机身顶边上方飘出三枚 Z；
//    · 处理中：机器人蹲在键盘后面敲字，随按键上下起伏，键帽每 0.1 秒换一格亮起来，
//      每约 11 秒停一拍（像在读输出，而不是一直敲）；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮），跳起来时瞪眼、机身左右抖并脉冲放大，
//      头顶惊叹号亮起。
//
//  场景视口（SVG 单位）：漂浮 15×12（上边缘 y=4）、打字 16×14（上边缘 y=3）、
//  起跳 16×14（上边缘 y=3）——视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/ClineView.swift`，坐标常量与配色逐值保留。上游还定义了一枚扳手
//  （`drawWrench`），但三套场景都没有调用它（死代码，画面上从未出现），故未移植。
//

import SwiftUI

struct ClineMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（机身绿——品牌色是白的，绿才是这只角色的样子）。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = bodyC

    /// 配色取自 Cline 的品牌绿：机身三段渐变、纯白眼睛、橙红警报、键盘是压暗的绿。
    private static let bodyC = Color(mascotHex: 0x00B37D)  // 品牌绿（机身中段）
    private static let bodyDk = Color(red: 0.00, green: 0.50, blue: 0.35)  // 机身暗段（也是腿）
    private static let bodyLt = Color(red: 0.20, green: 0.85, blue: 0.62)  // 机身亮段（也是天线）
    private static let eyeC = Color.white
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)  // 橙红
    private static let kbBase = Color(red: 0.00, green: 0.30, blue: 0.22)
    private static let kbKey = Color(red: 0.00, green: 0.55, blue: 0.38)
    private static let kbHi = Color(red: 0.20, green: 0.95, blue: 0.68)

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 4.1, svgTop: 3)

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

    // MARK: - 机身

    /// 机身：一枚圆角方块，自上而下由亮绿到深绿的三段渐变；头顶一枚半圆天线（没有杆，
    /// 直接坐在机身顶上），左右各一枚小耳朵。`scale` 是起跳时的脉冲放大。
    private func drawBody(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat, scale: CGFloat = 1.0
    ) {
        let cx: CGFloat = 7.5, cy: CGFloat = 9.0
        let width: CGFloat = 9 * scale, height: CGFloat = 7 * scale
        let radius: CGFloat = 1.8 * scale
        let rect = sprite.r(cx - width / 2, cy - height / 2, width, height, dy: dy)
        context.fill(
            Path(roundedRect: rect, cornerRadius: radius * sprite.block),
            with: .linearGradient(
                Gradient(colors: [Self.bodyLt, Self.bodyC, Self.bodyDk]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)))

        // 天线：直接坐在机身顶上的一枚半圆
        let axisX = sprite.origin.x + cx * sprite.block
        let ballW: CGFloat = 2.4 * scale * sprite.block
        let ballH: CGFloat = 1.4 * scale * sprite.block
        let ballRect = CGRect(
            x: axisX - ballW / 2, y: rect.minY - ballH, width: ballW, height: ballH)
        context.fill(
            Path(roundedRect: ballRect, cornerRadius: ballW / 2), with: .color(Self.bodyLt))

        // 耳朵：机身左右各一枚小圆角矩形
        let earW: CGFloat = 1.2 * scale * sprite.block
        let earH: CGFloat = 2.2 * scale * sprite.block
        let earY = rect.midY - earH / 2
        let leftEar = CGRect(x: rect.minX - earW * 0.6, y: earY, width: earW, height: earH)
        let rightEar = CGRect(x: rect.maxX - earW * 0.4, y: earY, width: earW, height: earH)
        let earRadius = earW / 2
        context.fill(Path(roundedRect: leftEar, cornerRadius: earRadius), with: .color(Self.bodyC))
        context.fill(Path(roundedRect: rightEar, cornerRadius: earRadius), with: .color(Self.bodyC))
    }

    /// 脸：两只纯白方眼。`blinkPhase` 压低它们（睡觉时的半阖眼、打字时的眨眼）。
    private func drawFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        eyeScale: CGFloat = 1.0, blinkPhase: CGFloat = 1.0
    ) {
        let eyeH: CGFloat = 1.8 * eyeScale * blinkPhase
        let eyeY: CGFloat = 8.5 + (1.8 - eyeH) / 2
        context.fill(
            Path(sprite.r(5.0, eyeY, 1.3, max(0.3, eyeH), dy: dy)), with: .color(Self.eyeC))
        context.fill(
            Path(sprite.r(8.7, eyeY, 1.3, max(0.3, eyeH), dy: dy)), with: .color(Self.eyeC))
    }

    /// 影子：一条压在地面上的黑线。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 7,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两条腿：只跟机身位移的**三成**——跳起来时腿被拉长，像还踩在地上。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat = 0) {
        let legDy = dy * 0.3
        context.fill(
            Path(sprite.r(5.0, 13.5, 1, 2, dy: legDy)), with: .color(Self.bodyDk.opacity(0.7)))
        context.fill(
            Path(sprite.r(9.0, 13.5, 1, 2, dy: legDy)), with: .color(Self.bodyDk.opacity(0.7)))
    }

    // MARK: - 空闲：飘着睡

    private var sleepScene: some View {
        Canvas { context, canvas in
            // 两个不可通约的周期叠出来的漂浮（4.33 / 5.92 秒）：浮沉不会精确重复，
            // 同屏多枚角色也因此各有各的节拍，不会跳成一排。
            let float = sin(t * 2 * .pi / 4.33) * 0.68 + sin(t * 2 * .pi / 5.92) * 0.36
            let blinkCycle = t.truncatingRemainder(dividingBy: 4.0)
            let blink: CGFloat = (blinkCycle > 3.5 && blinkCycle < 3.7) ? 0.15 : 0.5
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawShadow(&context, sprite, width: 6 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(&context, sprite, dy: float)
            drawBody(&context, sprite, dy: float, scale: 0.9)
            drawFace(&context, sprite, dy: float, blinkPhase: blink)
            // 飘 Z 从机身（scale 0.9 → 顶边 SVG y=5.85）上方升起；头顶细天线不算主体顶边。
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: 5.85, t: t, size: size, color: Self.sleepZ)
        }
    }

    // MARK: - 处理中：趴在键盘上打字

    private var workScene: some View {
        Canvas { context, canvas in
            // 每约 11 秒停一拍：起伏从「随按键的快抖」换成「缓慢的呼吸」——
            // 像在读输出，而不是一直敲键盘。
            let workPause = MascotMotion.quirk(t, cycle: 11.1, duration: 1.2, seed: 0xFE2)
            let bounce =
                sin(t * 2 * .pi / 0.5) * 0.8 * (1 - workPause)
                + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
            let blink = max(0.1, MascotMotion.blink(t, seed: 0xFE3))
            let keyPhase = Int(t / 0.1) % 12

            let sprite = MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3)
            let dy = bounce

            // 1. 影子（起伏越大越窄越淡）
            let shadowWidth: CGFloat = 7 - abs(dy) * 0.3
            context.fill(
                Path(sprite.r(4 + (7 - shadowWidth) / 2, 16, shadowWidth, 1)),
                with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

            // 2. 键盘：2 行 × 6 列的键帽，每 0.1 秒换一格亮起来
            context.fill(Path(sprite.r(0.5, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let keyY = 13.5 + CGFloat(row) * 1.2
                for column in 0..<6 {
                    let keyX = 1.0 + CGFloat(column) * 2.3
                    context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            let flashRow = keyPhase / 6
            let flashColumn = keyPhase % 6
            context.fill(
                Path(sprite.r(1.0 + CGFloat(flashColumn) * 2.3, 13.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
                with: .color(Self.kbHi.opacity(0.9)))

            // 3. 腿、机身与脸（叠在键盘后面，只有上半身露出来）
            drawLegs(&context, sprite, dy: dy)
            drawBody(&context, sprite, dy: dy, scale: 1.0)
            drawFace(&context, sprite, dy: dy, blinkPhase: blink)
        }
    }

    // MARK: - 待审批：三连跳 + 瞪眼 + 惊叹号

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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。
    /// 影子留在地上，腿只跟三成、机身在跳，惊叹号的位置按跳跃高度做阻尼。
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

        // 上游的顶点（-8 个单位）比视口还高：实拍那一帧只剩腿与影子，机身整块被裁掉。
        // 整条曲线等比缩到机身（含头顶天线）不越出视口上边缘——跳得起来，也永远看得见。
        let rise = jumpY * Self.alertSpec.riseFactor

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        // 起跳期间的脉冲放大（与位移无关，故用原始进度判定）。
        let pulseScale: CGFloat = (pct > 0.03 && pct < 0.55) ? 1.0 + sin(pct * 20) * 0.15 : 1.0

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

        // 腿：跟着机身走，但只跟三成（跳起来时被拉长）
        drawLegs(&context, sprite, dy: rise)

        // 机身与脸：左右抖一下（抖的是横向位移，与截顶无关）
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawBody(&context, sprite, dy: rise, scale: pulseScale)
        drawFace(&context, sprite, dy: rise, eyeScale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
        context.translateBy(x: -shakeX * sprite.block, y: 0)

        // 惊叹号：在头顶上方，位移只有跳跃的 15%（不会飞出画布）。
        if bangOpacity > 0.01 {
            let width: CGFloat = 2 * bangScale
            let x: CGFloat = 13
            let y: CGFloat = 4 + rise * 0.15
            context.fill(
                Path(sprite.r(x, y, width, 3.5 * bangScale)),
                with: .color(Self.alertC.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(x, y + 4.0 * bangScale, width, 1.5 * bangScale)),
                with: .color(Self.alertC.opacity(bangOpacity)))
        }
    }
}