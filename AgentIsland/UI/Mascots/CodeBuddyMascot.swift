//
//  CodeBuddyMascot.swift
//  AgentIsland
//
//  CodeBuddy 的像素角色：一只穿宇航服的紫猫（腾讯云风）。紫猫身 + 青绿护目镜与耳窝，
//  坐下来时两只尖耳支棱着、身后翘一格尾巴：
//    · 空闲：坐在地上打盹——两个互不整除的漂移周期把身体慢慢托起又放下，眼睛眯成一条缝
//      （护目镜里的青绿压到 30%），头顶飘三个 Z；
//    · 处理中：坐在键盘前打字——身体随按键起伏，每约 10 秒停下来一轮（读结果而不是
//      一直在敲），键帽上有一格在亮（亮哪一格随节拍换），眼睛叠自然眨眼；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮）+ 落地压扁 + 左右发抖 + 眼睛在青绿与
//      警报红之间闪 + 头顶惊叹号 + 警报光晕。
//
//  场景视口（SVG 单位）：打盹 15×13（上边缘 y=3）、打字 16×14（上边缘 y=3）、
//  起跳 16×14（上边缘 y=3）——视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的 `Sources/CodeIsland/BuddyView.swift`，
//  坐标常量与配色逐值保留；时间改为显式传参（`t`），每一帧因此都是 `t` 的纯函数。
//

import SwiftUI

