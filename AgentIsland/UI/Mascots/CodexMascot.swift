//
//  CodexMascot.swift
//  AgentIsland
//
//  Codex（OpenAI）的像素角色 Dex：一朵白到发灰的**像素云**，脸上是一枚 `>_` 终端提示符。
//  上游把 Codex 的云图标与命令行提示符拼成了一个会动的小家伙，这里逐值保留那套画法：
//    · 空闲：飘着打盹——两条不成公倍数的正弦叠出「飘」（云不会整点重复），光标慢闪，
//      每约 8 秒快闪一下，像一台在睡梦里自检的终端；云顶上方飘着三个 Z；`>` 不画 = 嘴闭着；
//    · 处理中：在键盘上敲字——云按 0.4 秒的拍子上下弹、键帽跟着人手亮一格，光标快闪；
//      每约 12 秒停一轮（起伏收住、光标常亮，像在等编译输出滚完）；
//    · 待审批：三连跳（一跳比一跳矮）+ 云身左右抖 + 提示符在白与琥珀之间闪 + 头顶惊叹号。
//
//  场景视口（SVG 单位）：打盹 15×12（上边缘 y=4）、打字与起跳 16×14（上边缘 y=3）——
//  视口不同只影响这一套场景里角色的位置与大小。
//
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）的 `Sources/CodeIsland/DexView.swift`，
//  坐标常量与配色逐值保留。
//

import SwiftUI

