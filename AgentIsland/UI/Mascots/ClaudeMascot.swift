//
//  ClaudeMascot.swift
//  AgentIsland
//
//  Claude Code 的像素蟹 Clawd：趴着打盹（做梦时抽腿、翻眼）、干活时趴在键盘上敲字、
//  有事就用三连跳 + 瞪眼 + 头顶惊叹号喊你。本应用原有的身份标记就是这只螃蟹，这里换成
//  移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）`Sources/CodeIsland/PixelCharacterView.swift`
//  的那一版——画法（趴姿、四条腿、臂绕肩旋转、键盘）与配色逐值保留：
//    · 空闲：趴着打盹（sploot），呼吸把身子撑起来，一条腿偶尔抽一下（做梦踢腿），
//      眼睛眯着偶尔翻动，头顶飘三个 Z；
//    · 处理中：趴在键盘上打字，手臂绕肩旋转，按下的键亮一下，偶尔停下来抬头想一轮；
//    · 待审批：3.5 秒一轮的三连跳（一跳比一跳矮），跳起来时瞪大眼、双臂扬起、头顶惊叹号。
//
//  场景视口（SVG 单位）：趴姿 17×7（上边缘 y=9）、打字 16×11（上边缘 y=5.5）、
//  起跳 15×12（上边缘 y=4）——视口不同只影响这一套场景里角色的位置与大小。
//

import SwiftUI