struct CodeBuddyMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（机身紫）。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = bodyC

    /// CodeBuddy 的品牌配色：紫猫身（`#6C4DFF`）、压暗一档的护目镜与爪子（`#583ED3`）、
    /// 青绿耳窝与眼睛（`#32E6B9`）、护目镜深处的白；键盘三档与警报红照抄上游数值。
    private static let bodyC = Color(mascotHex: 0x6C4DFF)
    private static let bodyDk = Color(mascotHex: 0x583ED3)
    private static let glowC = Color(mascotHex: 0x32E6B9)
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.18, green: 0.15, blue: 0.30)
    private static let kbKey = Color(red: 0.35, green: 0.30, blue: 0.55)
    private static let kbHi = Color(red: 0.196, green: 0.902, blue: 0.725)

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 8, bodyTop: 4, svgTop: 3)

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

    /// 坐着的猫：九行躯干（上窄下宽）+ 两只尖耳（内耳青绿）+ 护目镜横带 + 鼻点 + 身后的尾巴。
    /// `squashX` / `squashY` 是落地压扁，静息时都是 1。
    private func drawCat(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        squashX: CGFloat = 1, squashY: CGFloat = 1
    ) {
        let cx: CGFloat = 7.5

        /// 以躯干中线为轴横向压扁，返回调整后的左边界与宽度。
        func sx(_ x: CGFloat, w: CGFloat) -> (CGFloat, CGFloat) {
            let nx = cx + (x - cx) * squashX
            return (nx, w * squashX)
        }

        // 躯干九行：底边坐在地上，头顶比胸口窄一格。
        let bodyRows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (14, 3, 9),  // 坐在地上的底边
            (13, 2, 11),
            (12, 2, 11),
            (11, 2, 11),  // 肚子
            (10, 3, 9),
            (9, 3, 9),  // 胸口
            (8, 3, 9),  // 头
            (7, 3, 9),
            (6, 4, 7),  // 头顶
        ]
        for row in bodyRows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            let adjH: CGFloat = 1 * squashY
            context.fill(
                Path(sprite.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, adjH, dy: dy)),
                with: .color(Self.bodyC))
        }

        // 尖耳朵：两格高，压扁时跟着降下去。
        let (earLX, earLW) = sx(2.5, w: 2.5)
        let (earRX, earRW) = sx(10.0, w: 2.5)
        let earY: CGFloat = 4 * squashY + (1 - squashY) * 10
        let earH: CGFloat = 2 * squashY
        context.fill(Path(sprite.r(earLX, earY, earLW, earH, dy: dy)), with: .color(Self.bodyC))
        context.fill(Path(sprite.r(earRX, earY, earRW, earH, dy: dy)), with: .color(Self.bodyC))

        // 耳窝：青绿，比耳朵小一圈（60% 不透明，读起来是发光的内耳）。
        let (innerEarLX, innerEarLW) = sx(3.0, w: 1.5)
        let (innerEarRX, innerEarRW) = sx(10.5, w: 1.5)
        context.fill(
            Path(sprite.r(innerEarLX, earY + 0.5 * squashY, innerEarLW, 1.2 * squashY, dy: dy)),
            with: .color(Self.glowC.opacity(0.6)))
        context.fill(
            Path(sprite.r(innerEarRX, earY + 0.5 * squashY, innerEarRW, 1.2 * squashY, dy: dy)),
            with: .color(Self.glowC.opacity(0.6)))

        // 护目镜：横过脸的一条深紫带（眼睛画在它上面）。
        let (vizX, vizW) = sx(3.5, w: 8)
        context.fill(
            Path(sprite.r(vizX, 7 * squashY + (1 - squashY) * 10, vizW, 2.5 * squashY, dy: dy)),
            with: .color(Self.bodyDk))

        // 鼻点：两只眼睛中间的一格青绿。
        let (noseX, _) = sx(7.0, w: 1)
        context.fill(
            Path(sprite.r(noseX, 8.8 * squashY + (1 - squashY) * 10, 1, 0.8 * squashY, dy: dy)),
            with: .color(Self.glowC.opacity(0.4)))

        // 尾巴：在身体右侧翘一格。
        let (tailX, tailW) = sx(12.0, w: 2)
        context.fill(
            Path(sprite.r(tailX, 12 * squashY + (1 - squashY) * 10, tailW, 1 * squashY, dy: dy)),
            with: .color(Self.bodyC))
        context.fill(
            Path(
                sprite.r(
                    tailX + tailW * 0.5, 11 * squashY + (1 - squashY) * 10, tailW * 0.5,
                    1 * squashY, dy: dy)),
            with: .color(Self.bodyC))
    }

    /// 护目镜里的两点眼睛：`scale` 是睁眼程度（1 睁满、0.3 眯着）。
    private func drawEyes(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color = Self.glowC, scale: CGFloat = 1.0
    ) {
        let eyeH: CGFloat = 1.2 * scale
        let eyeY: CGFloat = 7.5 + (1.2 - eyeH) / 2
        context.fill(Path(sprite.r(5, eyeY, 1.2, max(0.2, eyeH), dy: dy)), with: .color(color))
        context.fill(Path(sprite.r(8.8, eyeY, 1.2, max(0.2, eyeH), dy: dy)), with: .color(color))
    }

    /// 地上的一格影子（宽度与浓度由各场景给）。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 9,
        opacity: Double = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15.5, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 两只前爪：钉在地上，不跟着身体跳（跳起来时身体与爪子之间因此会拉开一点）。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(4, 14.5, 1.5, 1.5)), with: .color(Self.bodyDk))
        context.fill(Path(sprite.r(9.5, 14.5, 1.5, 1.5)), with: .color(Self.bodyDk))
    }

    // MARK: - 空闲：坐在地上打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 13, svgTop: 3)
            drawSleeping(&context, sprite)
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 6, t: t, size: size, color: Self.sleepZ)
        }
    }

    /// 打盹：两个互不整除的漂移周期（4.50s / 6.95s）叠出「永远差一点才重复」的起伏——
    /// 同一枚角色的节奏不会像节拍器，多行并排也不会整齐划一地上下。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let float = sin(t * 2 * .pi / 4.50) * 0.51 + sin(t * 2 * .pi / 6.95) * 0.27

        drawShadow(&context, sprite, width: 7 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(&context, sprite)
        drawCat(&context, sprite, dy: float)
        // 睡着的眼睛：青绿压到 30%、只剩一条缝。
        drawEyes(&context, sprite, dy: float, color: Self.glowC.opacity(0.3), scale: 0.3)
    }

    // MARK: - 处理中：坐在键盘前打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 打字：身体随按键快速起伏；每约 10 秒停下来一轮，起伏换成缓慢的呼吸摆动
    /// （那是在读结果，不是在敲）。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let workPause = MascotMotion.quirk(t, cycle: 10.2, duration: 1.2, seed: 0x131)
        let bounce =
            sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let blink = max(0.1, MascotMotion.blink(t, seed: 0x132))
        let keyPhase = Int(t / 0.1) % 6

        // 1. 影子（起伏越大越窄越淡）
        let shadowW: CGFloat = 8 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        // 2. 爪子（在键盘后面）
        drawLegs(&context, sprite)

        // 3. 键盘（盖在爪子上）+ 4. 两行 × 六列键帽
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 13.5 + CGFloat(row) * 1.2
            for column in 0..<6 {
                let keyX = 0.5 + CGFloat(column) * 2.4
                context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
            }
        }
        // 亮着的那一格：位置随 0.1 秒的节拍在 6 格里轮换（确定性）。
        let hitColumn = keyPhase % 6
        let hitRow = keyPhase / 3
        context.fill(
            Path(sprite.r(0.5 + CGFloat(hitColumn) * 2.4, 13.5 + CGFloat(hitRow) * 1.2, 1.8, 0.7)),
            with: .color(Self.kbHi.opacity(0.9)))

        // 5. 猫身 + 6. 眼睛
        drawCat(&context, sprite, dy: bounce)
        drawEyes(&context, sprite, dy: bounce, scale: blink)
    }

    // MARK: - 待审批：三连跳 + 抖 + 惊叹号

    private var alertScene: some View {
        ZStack {
            // 警报光晕：常亮一点余晖，随安静段慢慢呼吸。用径向渐变而不是 `blur`
            // （20fps 下模糊的离屏渲染太贵），强度是 `t` 的纯函数。
            RadialGradient(
                colors: [
                    Self.glowC.opacity(0.05 + 0.10 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.0))),
                    Self.glowC.opacity(0),
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
    /// 爪子与影子留在地上（只有身体跟着跳），惊叹号按跳跃高度做 15% 的阻尼位移。
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

        // 上游的顶点会把整只猫抛出视口（实拍只剩下爪子与影子）：整条曲线等比缩到身体
        // 顶边不越出视口上边缘，跳得起来、也永远看得见。
        // `bodyTop = 4` 是**耳朵的顶边**（`drawCat` 把耳朵画在躯干之上，猫的轮廓顶边就是它）：
        // 按躯干顶边 6 算出来的 0.45 会把一对耳朵在顶点切平（只剩几像素的残根）。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 落地瞬间压扁：判定用**原始** `jumpY`，位移才用截顶后的 `rise`。
        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0

        // 左右发抖：包络逐值保留（只在起跳那一段抖）。
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // 眼睛在青绿与警报红之间闪。
        let eyeFlash = pct > 0.03 && pct < 0.55 && sin(pct * 25) > 0
        let eyeColor = eyeFlash ? Self.alertC : Self.glowC

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
        let shadowW: CGFloat = 8 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
            with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, rise)) * 0.04))))

        // 爪子钉在地上
        drawLegs(&context, sprite)

        // 抖的是身体与眼睛，爪子和影子不抖。
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawCat(&context, sprite, dy: rise, squashX: squashX, squashY: squashY)
        drawEyes(
            &context, sprite, dy: rise, color: eyeColor,
            scale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
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