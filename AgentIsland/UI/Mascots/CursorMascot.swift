//
//  CursorMascot.swift
//  AgentIsland
//
//  文件：AgentIsland/UI/Mascots/CursorMascot.swift
//
//  Cursor 的像素宝石机器人：官方标记是一枚带斜向亮面的多面体，这里画成等距视角的六边形
//  宝石——左上是压暗的面、右上是中间档的面、底部是最暗的面，右上斜切一块亮面当招牌高光，
//  外圈再描一道细亮边（黑底上要看得见）。移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）
//  的 `Sources/CodeIsland/CursorView.swift`，坐标常量与配色逐值保留：
//    · 空闲：趴着打盹——宝石随两条不同周期的正弦缓慢浮沉，影子跟着收放，眼睛眯成缝、颜色
//      也压淡，头顶飘三个 Z；
//    · 处理中：坐在键盘后打字——身体随按键起伏、斜向高光随呼吸明暗脉动、按到的那一格键
//      亮一下、眼睛随自然眨眼开合，每约 11 秒歇一拍（那是在读输出，不是不停敲键）；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮）+ 左右抖 + 高光狂闪 + 瞪眼（眼睛还会闪红）
//      + 头顶惊叹号；影子与腿留在地上，只有身体与惊叹号跟着跳。
//
//  场景视口（SVG 单位）：打盹 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）
//  ——视口不同只影响这一套场景里角色的位置与大小。
//

import SwiftUI