struct ClaudeMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27
    /// 睡眠 Z 的颜色：**这只角色自己最有代表性的那一支**（蟹壳橙（与品牌橙同一支））。
    /// `floatingZs` 会按黑舞台把它提亮一档再画。
    private static let sleepZ = shell

    /// 配色取自 clawd-on-desk：蟹壳橙、挖空的黑眼睛、警报橙、键盘三档灰。
    private static let shell = Color(mascotHex: 0xDE886D)
    private static let eye = Color.black
    private static let alert = Color(mascotHex: 0xFF3D00)
    private static let kbBase = Color(red: 0.38, green: 0.44, blue: 0.50)
    private static let kbKey = Color(red: 0.60, green: 0.66, blue: 0.72)
    private static let kbFlash = Color.white

    /// 起跳截顶的入参（`MascotMotion.alertRiseFactor`）：`drawAlert` 的 `rise` 与单测的
    /// 断言都从这里取，改这组数字会被 `AgentMascotRenderTests` 当场抓到。
    static let alertSpec = MascotAlertSpec(maxRise: 10, bodyTop: 6, svgTop: 4)

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
            let sprite = MascotSprite(canvas, svgWidth: 17, svgHeight: 7, svgTop: 9)
            drawSleeping(&context, sprite, breathe: MascotMotion.breathe(t, period: 4.5))
            // 睡眠 Z 从四条腿的上方升起（趴姿的腿尖是全身最高处）。
            MascotDraw.floatingZs(&context, sprite: sprite, bodyTop: 8.5, t: t, size: size, color: Self.sleepZ)
        }
    }

    /// 趴姿：影子随呼吸放大一点，四条腿朝天（其中一条偶尔抽一下），摊平的躯干随呼吸鼓起，
    /// 两只前爪摊在地上，眯着的眼睛偶尔翻动一下（做梦）。
    private func drawSleeping(
        _ context: inout GraphicsContext, _ sprite: MascotSprite, breathe: CGFloat
    ) {
        let shadowScale: CGFloat = 1.0 + breathe * 0.03
        context.fill(
            Path(sprite.r(-1, 15, 17 * shadowScale, 1)),
            with: .color(.black.opacity(0.35 + breathe * 0.08)))

        // 做梦踢腿：一条腿每约 6 秒抽一下，还可能整轮跳过（确定性哈希，无状态）。
        let twitch = MascotMotion.quirk(t, cycle: 6.0, duration: 0.55, seed: 0xC1A)
        let twitchLeg = MascotMotion.quirkVariant(t, cycle: 6.0, count: 4, seed: 0xC1A)
        for (index, x) in ([3, 5, 9, 11] as [CGFloat]).enumerated() {
            let kick: CGFloat = index == twitchLeg ? twitch * 0.9 : 0
            context.fill(
                Path(sprite.r(x, 8.5 - kick, 1, 1.5 + kick)),
                with: .color(Self.shell))
        }

        // 躯干：吸气时高 25% 以上，宽度也略微撑开。
        let puff = max(0, breathe) * 0.25
        let torsoHeight: CGFloat = 5 * (1.0 + puff)
        let torsoY: CGFloat = 15 - torsoHeight
        let torsoWidth: CGFloat = 13 * (1.0 + breathe * 0.015)
        context.fill(
            Path(sprite.r(1 - (torsoWidth - 13) / 2, torsoY, torsoWidth, torsoHeight)),
            with: .color(Self.shell))

        // 摊在地上的两只前爪
        context.fill(Path(sprite.r(-1, 13, 2, 2)), with: .color(Self.shell))
        context.fill(Path(sprite.r(14, 13, 2, 2)), with: .color(Self.shell))

        // 眯着的眼睛：偶尔翻动一下（做梦，不是停摆）。
        let rem = MascotMotion.quirk(t, cycle: 9.0, duration: 0.7, seed: 0x5EE)
        let eyeHeight: CGFloat = 1.0 - rem * 0.5
        let eyeY: CGFloat = 12.2 - puff * 2.5 + (1.0 - eyeHeight) / 2
        context.fill(Path(sprite.r(3, eyeY, 2.5, eyeHeight)), with: .color(Self.eye))
        context.fill(Path(sprite.r(9.5, eyeY, 2.5, eyeHeight)), with: .color(Self.eye))
    }

    // MARK: - 处理中：趴在键盘上打字

    private var workScene: some View {
        Canvas { context, canvas in
            drawWorking(&context, MascotSprite(canvas, svgWidth: 16, svgHeight: 11, svgTop: 5.5))
        }
    }

    /// 打字：身体随按键起伏，双臂绕肩旋转（按下去的键亮一下），眼睛眯着；
    /// 每约 11 秒停下来一轮——手悬在键盘上抬头看屏幕，动作因此是「一阵一阵」的。
    private func drawWorking(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pause = MascotMotion.quirk(t, cycle: 11.0, duration: 1.4, seed: 0x7A9)
        let typing: CGFloat = 1.0 - pause

        // 打字时是随按键的快速起伏，停下来时换成缓慢的呼吸摆动。
        let bounce =
            sin(t * 2 * .pi / 0.35) * 1.2 * typing
            + sin(t * 2 * .pi / 2.8) * 0.35 * (1 - typing)
        let breathe = sin(t * 2 * .pi / 3.2)

        // 两只手各按各的节拍（节拍里会跳过几拍：手不会像节拍器那样敲）。
        let strokeLeft = MascotMotion.typingBeat(t, cadence: 0.15, seed: 0x1EF7)
        let strokeRight = MascotMotion.typingBeat(t, cadence: 0.12, seed: 0x819)
        let armLeftRaw = (strokeLeft.active ? sin(t * 2 * .pi / 0.15) : -0.6) * typing
        let armRightRaw = (strokeRight.active ? sin(t * 2 * .pi / 0.12) : -0.6) * typing
        let armLeft = armLeftRaw * 22.5 - 32.5  // -55°…-10°
        let armRight = armRightRaw * 22.5 + 32.5  // 10°…55°

        // 只有真的按下去了才亮键，且亮哪一格随节拍槽位变化（确定性）。
        let leftHit = strokeLeft.active && armLeftRaw > 0.3
        let rightHit = strokeRight.active && armRightRaw > 0.3
        let leftKeyColumn = Int(MascotMotion.hash01(strokeLeft.slot, seed: 0xFACE0) * 3)
        let rightKeyColumn = 3 + Int(MascotMotion.hash01(strokeRight.slot, seed: 0xFACE1) * 3)

        // 眼睛：打字时眯着，抬头看屏幕或那一轮「扫屏」时睁大；在此之上叠自然眨眼。
        let scanPhase = t.truncatingRemainder(dividingBy: 10.0)
        let scanning = scanPhase > 5.7 && scanPhase < 6.9
        let eyeScale: CGFloat = (scanning || pause > 0.3) ? 1.0 : 0.5
        let eyeShift: CGFloat = eyeScale < 0.8 ? 1.0 : -0.5
        let eyeHeight: CGFloat = 2 * eyeScale * max(0.1, MascotMotion.blink(t, seed: 0xB1))

        // 1. 影子（起伏越大越窄越淡）
        let shadowWidth: CGFloat = 9 - abs(bounce) * 0.3
        context.fill(
            Path(sprite.r(3 + (9 - shadowWidth) / 2, 15, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.1, 0.4 - abs(bounce) * 0.03))))

        // 2. 短腿（在键盘后面）
        for x: CGFloat in [3, 5, 9, 11] {
            context.fill(Path(sprite.r(x, 13, 1, 2)), with: .color(Self.shell))
        }

        // 3. 躯干
        let torsoWidth = 11 * (1.0 + breathe * 0.015)
        context.fill(
            Path(sprite.r(2 - (torsoWidth - 11) / 2, 6, torsoWidth, 7, dy: bounce)),
            with: .color(Self.shell))

        // 4. 眼睛
        let eyeY: CGFloat = 8 + (2 - eyeHeight) / 2 + eyeShift
        context.fill(Path(sprite.r(4, eyeY, 1, eyeHeight, dy: bounce)), with: .color(Self.eye))
        context.fill(Path(sprite.r(10, eyeY, 1, eyeHeight, dy: bounce)), with: .color(Self.eye))

        // 5. 键盘（盖在腿上）+ 6 列 × 3 行的键帽
        context.fill(Path(sprite.r(-0.5, 11.8, 16, 3.5)), with: .color(Self.kbBase))
        for row in 0..<3 {
            let keyY = 12.2 + CGFloat(row) * 1.0
            for column in 0..<6 {
                let keyX = 0.3 + CGFloat(column) * 2.5
                let width: CGFloat = (column == 2 && row == 1) ? 4.5 : 2.0
                context.fill(Path(sprite.r(keyX, keyY, width, 0.7)), with: .color(Self.kbKey))
            }
        }
        for (hit, column) in [(leftHit, leftKeyColumn), (rightHit, rightKeyColumn)] where hit {
            let row = column % 3
            context.fill(
                Path(sprite.r(0.3 + CGFloat(column) * 2.5, 12.2 + CGFloat(row) * 1.0, 2.0, 0.7)),
                with: .color(Self.kbFlash.opacity(0.9)))
        }

        // 6. 双臂绕肩旋转（轴心是手臂与身体的连接点）
        context.fill(
            sprite.rotatedRect(
                x: 0, y: 9, width: 2, height: 2, pivotX: 2, pivotY: 10, angle: armLeft,
                dy: bounce),
            with: .color(Self.shell))
        context.fill(
            sprite.rotatedRect(
                x: 13, y: 9, width: 2, height: 2, pivotX: 13, pivotY: 10, angle: armRight,
                dy: bounce),
            with: .color(Self.shell))
    }

    // MARK: - 待审批：三连跳 + 瞪眼 + 惊叹号

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
                drawAlert(&context, MascotSprite(canvas, svgWidth: 15, svgHeight: 12, svgTop: 4))
            }
        }
        .frame(width: size, height: size)
    }

    /// 起跳：3.5 秒一轮，跳三次、一次比一次矮，然后安静到下一轮。
    /// 影子留在地上（只有躯干与手臂跟着跳），惊叹号的位置按跳跃高度做阻尼。
    private func drawAlert(_ context: inout GraphicsContext, _ sprite: MascotSprite) {
        let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5

        let jumpY = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: -1),
                (at: 0.15, value: 1.5),
                (at: 0.175, value: -10), (at: 0.20, value: -10), (at: 0.25, value: 1.5),
                (at: 0.275, value: -8), (at: 0.30, value: -8), (at: 0.35, value: 1.2),
                (at: 0.375, value: -5), (at: 0.40, value: -5), (at: 0.45, value: 1.0),
                (at: 0.475, value: -3), (at: 0.50, value: -3), (at: 0.55, value: 0.5),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)

        // 上游的顶点会把身体整个抛出视口（实拍只剩腿与影子）：整条曲线等比缩到身体
        // 顶边不越出视口上边缘，跳得起来、也永远看得见。
        let rise = jumpY * Self.alertSpec.riseFactor

        // 落地瞬间压扁、离地时拉长。
        let scaleX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.05 : 1.0
        let scaleY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.04 : 1.0

        // 双臂扬起：与跳跃同一张关键帧表。
        let armLeft = MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: 25),
                (at: 0.15, value: 30), (at: 0.20, value: 155), (at: 0.25, value: 115),
                (at: 0.30, value: 140), (at: 0.35, value: 100), (at: 0.40, value: 115),
                (at: 0.45, value: 80), (at: 0.50, value: 80), (at: 0.55, value: 40),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)
        let armRight = -MascotMotion.lerp(
            [
                (at: 0, value: 0), (at: 0.03, value: 0), (at: 0.10, value: 30),
                (at: 0.15, value: 30), (at: 0.20, value: 155), (at: 0.25, value: 115),
                (at: 0.30, value: 140), (at: 0.35, value: 100), (at: 0.40, value: 115),
                (at: 0.45, value: 80), (at: 0.50, value: 80), (at: 0.55, value: 40),
                (at: 0.62, value: 0), (at: 1.0, value: 0),
            ], at: pct)

        // 瞪眼：刚被惊到时放大并往上移一点。
        let eyeScale: CGFloat = (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0
        let eyeShift: CGFloat = (pct > 0.03 && pct < 0.15) ? -0.5 : 0

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
        let shadowWidth: CGFloat = 9 * (1.0 - abs(min(0, rise)) * 0.04)
        context.fill(
            Path(sprite.r(3 + (9 - shadowWidth) / 2, 15, shadowWidth, 1)),
            with: .color(.black.opacity(max(0.08, 0.5 - abs(min(0, rise)) * 0.04))))

        // 腿（钉在地上）
        for x: CGFloat in [3, 5, 9, 11] {
            context.fill(Path(sprite.r(x, 11, 1, 4)), with: .color(Self.shell))
        }

        // 躯干（带压扁 / 拉长，从底边往上长）
        let torsoWidth = 11 * scaleX
        let torsoHeight = 7 * scaleY
        context.fill(
            Path(
                sprite.r(
                    2 - (torsoWidth - 11) / 2, 6 + (7 - torsoHeight), torsoWidth, torsoHeight,
                    dy: rise)),
            with: .color(Self.shell))

        // 眼睛（瞪大 = 更高）
        let eyeHeight = 2 * eyeScale
        let eyeY: CGFloat = 8 + (2 - eyeHeight) / 2 + eyeShift
        context.fill(Path(sprite.r(4, eyeY, 1, eyeHeight, dy: rise)), with: .color(Self.eye))
        context.fill(Path(sprite.r(10, eyeY, 1, eyeHeight, dy: rise)), with: .color(Self.eye))

        // 双臂
        context.fill(
            sprite.rotatedRect(
                x: 0, y: 9, width: 2, height: 2, pivotX: 2, pivotY: 10, angle: armLeft,
                    dy: rise),
            with: .color(Self.shell))
        context.fill(
            sprite.rotatedRect(
                x: 13, y: 9, width: 2, height: 2, pivotX: 13, pivotY: 10, angle: armRight,
                    dy: rise),
            with: .color(Self.shell))

        // 惊叹号：在头顶上方，位移只有跳跃的 15%（不会飞出画布）。
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
