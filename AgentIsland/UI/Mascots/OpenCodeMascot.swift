//
//  OpenCodeMascot.swift
//  AgentIsland
//
//  OpenCode 的像素角色 OpBot：一块深灰的终端方块，正面用浅灰的 `{ }` 当眼睛、
//  中间一颗光标点。整套配色是 OpenCode 的单色体系（深灰机身 + 浅灰描边 + 近白脸）。
//    · 空闲：方块在地面上轻轻漂浮，两条短腿摊着，脸压暗、括弧眼睛眯成一条缝，
//      头顶从机身顶边上方飘出三枚 Z；
//    · 处理中：方块蹲在键盘后面打字，随按键上下起伏，键帽每 0.1 秒换一格亮起来，
//      每约 11 秒停一拍（像在读输出，而不是一直敲）；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮），跳起来时瞪眼、左右抖一下，
//      头顶惊叹号亮起。
//
//  场景视口（SVG 单位）：漂浮 15×12（上边缘 y=4）、打字 16×14（上边缘 y=3）、
//  起跳 16×14（上边缘 y=3）——视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的
//  `Sources/CodeIsland/OpenCodeView.swift`，坐标常量与配色逐值保留。
//

import SwiftUI

struct OpenCodeMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（机身浅灰描边（深灰机身本身是中性档））。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = frameC

    /// 配色取自 OpenCode 的单色体系：深灰机身、浅灰描边、近白脸、琥珀色警报。
    /// 上游机身那条注释写的是 `#383838`，但它的浮点值是 `(0.22, 0.22, 0.24)` = `#38383D`
    /// ——这里以浮点值为准（离屏逐像素比对与上游一致）。
    private static let bodyC = Color(mascotHex: 0x38383D)  // 深灰机身
    private static let frameC = Color(mascotHex: 0x8C8C91)  // 浅灰描边
    private static let faceC = Color(mascotHex: 0xD9D9DE)  // 近白脸
    private static let legC = Color(red: 0.35, green: 0.35, blue: 0.37)
    private static let alertC = Color(red: 1.0, green: 0.55, blue: 0.0)  // 琥珀
    private static let kbBase = Color(red: 0.12, green: 0.12, blue: 0.14)
    private static let kbKey = Color(red: 0.30, green: 0.30, blue: 0.32)
    private static let kbHi = Color.white

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

    // MARK: - 机身

    /// 机身：一块按行铺出来的深灰方块（首末行各内缩一格当圆角），正面套一圈浅灰方框。
    /// `squashX` / `squashY` 是落地那一瞬的压扁——纵向压缩时基线钉在 y=10，方块从地面往上塌。
    private func drawBlock(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        squashX: CGFloat = 1, squashY: CGFloat = 1
    ) {
        let cx: CGFloat = 7.5

        func sx(_ x: CGFloat, w: CGFloat) -> (CGFloat, CGFloat) {
            (cx + (x - cx) * squashX, w * squashX)
        }

        // 机身轮廓：每行「所在行 + 起始列 + 宽度」，首末行各内缩一格。
        let bodyRows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (5, 3, 9),  // 顶边
            (6, 2, 11),
            (7, 2, 11),
            (8, 2, 11),
            (9, 2, 11),
            (10, 2, 11),
            (11, 2, 11),
            (12, 2, 11),
            (13, 3, 9),  // 底边
        ]
        for row in bodyRows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            let adjH: CGFloat = 1 * squashY
            context.fill(
                Path(sprite.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, adjH, dy: dy)),
                with: .color(Self.bodyC))
        }

        // 内框：上下两条边不透明些，左右两条竖边更淡——像终端的窗口描边。
        let frameRows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (6, 3, 9),  // 上边
            (12, 3, 9),  // 下边
        ]
        for row in frameRows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            context.fill(
                Path(sprite.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, 0.7 * squashY, dy: dy)),
                with: .color(Self.frameC.opacity(0.6)))
        }
        for y: CGFloat in stride(from: 7, to: 12, by: 1) {
            let (leftX, _) = sx(3, w: 0.7)
            context.fill(
                Path(sprite.r(leftX, y * squashY + (1 - squashY) * 10, 0.7 * squashX, 1 * squashY, dy: dy)),
                with: .color(Self.frameC.opacity(0.4)))
            let (rightX, _) = sx(11.3, w: 0.7)
            context.fill(
                Path(sprite.r(rightX, y * squashY + (1 - squashY) * 10, 0.7 * squashX, 1 * squashY, dy: dy)),
                with: .color(Self.frameC.opacity(0.4)))
        }
    }

    /// 脸：一对 `{ }`（各由一竖笔与一段外凸的短横拼成），中间一颗光标点。
    /// `eyeScale` 小于 0.5 时收起光标——睡着的时候没有光标在闪。
    private func drawFace(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color = Self.faceC, eyeScale: CGFloat = 1.0
    ) {
        let eyeH: CGFloat = 2.0 * eyeScale
        let eyeY: CGFloat = 8.5 + (2.0 - eyeH) / 2

        // 左括号 `{`
        context.fill(Path(sprite.r(4.5, eyeY, 0.8, max(0.3, eyeH), dy: dy)), with: .color(color))
        context.fill(
            Path(sprite.r(4.0, eyeY + eyeH * 0.3, 0.7, max(0.3, eyeH * 0.4), dy: dy)),
            with: .color(color))

        // 右括号 `}`
        context.fill(Path(sprite.r(9.7, eyeY, 0.8, max(0.3, eyeH), dy: dy)), with: .color(color))
        context.fill(
            Path(sprite.r(10.2, eyeY + eyeH * 0.3, 0.7, max(0.3, eyeH * 0.4), dy: dy)),
            with: .color(color))

        // 中间的光标点
        if eyeScale > 0.5 {
            context.fill(Path(sprite.r(7.1, 9.2, 0.8, 0.8, dy: dy)), with: .color(color.opacity(0.8)))
        }
    }

    /// 影子：一条压在地面上的黑线，越飘越淡。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 9,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 14.5, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两条短腿（钉在地上，跳起来也不动）。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(4, 13.5, 1, 1.5)), with: .color(Self.legC))
        context.fill(Path(sprite.r(10, 13.5, 1, 1.5)), with: .color(Self.legC))
    }

    // MARK: - 空闲：飘着睡

    private var sleepScene: some View {
        Canvas { context, canvas in
            // 两个不可通约的周期叠出来的漂浮（3.85 / 7.24 秒）：浮沉不会精确重复，
            // 同屏多枚角色也因此各有各的节拍，不会跳成一排。
            let float = sin(t * 2 * .pi / 3.85) * 0.68 + sin(t * 2 * .pi / 7.24) * 0.36
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawShadow(&context, sprite, width: 7 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(&context, sprite)
            drawBlock(&context, sprite, dy: float)
            drawFace(&context, sprite, dy: float, color: Self.faceC.opacity(0.4), eyeScale: 0.3)
            // 飘 Z 从趴姿机身顶边（SVG y=5）上方升起。
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 5, t: t, size: size, color: Self.sleepZ)
        }
    }

    // MARK: - 处理中：趴在键盘上打字

    private var workScene: some View {
        Canvas { context, canvas in
            // 每约 11 秒停一拍：起伏从「随按键的快抖」换成「缓慢的呼吸」——
            // 像在读输出，而不是一直敲键盘。
            let workPause = MascotMotion.quirk(t, cycle: 11.1, duration: 1.2, seed: 0xC88)
            let bounce =
                sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
                + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
            let blink = max(0.1, MascotMotion.blink(t, seed: 0xC89))
            let keyPhase = Int(t / 0.1) % 6

            let sprite = MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3)

            // 1. 影子（起伏越大越窄越淡）
            let shadowWidth: CGFloat = 8 - abs(bounce) * 0.3
            context.fill(
                Path(sprite.r(4 + (8 - shadowWidth) / 2, 16, shadowWidth, 1)),
                with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

            // 2. 短腿
            drawLegs(&context, sprite)

            // 3. 键盘：2 行 × 6 列的键帽，每 0.1 秒换一格亮起来
            context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let keyY = 13.5 + CGFloat(row) * 1.2
                for column in 0..<6 {
                    let keyX = 0.5 + CGFloat(column) * 2.4
                    context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            let flashColumn = keyPhase % 6
            let flashRow = keyPhase / 3
            context.fill(
                Path(sprite.r(0.5 + CGFloat(flashColumn) * 2.4, 13.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
                with: .color(Self.kbHi.opacity(0.9)))

            // 4. 机身与脸（叠在键盘腿后面，只有上半身露出来）
            drawBlock(&context, sprite, dy: bounce)
            drawFace(&context, sprite, dy: bounce, eyeScale: blink)
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
    /// 影子留在地上（只有机身与脸跟着跳），惊叹号的位置按跳跃高度做阻尼。
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
        // 整条曲线等比缩到机身顶边不越出视口上边缘——跳得起来，也永远看得见。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 落地瞬间压扁、离地时拉长（只有这两行用原始位移判定，其余一律用截顶后的 `rise`）。
        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0
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

        // 机身与脸：左右抖一下（抖的是横向位移，与截顶无关）
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawBlock(&context, sprite, dy: rise, squashX: squashX, squashY: squashY)
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