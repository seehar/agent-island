//
//  CopilotMascot.swift
//  AgentIsland
//
//  GitHub Copilot 的像素角色（上游名 CopilotBot，画法取自 copilot-avatar.svg）：
//  头顶一对中空的方耳环（╭─╮ / ╰─╯），玫红的外框里嵌一块深色面屏，屏上两颗金色方点
//  眼睛、屏下一条玫红下巴——一只极简的小机器人。
//    · 空闲：整体轻轻浮着打盹（两个不可通约的周期叠加，浮沉几乎不会正好重复），
//      外壳压暗（睡意）、腿伸在地上，耳环与机身一起浮，头顶飘三个 Z；
//    · 处理中：坐在键盘前敲字——机身随按键起伏，约每 2.5 秒耳环心亮一下（像在收数据），
//      按下的键帽亮一下，眼睛按快门眨；
//    · 待审批：三连跳（一跳比一跳矮）+ 耳环与外框闪成警报橙 + 眼睛瞪大一倍 +
//      头顶惊叹号 + 警报光晕。
//
//  场景视口（SVG 单位）：趴姿 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）。
//
//  来源：移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/CopilotView.swift`，坐标常量与配色逐值保留。
//

import SwiftUI

struct CopilotMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 配色取自 copilot-avatar.svg：耳环近黑、外壳玫红、眼睛金色、警报橙；
    /// 面屏与键盘是暗档，键帽压暗一档、按下去的那一格取纯白。
    private static let ear = Color(mascotHex: 0x333333)
    private static let shell = Color(mascotHex: 0xCC3366)
    private static let face = Color(red: 0.13, green: 0.13, blue: 0.16)
    private static let eye = Color(mascotHex: 0xFFD700)
    private static let alert = Color(mascotHex: 0xFE4C25)
    private static let kbBase = Color(red: 0.12, green: 0.08, blue: 0.10)
    private static let kbKey = Color(red: 0.35, green: 0.15, blue: 0.22)
    private static let kbFlash = Color.white

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 5, svgTop: 3)

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

    /// 趴姿机身的几何：外框顶边（Z 从这里往上飘）。耳环是细附件，不作为锚点。
    private static let sleepBodyTop: CGFloat = 9

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite)
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: Self.sleepBodyTop, t: t, size: size)
        }
    }

    /// 浮沉：两条不可通约的周期叠加，浮沉几乎不会正好重复；耳环与机身跟着浮、腿留在地上。
    /// 打盹时机身压暗（睡意），影子随浮沉放大一点。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let float = sin(t * 2 * .pi / 4.21) * 0.68 + sin(t * 2 * .pi / 6.85) * 0.36
        drawShadow(&context, sprite, width: 7 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(&context, sprite)
        drawEars(&context, sprite, dy: float)
        drawBody(&context, sprite, dy: float, shell: Self.shell.opacity(0.4))
    }

    // MARK: - 处理中：坐在键盘前敲字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 敲字：机身随按键起伏，每约 11.6 秒停一拍（像在等输出，不是一路敲个不停）；
    /// 耳环心每约 2.5 秒亮一下，键帽按拍号亮一格（确定性，不随机）。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pause = MascotMotion.quirk(t, cycle: 11.6, duration: 1.2, seed: 0x8F8)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - pause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * pause
        let keyPhase = Int(t / 0.1) % 6

        // 眨眼：每 3.2 秒闭 0.1 秒。
        let blinkPhase = t.truncatingRemainder(dividingBy: 3.2)
        let showEyes = !(blinkPhase > 1.5 && blinkPhase < 1.6)

        // 耳环里的信号：每约 2.5 秒亮 0.3 秒（在收数据）。
        let signalPhase = t.truncatingRemainder(dividingBy: 2.5)
        let earSignal = signalPhase > 2.0 && signalPhase < 2.3

        // 1. 影子（起伏越大越窄越淡）
        let shadowWidth: CGFloat = 8 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (8 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        // 2. 腿（在键盘后面）
        drawLegs(&context, sprite)

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

        // 4. 耳环 / 机身 / 眼睛（一起随按键起伏）
        drawEars(&context, sprite, dy: bounce, signal: earSignal)
        drawBody(&context, sprite, dy: bounce)
        if showEyes {
            drawEyes(&context, sprite, dy: bounce)
        }
    }

    // MARK: - 待审批：三连跳 + 闪色 + 瞪眼 + 惊叹号

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
    /// 影子留在地上（只有躯体与耳环跟着跳），跳起来时耳环与外框闪成警报橙、眼睛瞪大一倍，
    /// 惊叹号在头顶按跳跃高度做阻尼。
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

        // 上游的顶点会把整个角色抛出视口：整条曲线等比缩到「耳环顶边」不越出视口上边缘
        // （耳环与机身一起跳，所以截顶的基准是耳环顶边 y=5，而不是机身外框的 y=9）。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 起跳段整体左右抖一下（横向位移，与截顶无关）。
        let shake: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // 耳环与外框在常色与警报橙之间闪（确定性：拍号决定闪到哪一档）。
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0
        let earColor = flash > 0.5 ? Self.alert : Self.ear
        let shellColor = flash > 0.5 ? Self.alert : Self.shell

        // 眼睛瞪大一倍（1 块 → 2 块高）
        let eyeHeight: CGFloat = (pct > 0.03 && pct < 0.55) ? 2 : 1

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
        let shadowWidth: CGFloat = 8 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(4 + (8 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, rise)) * 0.04))))

        // 腿（钉在地上）
        drawLegs(&context, sprite)

        context.translateBy(x: shake * sprite.block, y: 0)
        drawEars(&context, sprite, dy: rise, color: earColor)
        drawBody(&context, sprite, dy: rise, shell: shellColor)
        drawEyes(&context, sprite, dy: rise, height: eyeHeight)
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

    /// 耳环：左右各一只中空方环（╭─╮ / ╰─╯），下面一根梗连到机身；`signal` 为真时环心亮一下。
    private func drawEars(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color? = nil, signal: Bool = false
    ) {
        let earColor = color ?? Self.ear
        // 左耳环：上横一块、左右各一块、下横一块
        context.fill(Path(sprite.r(3, 5, 3, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(3, 6, 1, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(5, 6, 1, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(3, 7, 3, 1, dy: dy)), with: .color(earColor))
        // 右耳环
        context.fill(Path(sprite.r(9, 5, 3, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(9, 6, 1, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(11, 6, 1, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(9, 7, 3, 1, dy: dy)), with: .color(earColor))
        // 连到机身的梗
        context.fill(Path(sprite.r(4, 8, 1, 1, dy: dy)), with: .color(earColor))
        context.fill(Path(sprite.r(10, 8, 1, 1, dy: dy)), with: .color(earColor))
        // 环心亮一下（处理中：在收数据）
        if signal {
            context.fill(Path(sprite.r(4, 6, 1, 1, dy: dy)), with: .color(Self.eye.opacity(0.5)))
            context.fill(Path(sprite.r(10, 6, 1, 1, dy: dy)), with: .color(Self.eye.opacity(0.5)))
        }
    }

    /// 机身：玫红外框 + 深色面屏；外框的下横杠与下巴最后画（压在面屏上）。
    private func drawBody(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        shell: Color? = nil
    ) {
        let bodyColor = shell ?? Self.shell
        context.fill(Path(sprite.r(2, 9, 11, 1, dy: dy)), with: .color(bodyColor))  // 上横杠
        context.fill(Path(sprite.r(2, 10, 2, 3, dy: dy)), with: .color(bodyColor))  // 左颊
        context.fill(Path(sprite.r(11, 10, 2, 3, dy: dy)), with: .color(bodyColor))  // 右颊
        context.fill(Path(sprite.r(4, 10, 7, 3, dy: dy)), with: .color(Self.face))  // 面屏
        context.fill(Path(sprite.r(2, 13, 11, 1, dy: dy)), with: .color(bodyColor))  // 下横杠
        context.fill(Path(sprite.r(4, 14, 7, 1, dy: dy)), with: .color(bodyColor))  // 下巴
    }

    /// 眼睛：面屏上的两颗金色方点；`height` 是瞪大 / 眨眼的开口高度。
    private func drawEyes(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color? = nil, height: CGFloat = 1
    ) {
        let eyeColor = color ?? Self.eye
        context.fill(Path(sprite.r(5, 10, 1, height, dy: dy)), with: .color(eyeColor))
        context.fill(Path(sprite.r(9, 10, 1, height, dy: dy)), with: .color(eyeColor))
    }

    /// 腿：两条压半透明的玫红短腿，底边钉在接地线上。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(6, 14.5, 1, 1.5)), with: .color(Self.shell.opacity(0.6)))
        context.fill(Path(sprite.r(8, 14.5, 1, 1.5)), with: .color(Self.shell.opacity(0.6)))
    }

    /// 影子：接地线上的一条黑带，`width` 是它的宽度（随浮沉伸缩）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 9,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15, width, 1)),
            with: .color(.black.opacity(opacity)))
    }
}