struct CursorMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 配色取自上游：宝石三档暖暗色（左面、右面、底面）、亮面与描边用近白，
    /// 以及警报橙、键盘的两档底色与一格键帽。
    private static let darkC = Color(mascotHex: 0x14120B)
    private static let midC = Color(mascotHex: 0x26251E)
    private static let lightC = Color(mascotHex: 0xEDECEC)
    private static let edgeC = Color(red: 0.30, green: 0.28, blue: 0.24)
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.12, green: 0.11, blue: 0.08)
    private static let kbKey = Color(red: 0.30, green: 0.28, blue: 0.22)
    private static let kbHi = Color(red: 0.93, green: 0.93, blue: 0.93)

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

    // MARK: - 空闲：趴着打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            // 两条不通约的浮沉周期：浮姿几乎不重复，各枚角色的节拍也各不相同，
            // 多会话并排时不会同步（上游 #15）。
            let float = sin(t * 2 * .pi / 4.32) * 0.51 + sin(t * 2 * .pi / 6.29) * 0.27
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite, float: float)
            // Z 从宝石顶顶点（cy - ry = 5.5）上方升起，不压到身上。
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 5.5, t: t, size: size)
        }
    }

    /// 趴姿：影子随浮沉收放，两条腿钉在地上，宝石跟着浮；眼睛眯成缝、颜色也压淡（睡着了）。
    private func drawSleeping(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, float: CGFloat
    ) {
        drawShadow(&context, sprite, width: 7 + abs(float) * 0.2, opacity: 0.2)
        drawLegs(&context, sprite)
        drawGem(&context, sprite, dy: float)
        drawEyes(&context, sprite, dy: float, scale: 0.3, color: Self.lightC.opacity(0.4))
    }

    // MARK: - 处理中：坐在键盘后打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 打字：身体随按键快速起伏，歇拍时换成缓慢的呼吸摆动；高光随呼吸明暗脉动，
    /// 亮起的那一格键随拍子移动，眼睛随自然眨眼开合。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        // 每约 11 秒歇一拍：起伏收缓，像在坐着读输出。
        let workPause = MascotMotion.quirk(t, cycle: 11.0, duration: 1.2, seed: 0xE2E)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let shimmer = sin(t * 2 * .pi / 1.5) * 0.5 + 0.5  // 斜向高光的呼吸
        let blink = max(0.1, MascotMotion.blink(t, seed: 0xE2F))
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

        // 4. 身体与眼睛
        drawGem(&context, sprite, dy: bounce, shimmer: shimmer)
        drawEyes(&context, sprite, dy: bounce, scale: blink)
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
    /// 高光狂闪、眼睛瞪大并闪红；影子与腿留在地上，只有身体与惊叹号跟着跳。
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

        // 上游的顶点会把身体整个抛出视口（实拍只剩腿与影子）：整条曲线等比缩到身体
        // 顶边不越出视口上边缘——宝石的顶顶点在 y=5.5，视口上边缘在 y=3。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 左右抖：只在起跳那一段抖（`sin(pct * 80)` 是 `t` 的纯函数，不是随机数）。
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        // 高光在警报段狂闪
        let shimmer: CGFloat = (pct > 0.03 && pct < 0.55) ? sin(pct * 30) * 0.5 + 0.5 : 0

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

        // 身体与眼睛整体左右抖；眼睛在刚被惊到时瞪大，警报段还会闪红。
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawGem(&context, sprite, dy: rise, shimmer: shimmer)
        let eyeColor: Color =
            (pct > 0.03 && pct < 0.55 && sin(pct * 25) > 0) ? Self.alertC : Self.lightC
        drawEyes(
            &context, sprite, dy: rise, scale: (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0,
            color: eyeColor)
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

    /// 宝石主体：等距视角的六边形，三个面各一档暗色，右上斜切一块招牌亮面，外圈一道细亮边。
    private func drawGem(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        shimmer: CGFloat = 0
    ) {
        // 六边形顶点（平顶朝向，中心在 7.5, 10）
        let cx: CGFloat = 7.5
        let cy: CGFloat = 10.0
        let rx: CGFloat = 5.0
        let ry: CGFloat = 4.5  // 比高略宽

        let top = sprite.point(cx, cy - ry, dy: dy)  // 顶顶点
        let topR = sprite.point(cx + rx, cy - ry * 0.45, dy: dy)  // 右上
        let botR = sprite.point(cx + rx, cy + ry * 0.45, dy: dy)  // 右下
        let bot = sprite.point(cx, cy + ry, dy: dy)  // 底顶点
        let botL = sprite.point(cx - rx, cy + ry * 0.45, dy: dy)  // 左下
        let topL = sprite.point(cx - rx, cy - ry * 0.45, dy: dy)  // 左上
        let center = sprite.point(cx, cy, dy: dy)

        // 左面（压暗）
        var leftFacet = Path()
        leftFacet.move(to: topL)
        leftFacet.addLine(to: top)
        leftFacet.addLine(to: center)
        leftFacet.addLine(to: botL)
        leftFacet.closeSubpath()
        context.fill(leftFacet, with: .color(Self.darkC))

        // 右面（中间档）
        var rightFacet = Path()
        rightFacet.move(to: top)
        rightFacet.addLine(to: topR)
        rightFacet.addLine(to: botR)
        rightFacet.addLine(to: center)
        rightFacet.closeSubpath()
        context.fill(rightFacet, with: .color(Self.midC))

        // 底面（最暗的暖灰）
        var bottomFacet = Path()
        bottomFacet.move(to: botL)
        bottomFacet.addLine(to: center)
        bottomFacet.addLine(to: botR)
        bottomFacet.addLine(to: bot)
        bottomFacet.closeSubpath()
        context.fill(bottomFacet, with: .color(Self.edgeC))

        // 斜向亮面：Cursor 的招牌元素，从右上往中间切的一角，亮度随 `shimmer` 脉动。
        let highlightAlpha = 0.7 + shimmer * 0.3
        var highlight = Path()
        highlight.move(to: sprite.point(cx + 1, cy - ry + 0.5, dy: dy))
        highlight.addLine(to: sprite.point(cx + rx - 0.5, cy - ry * 0.45 + 0.3, dy: dy))
        highlight.addLine(to: sprite.point(cx + 0.5, cy + 0.5, dy: dy))
        highlight.closeSubpath()
        context.fill(highlight, with: .color(Self.lightC.opacity(highlightAlpha)))

        // 描边：黑底上要看得见轮廓
        var outline = Path()
        outline.move(to: top)
        outline.addLine(to: topR)
        outline.addLine(to: botR)
        outline.addLine(to: bot)
        outline.addLine(to: botL)
        outline.addLine(to: topL)
        outline.closeSubpath()
        context.stroke(outline, with: .color(Self.lightC.opacity(0.35)), lineWidth: sprite.block * 0.5)
    }

    /// 两只眼睛：贴在宝石面上的两个点，大小随眨眼 / 瞪眼缩放，颜色可换（警报时闪红）。
    private func drawEyes(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        scale: CGFloat = 1.0, color: Color = Self.lightC
    ) {
        let eyeHeight: CGFloat = 1.3 * scale
        let eyeY: CGFloat = 9.5 + (1.3 - eyeHeight) / 2
        context.fill(
            Path(sprite.r(4.2, eyeY, 1.3, max(0.3, eyeHeight), dy: dy)), with: .color(color))
        context.fill(
            Path(sprite.r(6.8, eyeY, 1.3, max(0.3, eyeHeight), dy: dy)), with: .color(color))
    }

    /// 影子（宽 `width`、以宝石中线为中心）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 8,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15.5, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两条腿：宝石下方两根小立柱，钉在地上不跟着跳。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(5.5, 14.5, 1, 1.5)), with: .color(Self.edgeC))
        context.fill(Path(sprite.r(8.5, 14.5, 1, 1.5)), with: .color(Self.edgeC))
    }
}