//
//  QoderMascot.swift
//  AgentIsland
//
//  文件：AgentIsland/UI/Mascots/QoderMascot.swift
//
//  Qoder 的像素聊天气泡机器人：主体是青柠绿（品牌色 #2ADB5C）的圆角气泡，用十行「整块」
//  自下而上收边堆出来（第 11 行最宽、上下各收两行，因此是个圆角方气泡），脸上挖两只黑点眼
//  与一条微笑弧。移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/QoderView.swift`，坐标常量与配色逐值保留：
//    · 空闲：趴着打盹——气泡随两条不同周期的正弦缓慢浮沉，影子跟着收放，眼睛眯成缝、压淡，
//      也不画笑脸，头顶飘三个 Z；
//    · 处理中：坐在键盘后打字——气泡随按键起伏、按到的那一格键亮一下、笑脸始终挂着，
//      眼睛随自然眨眼开合，每约 11 秒歇一拍（那是在读输出，不是不停敲键）；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮）+ 左右抖 + 落地压扁 / 离地拉长 + 瞪眼
//      + 头顶惊叹号；影子与腿留在地上，只有气泡与惊叹号跟着跳。
//
//  场景视口（SVG 单位）：打盹 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）
//  ——视口不同只影响这一套场景里角色的位置与大小。
//

import SwiftUI

