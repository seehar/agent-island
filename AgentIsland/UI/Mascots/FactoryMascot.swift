//
//  FactoryMascot.swift
//  AgentIsland
//
//  Factory（droid）的像素角色 DroidBot：一台方胖的工业机器人——退台的头壳、正中一只发光的
//  独眼、头上一根天线、胸口压深一档的铆钉胸甲、两侧伸出的机械臂，招牌配色是工锈橙
//  （#D56A26）配暖金属灰。三套场景各自在做什么：
//    · 空闲：蹲着打盹，整台机器随呼吸上下 0.4 块（机械的慢节奏，不是生物式的起伏），
//      独眼像断电一样每 3 秒暗 0.5 秒，头顶飘三个 Z；
//    · 处理中：在键盘后面砸键，整台机器随按键起落（每约 11 秒停一拍读输出），
//      独眼随眨眼开合、按下的那颗键亮成锈橙；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮），跳起来时独眼闪红并放大、头顶惊叹号、
//      横向随节拍抖一抖。
//
//  场景视口（SVG 单位）：三套都是 16×16（上边缘 y=2）——视口只决定这一套场景里角色的位置
//  与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的 `Sources/CodeIsland/DroidView.swift`，
//  坐标常量与配色逐值保留。
//

import SwiftUI

