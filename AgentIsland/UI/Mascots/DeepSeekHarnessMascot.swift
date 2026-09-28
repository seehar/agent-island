//
//  DeepSeekHarnessMascot.swift
//  AgentIsland
//
//  DeepSeek Harness 的像素机箱。官方标记是一个圆角方框（框内一道抽屉式的横槽），
//  这里把它做成一台会打盹、会敲字、会跳起来喊你的小机箱：
//    · 空闲：趴下打盹（机身压扁、呼吸把顶盖撑起来），眼睛眯成一条缝偶尔翻动，
//      天线耷拉着，头顶飘三个 Z；
//    · 处理中：坐在键盘前打字——双臂绕肩转、按下的键亮一下，抽屉跟着节拍滑一下，
//      偶尔停下来一轮（天线竖起、眼睛睁大，像在等结果）；
//    · 待审批：三连跳（一跳比一跳矮）+ 瞪眼 + 天线竖起 + 头顶惊叹号 + 警报光晕。
//
//  这一枚是本仓自己画的（上游 CodeIsland 没有 DeepSeek Harness 的角色），
//  但沿用同一套口径：SVG 单位坐标（`MascotSprite`）、与其它角色同一套曲线（`MascotMotion`）。
//  场景视口：趴姿 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）。
//

import SwiftUI