struct QoderMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 配色取自上游：品牌青柠绿、压暗一档的青柠绿（腿用）、挖空的黑脸（眼与笑弧）、
    /// 警报橙，以及键盘的底色、键帽与亮键（亮键与主体同色）。
    private static let bodyC = Color(mascotHex: 0x2ADB5C)
    private static let bodyDk = Color(red: 0.12, green: 0.65, blue: 0.28)
    private static let faceC = Color.black
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.10, green: 0.18, blue: 0.12)
    private static let kbKey = Color(red: 0.20, green: 0.38, blue: 0.24)
    private static let kbHi = Color(red: 0.165, green: 0.859, blue: 0.361)

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

    // MARK: - 空闲：趴着打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            // 两条不通约的浮沉周期：浮姿几乎不重复，各枚角色的节拍也各不相同，
            // 多会话并排时不会同步（上游 #15）。
            let float = sin(t * 2 * .pi / 4.42) * 0.68 + sin(t * 2 * .pi / 6.96) * 0.36
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite, float: float)
            // Z 从气泡顶边（行表最上面一行 y=5）上方升起，不压到脸上。
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 5, t: t, size: size)
        }
    }

    /// 趴姿：影子随浮沉收放，两条腿钉在地上，气泡跟着浮；眼睛眯成缝、压淡，笑脸也不画。
    private func drawSleeping(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, float: CGFloat
    ) {
        drawShadow(&context, sprite, width: 7 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(&context, sprite)
        drawBubble(&context, sprite, dy: float)
        drawQFace(
            &context, sprite, dy: float, color: Self.faceC.opacity(0.5), eyeScale: 0.3,
            showSmile: false)
    }

    // MARK: - 处理中：坐在键盘后打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 打字：气泡随按键快速起伏，歇拍时换成缓慢的呼吸摆动；亮起的那一格键随拍子移动，
    /// 笑脸始终挂着，眼睛随自然眨眼开合。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        // 每约 11.4 秒歇一拍：起伏收缓，像在坐着读输出。
        let workPause = MascotMotion.quirk(t, cycle: 11.4, duration: 1.2, seed: 0x1BC)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let blink = max(0.1, MascotMotion.blink(t, seed: 0x1BD))
        let keyPhase = Int(t / 0.1) % 6

        // 1. 影子（起伏越大越窄越淡）
        let shadowWidth: CGFloat = 8 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (8 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        // 2. 腿（在键盘后面）
        drawLegs(&context, sprite)

        // 3. 键盘 + 2 行 × 6 列的键帽
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 13.5 + CGFloat(row) * 1.2
            for column in 0..<6 {
                let keyX = 0.5 + CGFloat(column) * 2.4
                context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
            }
        }
        // 亮起的那一格随拍子（确定性：同一 `t` 永远亮同一格）
        let flashColumn = keyPhase % 6
        let flashRow = keyPhase / 3
        context.fill(
            Path(
                sprite.r(
                    0.5 + CGFloat(flashColumn) * 2.4, 13.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
            with: .color(Self.kbHi.opacity(0.9)))

        // 4. 气泡与脸
        drawBubble(&context, sprite, dy: bounce)
        drawQFace(&context, sprite, dy: bounce, eyeScale: blink)
    }

    // MARK: - 待审批：三连跳 + 抖 + 惊叹号

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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。跳起来时左右抖、
    /// 落地压扁离地拉长、眼睛瞪大；影子与腿留在地上，只有气泡与惊叹号跟着跳。
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

        // 落地压扁（`jumpY > 0.5` 那两行）用原始关键帧值，其余位移用截顶后的 `rise`。
        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0

        // 上游的顶点会把身体整个抛出视口（实拍只剩腿与影子）：整条曲线等比缩到身体
        // 顶边不越出视口上边缘——气泡的顶边在 y=5，视口上边缘在 y=3。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 左右抖：只在起跳那一段抖（`sin(pct * 80)` 是 `t` 的纯函数，不是随机数）。
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

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

        // 气泡与脸整体左右抖；眼睛在刚被惊到时瞪大。
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawBubble(&context, sprite, dy: rise, squashX: squashX, squashY: squashY)
        drawQFace(&context, sprite, dy: rise, eyeScale: (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0)
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

    // MARK: - 部件

    /// 气泡主体：十行自下而上收边的整块（第 11 行最宽 → 圆角方气泡）。
    /// `squashX` / `squashY` 是落地压扁用的整体缩放，横轴绕气泡中线（7.5）缩放，
    /// 纵轴绕第 10 行缩放（底边因此不动）。
    private func drawBubble(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        squashX: CGFloat = 1, squashY: CGFloat = 1
    ) {
        let cx: CGFloat = 7.5

        func squashed(_ x: CGFloat, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
            let centerX = cx + (x - cx) * squashX
            return (centerX, width * squashX)
        }

        // 气泡的行表（圆角方气泡，左右对称）
        let rows: [(y: CGFloat, x: CGFloat, width: CGFloat)] = [
            (14, 4, 7),  // 底边（收窄，左右对称）
            (13, 2, 11),
            (12, 1, 13),
            (11, 1, 13),  // 最宽
            (10, 1, 13),
            (9, 1, 13),
            (8, 1, 13),
            (7, 2, 11),  // 往上收边
            (6, 3, 9),
            (5, 4, 7),  // 顶边
        ]

        for row in rows {
            let squashedX = squashed(row.x, width: row.width)
            let rowHeight: CGFloat = 1 * squashY
            context.fill(
                Path(
                    sprite.r(
                        squashedX.x, row.y * squashY + (1 - squashY) * 10, squashedX.width,
                        rowHeight, dy: dy)),
                with: .color(Self.bodyC))
        }
    }

    /// 脸：两只黑点眼 + 一条微笑弧（睡着时不画笑脸，眼睛也眯小）。
    private func drawQFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color = Self.faceC, eyeScale: CGFloat = 1.0, showSmile: Bool = true
    ) {
        // 两只点眼
        let eyeHeight: CGFloat = 1.5 * eyeScale
        let eyeY: CGFloat = 9.0 + (1.5 - eyeHeight) / 2
        context.fill(
            Path(sprite.r(4, eyeY, 1.2, max(0.3, eyeHeight), dy: dy)), with: .color(color))
        context.fill(
            Path(sprite.r(9.8, eyeY, 1.2, max(0.3, eyeHeight), dy: dy)), with: .color(color))

        // 微笑弧（醒着时才画）：中间一段长、两端各一段短，向下收成一条弧
        if showSmile {
            context.fill(Path(sprite.r(5, 11.5, 1, 0.8, dy: dy)), with: .color(color))
            context.fill(Path(sprite.r(6, 12, 3, 0.8, dy: dy)), with: .color(color))
            context.fill(Path(sprite.r(9, 11.5, 1, 0.8, dy: dy)), with: .color(color))
        }
    }

    /// 影子（宽 `width`、以气泡中线为中心）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 9,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15.5, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两条腿：气泡下方两根小立柱（压暗一档的青柠绿），钉在地上不跟着跳。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(5, 14.5, 1, 1.5)), with: .color(Self.bodyDk))
        context.fill(Path(sprite.r(9, 14.5, 1, 1.5)), with: .color(Self.bodyDk))
    }
}