struct FactoryMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（机身橙）。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = shell

    /// 配色：锈橙的头壳与身子、压深一档的胸甲、暖灰的金属件、金色的独眼与信号帽，键盘三档暖灰。
    private static let shell = Color(mascotHex: 0xD56A26)
    private static let shellDark = Color(red: 0.65, green: 0.32, blue: 0.12)
    private static let metal = Color(red: 0.40, green: 0.37, blue: 0.34)
    private static let eye = Color(mascotHex: 0xE3992A)
    private static let alert = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.15, green: 0.13, blue: 0.12)
    private static let kbKey = Color(red: 0.32, green: 0.28, blue: 0.25)
    private static let kbFlash = Color(mascotHex: 0xD56A26)

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 4, svgTop: 2, overshoot: 0)

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

    /// 机器人本体：方胖的身子 + 退台的头壳 + 天线 + 铆钉胸甲 + 两侧机械臂。
    /// `dy` 是整块的纵向位移（呼吸、按键起伏、起跳都靠它），压扁 / 拉长只改宽高。
    private func drawRobot(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        squashX: CGFloat = 1, squashY: CGFloat = 1
    ) {
        let centerX: CGFloat = 7.5

        // 身子（方块）
        let bodyWidth: CGFloat = 9 * squashX
        let bodyHeight: CGFloat = 6 * squashY
        let bodyLeft = centerX - bodyWidth / 2
        let bodyTop: CGFloat = 9 + (6 - bodyHeight)
        context.fill(
            Path(sprite.r(bodyLeft, bodyTop, bodyWidth, bodyHeight, dy: dy)),
            with: .color(Self.shell))

        // 头壳（顶上小一号的方块）
        let headWidth: CGFloat = 7 * squashX
        let headHeight: CGFloat = 3 * squashY
        let headLeft = centerX - headWidth / 2
        let headTop = bodyTop - headHeight + 0.5
        context.fill(
            Path(sprite.r(headLeft, headTop, headWidth, headHeight, dy: dy)),
            with: .color(Self.shell))

        // 天线：一根金属杆，顶上一块金色信号帽
        let antennaLeft = centerX - 0.5
        context.fill(
            Path(sprite.r(antennaLeft, headTop - 2, 1, 2, dy: dy)),
            with: .color(Self.metal))
        context.fill(
            Path(sprite.r(antennaLeft - 0.5, headTop - 2.5, 2, 1, dy: dy)),
            with: .color(Self.eye))

        // 胸甲（压深一档的内嵌方块）+ 左右两颗铆钉
        let plateWidth: CGFloat = 5 * squashX
        let plateHeight: CGFloat = 3 * squashY
        let plateLeft = centerX - plateWidth / 2
        context.fill(
            Path(sprite.r(plateLeft, bodyTop + 1, plateWidth, plateHeight, dy: dy)),
            with: .color(Self.shellDark))
        context.fill(
            Path(sprite.r(plateLeft + 0.5, bodyTop + 1.5, 0.8, 0.8, dy: dy)),
            with: .color(Self.metal))
        context.fill(
            Path(sprite.r(plateLeft + plateWidth - 1.3, bodyTop + 1.5, 0.8, 0.8, dy: dy)),
            with: .color(Self.metal))

        // 两侧机械臂
        context.fill(
            Path(sprite.r(bodyLeft - 1.5, bodyTop + 1, 1.5, 4 * squashY, dy: dy)),
            with: .color(Self.metal))
        context.fill(
            Path(sprite.r(bodyLeft + bodyWidth, bodyTop + 1, 1.5, 4 * squashY, dy: dy)),
            with: .color(Self.metal))
    }

    /// 独眼：两只发光方块（`scale` 是睁眼程度，警报时颜色换成红）。
    private func drawEyes(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color = Self.eye, scale: CGFloat = 1.0
    ) {
        let eyeWidth: CGFloat = 1.5
        let eyeHeight: CGFloat = 1.2 * scale
        let eyeY: CGFloat = 8.0 + (1.2 - eyeHeight) / 2
        context.fill(
            Path(sprite.r(4.8, eyeY, eyeWidth, max(0.2, eyeHeight), dy: dy)),
            with: .color(color))
        context.fill(
            Path(sprite.r(8.7, eyeY, eyeWidth, max(0.2, eyeHeight), dy: dy)),
            with: .color(color))
    }

    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite,
        width: CGFloat = 9, opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 16, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两只方块脚。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(4.5, 14.5, 2, 1.5)), with: .color(Self.metal))
        context.fill(Path(sprite.r(8.5, 14.5, 2, 1.5)), with: .color(Self.metal))
    }

    // MARK: - 空闲：蹲着打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 16, svgHeight: 16, svgTop: 2)

            // 呼吸：5 秒一轮，幅度只有 ±0.4 块——机械的慢节奏。
            let breathe = sin(t.truncatingRemainder(dividingBy: 5.0) / 5.0 * .pi * 2) * 0.4
            // 独眼像断电一样：每 3 秒里亮 2.5 秒。
            let eyeOn = t.truncatingRemainder(dividingBy: 3.0) < 2.5

            drawShadow(&context, sprite, width: 8, opacity: 0.2)
            drawLegs(&context, sprite)
            drawRobot(&context, sprite, dy: breathe)
            if eyeOn {
                drawEyes(&context, sprite, dy: breathe, color: Self.eye.opacity(0.3), scale: 0.4)
            }
            // Z 锚在头壳顶边（6.5 = 身顶 9 − 头高 3 + 0.5），不取天线：细附件的尖端会把 Z
            // 顶出画布。呼吸只让机身上下 0.4 块，锚点用静息值就够。
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: 6.5, t: t, size: size, color: Self.sleepZ)
        }
    }

    // MARK: - 处理中：在键盘后面砸键

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 16, svgTop: 2))
        }
    }

    /// 打字：整台机器随按键起落，按下的键闪一下；每约 11 秒停一拍——那一下在「读输出」，
    /// 而不是一直砸键，节奏因此是一阵一阵的。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let workPause = MascotMotion.quirk(t, cycle: 10.6, duration: 1.2, seed: 0x296)
        let bounce =
            sin(t * 2 * .pi / 0.5) * 0.8 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let blink = max(0.1, MascotMotion.blink(t, seed: 0x297))
        let keyPhase = Int(t / 0.12) % 6  // 比别的角色稍慢的打字速度

        let shadowWidth: CGFloat = 9 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(3.5 + (9 - shadowWidth) / 2, 17, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        drawLegs(&context, sprite)

        // 键盘（画在腿前面，把腿挡住）
        context.fill(Path(sprite.r(0, 15, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 15.5 + CGFloat(row) * 1.2
            for column in 0..<6 {
                let keyX = 0.5 + CGFloat(column) * 2.4
                context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
            }
        }
        let flashColumn = keyPhase % 6
        let flashRow = keyPhase / 3
        context.fill(
            Path(sprite.r(0.5 + CGFloat(flashColumn) * 2.4, 15.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
            with: .color(Self.kbFlash.opacity(0.9)))

        drawRobot(&context, sprite, dy: bounce)
        drawEyes(&context, sprite, dy: bounce, scale: blink)
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
                drawAlert(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 16, svgTop: 2))
            }
        }
        .frame(width: size, height: size)
    }

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。
    /// 影子留在地上（只有身躯与眼睛跟着跳），惊叹号的位置按跳跃高度做阻尼。
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
        // 16×16 的视口在方形画布里没有纵向余量：越顶余量必须取 0，否则顶点会把天线帽削平。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 落地瞬间压扁、离地时拉长。
        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0
        // 横向抖动：只在起跳那一段，随节拍来回。
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // 警报里独眼闪红（随节拍明暗交替）。
        let eyeFlash = (pct > 0.03 && pct < 0.55 && sin(pct * 20) > 0)
        let eyeColor = eyeFlash ? Self.alert : Self.eye

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
        let shadowWidth: CGFloat = 9 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(3.5 + (9 - shadowWidth) / 2, 17, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, rise)) * 0.04))))

        // 腿（钉在地上）
        drawLegs(&context, sprite)

        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawRobot(&context, sprite, dy: rise, squashX: squashX, squashY: squashY)
        drawEyes(
            &context, sprite, dy: rise, color: eyeColor,
            scale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
        context.translateBy(x: -shakeX * sprite.block, y: 0)

        // 惊叹号：在头顶上方，位移只有跳跃的 15%（不会飞出画布）。
        if bangOpacity > 0.01 {
            let width: CGFloat = 2 * bangScale
            let x: CGFloat = 13
            let y: CGFloat = 3 + rise * 0.15
            context.fill(
                Path(sprite.r(x, y, width, 3.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
            context.fill(
                Path(sprite.r(x, y + 4.0 * bangScale, width, 1.5 * bangScale)),
                with: .color(Self.alert.opacity(bangOpacity)))
        }
    }
}