struct CodexMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（白云本身没有彩色 → 用品牌蓝）。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = AgentKind.codex.brandColor

    /// 配色：白到发灰的云、更暗一档的腿、黑色提示符、琥珀警报色、键盘三档灰。
    private static let cloud = Color(red: 0.92, green: 0.92, blue: 0.93)
    private static let leg = Color(red: 0.70, green: 0.70, blue: 0.72)
    private static let prompt = Color.black
    private static let alert = Color(red: 1.0, green: 0.55, blue: 0.0)
    private static let kbBase = Color(red: 0.18, green: 0.18, blue: 0.20)
    private static let kbKey = Color(red: 0.40, green: 0.40, blue: 0.42)
    private static let kbHit = Color.white
    /// 睡眠 Z 的中灰：黑舞台上看得见，压在近白的云顶上也不会消失。

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

    // MARK: - 空闲：飘着打盹

    private var sleepScene: some View {
        Canvas { context, canvas in
            let sprite = MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4)
            drawSleeping(&context, sprite)
            // 飘 Z 从云顶（趴姿身体主体的顶边，SVG y = 5：三个鼓包的最高那一行）上方升起。
            // 云是接近白的浅灰：Z 用中灰才能在**黑舞台与云顶上都读得出来**
            // （上游在这个位置画的是白 Z，落在云上等于隐形）。
            MascotDraw.floatingZs(
                &context, sprite: sprite, bodyTop: 5, t: t, size: size, color: Self.sleepZ)
        }
    }

    /// 打盹：两个不成公倍数的正弦叠出「飘」，云因此不会整点重复；光标慢闪，每约 8 秒
    /// 还快闪一下——像一台在睡梦里自检的终端。`>` 不画（= 嘴闭着），只留暗淡的光标。
    private func drawSleeping(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let float = sin(t * 2 * .pi / 4.0) * 0.7 + sin(t * 2 * .pi / 6.3) * 0.35
        let pulse = MascotMotion.quirk(t, cycle: 8.0, duration: 0.5, seed: 0xDE1)
        let cursorPhase = t.truncatingRemainder(dividingBy: 1.2)
        let cursorOn =
            pulse > 0 ? (pulse * 4).truncatingRemainder(dividingBy: 1) < 0.5 : cursorPhase < 0.6

        drawShadow(&context, sprite, width: 7 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(&context, sprite)
        drawCloud(&context, sprite, dy: float)
        if cursorOn {
            context.fill(
                Path(sprite.r(6, 12, 3, 1, dy: float)),
                with: .color(Self.prompt.opacity(pulse > 0 ? 0.5 : 0.3)))
        }
    }

    // MARK: - 处理中：在键盘上敲字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 14, svgTop: 3))
        }
    }

    /// 敲字：云按 0.4 秒的拍子上下弹（停下来那一轮收住，换成很小的余波），键盘上
    /// 亮哪一格由敲击槽位决定；每约 12 秒停一轮——那期间光标常亮（忙，不是闲）。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pause = MascotMotion.quirk(t, cycle: 12.0, duration: 1.2, seed: 0xDE2)
        let intensity: CGFloat = 1.0 - pause
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * intensity

        let cursorPhase = t.truncatingRemainder(dividingBy: 0.3)
        let cursorOn = pause > 0.3 ? true : cursorPhase < 0.15

        // 键闪跟着人手的节奏（节拍里会跳过几拍）：槽位决定亮哪一格。
        let stroke = MascotMotion.typingBeat(t, cadence: 0.1, seed: 0xDE3)
        let keyPhase = Int(MascotMotion.hash01(stroke.slot, seed: 0xDE4) * 6)

        // 1. 影子（弹得越高越窄越淡）
        let shadowWidth: CGFloat = 8 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(4 + (8 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

        // 2. 短腿（在键盘后面）
        drawLegs(&context, sprite)

        // 3. 键盘 + 6 列 × 2 行的键帽
        context.fill(Path(sprite.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let keyY = 13.5 + CGFloat(row) * 1.2
            for column in 0..<6 {
                let keyX = 0.5 + CGFloat(column) * 2.4
                context.fill(Path(sprite.r(keyX, keyY, 1.8, 0.7)), with: .color(Self.kbKey))
            }
        }

        // 4. 真敲下去的那一下才亮键（且不在停顿时）
        if stroke.active && pause < 0.3 {
            let flashX = 0.5 + CGFloat(keyPhase % 6) * 2.4
            let flashY = 13.5 + CGFloat(keyPhase / 3) * 1.2
            context.fill(
                Path(sprite.r(flashX, flashY, 1.8, 0.7)),
                with: .color(Self.kbHit.opacity(0.9)))
        }

        // 5. 云与 `>_`：一起随敲字起伏
        drawCloud(&context, sprite, dy: bounce)
        drawPrompt(&context, sprite, dy: bounce, cursorOn: cursorOn)
    }

    // MARK: - 待审批：三连跳 + 提示符报警 + 惊叹号

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

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮——起跳段云身左右抖、
    /// 提示符在白与琥珀之间闪，影子留在地上（跳得越高越窄越淡）。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        // 三连跳的位移表（-8 / -6 / -4 / -2 是三次起跳的顶点）。
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

        // 上游的顶点会把云整个抛出视口（实拍只剩腿与影子）：整条曲线等比缩到云顶不越出
        // 视口上边缘，跳得起来、也永远看得见。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 落地瞬间压扁、离地时拉长（判定继续用原始 jumpY：压扁是「贴地」的表现）。
        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0

        // 起跳段的左右抖（横向位移，不参与截顶）
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // 提示符在白与琥珀之间闪
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let promptColor = flash > 0.5 ? Self.alert : Self.prompt

        // 惊叹号：起跳一开始亮起，安静下来淡出
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

        // 影子：跳得越高越窄越淡，但**留在原地**
        let shadowWidth: CGFloat = 8 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(4 + (8 - shadowWidth) / 2, 16, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, rise)) * 0.04))))

        // 腿（钉在地上）
        drawLegs(&context, sprite)

        // 云身与 `>_`：整体横向抖一下（`translateBy` 走画布点，所以要乘一个单位的边长）
        context.translateBy(x: shakeX * sprite.block, y: 0)
        drawCloud(&context, sprite, dy: rise, squashX: squashX, squashY: squashY)
        drawPrompt(&context, sprite, dy: rise, color: promptColor, cursorOn: true)
        context.translateBy(x: -shakeX * sprite.block, y: 0)

        // 惊叹号：在头顶上方，位移只有跳跃的 15%（不会飞出画布）
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

    // MARK: - 共用的部件

    /// 云身：一排排像素块叠出来的云朵轮廓（底宽顶窄，顶上三个鼓包）。
    /// `squashX` / `squashY` 只用于落地压扁（横向以 x=7.5 为中心、纵向锚在 y≈10）。
    private func drawCloud(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        squashX: CGFloat = 1, squashY: CGFloat = 1
    ) {
        /// 压扁后的横坐标与宽度（中心 x = 7.5）。
        func squashed(_ x: CGFloat, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
            (7.5 + (x - 7.5) * squashX, width * squashX)
        }

        let rows: [(y: CGFloat, x: CGFloat, width: CGFloat)] = [
            (14, 4, 7),  // 底边
            (13, 3, 9),
            (12, 2, 11),
            (11, 1, 13),  // 最宽
            (10, 1, 13),
            (9, 1, 13),
            (8, 2, 11),
            (7, 2, 11),
            // 云朵轮廓上的三个鼓包
            (6, 3, 3),  // 左鼓包
            (6, 6, 3),  // 中鼓包
            (6, 9, 3),  // 右鼓包
            (5, 4, 2),  // 左鼓包顶
            (5, 6.5, 2),  // 中鼓包顶
            (5, 9, 2),  // 右鼓包顶
        ]

        for row in rows {
            let (x, width) = squashed(row.x, width: row.width)
            context.fill(
                Path(sprite.r(x, row.y * squashY + (1 - squashY) * 10, width, squashY, dy: dy)),
                with: .color(Self.cloud))
        }
    }

    /// 脸上的 `>_`：`>` 是三级台阶的箭头，`_` 是光标（敲键时亮灭、睡觉时暗淡、
    /// 待审批时在白与琥珀之间闪）。
    private func drawPrompt(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, dy: CGFloat,
        color: Color = Self.prompt, cursorOn: Bool = true
    ) {
        context.fill(Path(sprite.r(3, 10, 1, 1, dy: dy)), with: .color(color))
        context.fill(Path(sprite.r(4, 11, 1, 1, dy: dy)), with: .color(color))
        context.fill(Path(sprite.r(3, 12, 1, 1, dy: dy)), with: .color(color))
        if cursorOn {
            context.fill(Path(sprite.r(6, 12, 3, 1, dy: dy)), with: .color(color))
        }
    }

    /// 接地影子：横在 y = 15 那一行，跟着角色的起伏收窄变淡。
    private func drawShadow(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, width: CGFloat = 9,
        opacity: CGFloat = 0.3
    ) {
        context.fill(
            Path(sprite.r(7.5 - width / 2, 15, width, 1)),
            with: .color(.black.opacity(opacity)))
    }

    /// 云底下两根更暗的小短腿。
    private func drawLegs(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        context.fill(Path(sprite.r(5, 14.5, 1, 1.5)), with: .color(Self.leg))
        context.fill(Path(sprite.r(9, 14.5, 1, 1.5)), with: .color(Self.leg))
    }
}