struct DeepSeekHarnessMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// DeepSeek 的官方蓝做机身，压暗一档做底板与腿，亮档做顶盖 / 键帽 / 亮闪。
    /// 舞台底色是黑的，眼睛用深靛（与机身同色相、压到最暗），不引入第四种颜色。
    private static let shell = Color(mascotHex: 0x4D6BFE)
    private static let edge = Color(mascotHex: 0x2F49C9)
    private static let lit = Color(mascotHex: 0x8CA0FF)
    private static let eye = Color(mascotHex: 0x101A45)
    private static let alert = Color(mascotHex: 0xFF3D00)
    private static let kbBase = Color(mascotHex: 0x617080)
    private static let kbKey = Color(mascotHex: 0x99A8B8)

    /// 机身的几何（SVG 单位）：站立姿态下顶盖、底边、眼睛、天线。
    private static let bodyTop: CGFloat = 6
    private static let bodyBottom: CGFloat = 13
    private static let bodyLeft: CGFloat = 3
    private static let bodyWidth: CGFloat = 10

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 6, svgTop: 3)

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

    // MARK: - 空闲：趴着打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite, breathe: MascotMotion.breathe(t, period: 4.5))
            // 睡眠 Z 从机身顶盖上方升起（趴姿的机身顶边随呼吸在 8.7…9.5 之间）。
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 8, t: t, size: size)
        }
    }

    /// 趴姿：机身摊在地上，吸气把顶盖抬起一点、机身跟着变宽，眉毛线（眯着的眼睛）
    /// 偶尔翻动一下，天线耷拉在后脑。
    private func drawSleeping(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, breathe: CGFloat
    ) {
        let shadowWidth: CGFloat = 11 + breathe * 0.4
        context.fill(
            Path(sprite.r(0.5 + (14 - shadowWidth) / 2, 15, shadowWidth, 1)),
            with: .color(.black.opacity(0.35 + breathe * 0.08)))

        // 趴下的机身：高度随呼吸变化，底边钉在地上。
        let height: CGFloat = 5.5 + breathe * 0.8
        let width: CGFloat = 12 + breathe * 0.2
        context.fill(
            Path(sprite.r(1.5 - (width - 12) / 2, 15 - height, width, height)),
            with: .color(Self.shell))
        // 顶盖（亮档）：呼吸时露出一条亮边，像机器在冷启动时亮起来的灯带。
        context.fill(
            Path(sprite.r(1.5 - (width - 12) / 2, 15 - height, width, 0.8)),
            with: .color(Self.lit.opacity(0.55 + breathe * 0.35)))

        // 抽屉横槽（趴着时朝上）
        context.fill(Path(sprite.r(5, 12.4, 5, 1.1)), with: .color(Self.edge))

        // 眯着的眼睛：一条缝，偶尔翻动（梦里在跑活儿）。
        let rem = MascotMotion.quirk(t, cycle: 9.0, duration: 0.7, seed: 0x05E)
        let eyeHeight: CGFloat = 0.35 + rem * 0.5
        let eyeY: CGFloat = 15 - height + 2.2 - (eyeHeight - 0.35) / 2
        context.fill(Path(sprite.r(3, eyeY, 3, eyeHeight)), with: .color(Self.eye))
        context.fill(Path(sprite.r(9, eyeY, 3, eyeHeight)), with: .color(Self.eye))

        // 耷拉的天线：趴着时向侧面倒。
        context.fill(Path(sprite.r(11.4, 15 - height - 1.4, 2.6, 1)), with: .color(Self.edge))
        context.fill(Path(sprite.r(13.4, 15 - height - 2, 1, 1)), with: .color(Self.lit))
    }

    // MARK: - 处理中：坐在键盘前打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pause = MascotMotion.quirk(t, cycle: 11.0, duration: 1.4, seed: 0x7A9)
        let typing: CGFloat = 1.0 - pause

        let bounce =
            sin(t * 2 * .pi / 0.35) * 0.9 * typing
            + sin(t * 2 * .pi / 2.8) * 0.3 * (1 - typing)

        let strokeLeft = MascotMotion.typingBeat(t, cadence: 0.15, seed: 0x0DD1)
        let strokeRight = MascotMotion.typingBeat(t, cadence: 0.12, seed: 0x0DD2)
        let armLeftRaw = (strokeLeft.active ? sin(t * 2 * .pi / 0.15) : -0.6) * typing
        let armRightRaw = (strokeRight.active ? sin(t * 2 * .pi / 0.12) : -0.6) * typing
        let armLeft = armLeftRaw * 20 - 30
        let armRight = armRightRaw * 20 + 30

        // 抽屉：打字时按节拍滑进滑出（机器在忙）。
        let drawer = MascotMotion.pulse(t, period: 1.1) * 0.5

        // 眼睛：打字时眯着（顶盖压低），停下来那一轮睁大；叠自然眨眼。
        let eyeHeight: CGFloat =
            1.6 * (pause > 0.3 ? 1.0 : 0.45)
            * max(0.15, MascotMotion.blink(t, seed: 0x0DD3))
        let keyRows = 3
        let keyColumns = 6

        // 1. 影子
        context.fill(
            Path(sprite.r(3 + 0.5, 15, 9 - abs(bounce) * 0.3, 1)),
            with: .color(.black.opacity(max(0.1, 0.4 - abs(bounce) * 0.03))))

        // 2. 短腿（在键盘后面）
        for x: CGFloat in [4, 6, 9.5, 11.5] {
            context.fill(Path(sprite.r(x, 13, 1, 2)), with: .color(Self.edge))
        }

        // 3. 机身
        context.fill(
            Path(sprite.r(Self.bodyLeft, Self.bodyTop, Self.bodyWidth, 7, dy: bounce)),
            with: .color(Self.shell))
        context.fill(
            Path(sprite.r(Self.bodyLeft, Self.bodyTop, Self.bodyWidth, 0.8, dy: bounce)),
            with: .color(Self.lit.opacity(pause > 0.3 ? 1 : 0.7)))
        // 抽屉横槽（滑进滑出）
        context.fill(
            Path(sprite.r(5, 11.2, 6, 1.2 + drawer, dy: bounce)), with: .color(Self.edge))

        // 4. 眼睛
        let eyeY: CGFloat = 8.2 + (1.6 - eyeHeight) / 2
        context.fill(Path(sprite.r(4.6, eyeY, 2, eyeHeight, dy: bounce)), with: .color(Self.eye))
        context.fill(Path(sprite.r(9.4, eyeY, 2, eyeHeight, dy: bounce)), with: .color(Self.eye))

        // 5. 天线：打字时竖直，停下来时竖得更高
        context.fill(
            Path(sprite.r(7.6, 4.2 - pause * 0.8, 0.9, 1.8 + pause * 0.8, dy: bounce)),
            with: .color(Self.edge))
        context.fill(
            Path(sprite.r(7.1, 3.4 - pause * 0.8, 1.9, 1, dy: bounce)),
            with: .color(Self.lit))

        // 6. 键盘 + 键帽
        context.fill(Path(sprite.r(-0.5, 11.8, 16, 3.5)), with: .color(Self.kbBase))
        for row in 0..<keyRows {
            for column in 0..<keyColumns {
                context.fill(
                    Path(
                        sprite.r(0.3 + CGFloat(column) * 2.5, 12.2 + CGFloat(row) * 1.0, 2.0, 0.7)),
                    with: .color(Self.kbKey))
            }
        }
        // 按下的键亮一下（左右手各按各的槽位，确定性）
        let leftColumn = Int(MascotMotion.hash01(strokeLeft.slot, seed: 0x0DD4) * 3)
        let rightColumn = 3 + Int(MascotMotion.hash01(strokeRight.slot, seed: 0x0DD5) * 3)
        if strokeLeft.active && armLeftRaw > 0.3 {
            context.fill(
                Path(
                    sprite.r(
                        0.3 + CGFloat(leftColumn) * 2.5, 12.2 + CGFloat(leftColumn % keyRows) * 1.0,
                        2.0, 0.7)),
                with: .color(Self.lit.opacity(0.9)))
        }
        if strokeRight.active && armRightRaw > 0.3 {
            context.fill(
                Path(
                    sprite.r(
                        0.3 + CGFloat(rightColumn) * 2.5,
                        12.2 + CGFloat(rightColumn % keyRows) * 1.0, 2.0, 0.7)),
                with: .color(Self.lit.opacity(0.9)))
        }

        // 7. 双臂绕肩旋转
        context.fill(
            sprite.rotatedRect(
                x: 1.4, y: 9, width: 1.6, height: 1.6, pivotX: 3, pivotY: 10, angle: armLeft,
                dy: bounce),
            with: .color(Self.shell))
        context.fill(
            sprite.rotatedRect(
                x: 13, y: 9, width: 1.6, height: 1.6, pivotX: 13, pivotY: 10, angle: armRight,
                dy: bounce),
            with: .color(Self.shell))
    }

    // MARK: - 待审批：三连跳 + 瞪眼 + 惊叹号

    private var alertScene: some View {
        ZStack {
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

    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        // 三连跳：一跳比一跳矮，落地时压扁。位移按视口高度截顶（身体不许飞出画布）。
        let jumpY = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: -1),
                (at: 0.15, value: 1.2), (at: 0.175, value: -8), (at: 0.20, value: -8),
                (at: 0.25, value: 1.2), (at: 0.275, value: -6), (at: 0.30, value: -6),
                (at: 0.35, value: 1.0), (at: 0.375, value: -4), (at: 0.40, value: -4),
                (at: 0.45, value: 0.8), (at: 0.475, value: -2), (at: 0.50, value: -2),
                (at: 0.55, value: 0.4), (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)
        let rise = jumpY * Self.alertSpec.riseFactor

        let scaleX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.05 : 1.0
        let scaleY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.04 : 1.0

        let bangOpacity = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 1), (at: 0.10, value: 1),
                (at: 0.55, value: 1), (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)
        let bangScale = MascotMotion.lerp(
            [
                (at: 0, value: 0.3), (at: 0.03, value: 1.3), (at: 0.10, value: 1.0),
                (at: 0.55, value: 1.0), (at: 0.62, value: 0.6), (at: 1.0, value: 0.6),
            ], at: pct)

        // 影子留在地上，跳得越高越窄越淡。
        let shadowWidth: CGFloat = 9 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(3.5 + (9 - shadowWidth) / 2, 15, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.5 - abs(min(0, rise)) * 0.04))))

        // 腿（钉在地上）
        for x: CGFloat in [4, 6, 9.5, 11.5] {
            context.fill(Path(sprite.r(x, 13, 1, 2)), with: .color(Self.edge))
        }

        // 机身（压扁 / 拉长，从底边往上长）
        let width = 10 * scaleX
        let height = 7 * scaleY
        context.fill(
            Path(
                sprite.r(
                    Self.bodyLeft - (width - 10) / 2, Self.bodyBottom - height, width, height,
                    dy: rise)),
            with: .color(Self.shell))
        context.fill(
            Path(
                sprite.r(
                    Self.bodyLeft - (width - 10) / 2, Self.bodyBottom - height, width, 0.8,
                    dy: rise)),
            with: .color(Self.lit))
        context.fill(Path(sprite.r(5, 11.2, 6, 1.2, dy: rise)), with: .color(Self.edge))

        // 瞪大的眼睛（刚被惊到时更大更靠上）
        let startled = pct > 0.03 && pct < 0.15
        let eyeHeight: CGFloat = startled ? 2.4 : 1.8
        let eyeY: CGFloat = 8.2 - (eyeHeight - 1.6) / 2 - (startled ? 0.3 : 0)
        context.fill(Path(sprite.r(4.6, eyeY, 2, eyeHeight, dy: rise)), with: .color(Self.eye))
        context.fill(Path(sprite.r(9.4, eyeY, 2, eyeHeight, dy: rise)), with: .color(Self.eye))

        // 天线竖起（越吃惊越高）
        let antennaLift: CGFloat = startled ? 1.2 : 0.6
        context.fill(
            Path(sprite.r(7.6, 4.2 - antennaLift, 0.9, 1.8 + antennaLift, dy: rise)),
            with: .color(Self.edge))
        context.fill(
            Path(sprite.r(7.1, 3.4 - antennaLift, 1.9, 1, dy: rise)), with: .color(Self.lit))

        // 双臂扬起
        let armAngle = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: 30),
                (at: 0.15, value: 40), (at: 0.20, value: 150), (at: 0.25, value: 110),
                (at: 0.30, value: 135), (at: 0.35, value: 95), (at: 0.40, value: 110),
                (at: 0.45, value: 75), (at: 0.50, value: 75), (at: 0.55, value: 35),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)
        context.fill(
            sprite.rotatedRect(
                x: 1.4, y: 9, width: 1.6, height: 1.6, pivotX: 3, pivotY: 10, angle: armAngle,
                dy: rise),
            with: .color(Self.shell))
        context.fill(
            sprite.rotatedRect(
                x: 13, y: 9, width: 1.6, height: 1.6, pivotX: 13, pivotY: 10, angle: -armAngle,
                dy: rise),
            with: .color(Self.shell))

        // 惊叹号
        if bangOpacity > 0.01 {
            let width: CGFloat = 2 * bangScale
            let x: CGFloat = 13
            let y: CGFloat = 4.5 + rise * 0.15
            context.fill(
                Path(sprite.r(x, y, width, 3.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(x, y + 4.0 * bangScale, width, 1.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
        }
    }
}
