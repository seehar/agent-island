//
//  FactoryMascot.swift
//  AgentIsland
//
//  Factory（droid）的像素角色：一台机械头机器人。方胖的机械头壳（7×7 退台方块）正中挖一只
//  独眼，头壳四周伸出八根辐条，围成一圈齿轮 / 螺旋桨的轮廓——Factory 官方标记「机械头 + 八
//  个扇叶」的方块化写法。
//    · 空闲：整台悬停呼吸（头与辐条一起上下 1 块）、眨眼，偶尔把辐条顺时针拧一格再拧回来；
//    · 处理中：辐条像齿轮一样连续转（每 0.12 秒挪一格），头随转的节拍轻颠、眼睛随转速忽宽忽窄；
//    · 待审批：辐条转速翻倍，独眼瞪大并点亮成品牌橙——「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：头壳 5…11 列 × 3…9 行，八根辐条各 2×1 块向外伸出，
//  整体约 12 列宽 × 9 行高，接地线在第 11 行。
//

import SwiftUI

struct FactoryMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 品牌橙（Factory 的亮橙），头壳压暗一档、辐条提亮一档，三层橙撑出体积。
    private static let body = Color(mascotHex: 0xFC7414)
    /// 辐条的亮档：在黑底上最跳，齿轮轮廓才看得清。
    private static let spoke = Color(mascotHex: 0xFFA85C)
    /// 头壳主体：比品牌橙暗一档，和辐条拉开层次。
    private static let shell = Color(mascotHex: 0xD95B0A)
    private static let seed = MascotMotion.stableSeed("droid")

    /// 八个辐条的方位（正上方起顺时针）：每个方位的方块左上角（网格列、行）。
    /// 依次是 上 / 右上 / 右 / 右下 / 下 / 左下 / 左 / 左上。
    private static let spokeSlots: [(x: CGFloat, y: CGFloat)] = [
        (7, 2),   // 上
        (11, 2),  // 右上
        (12, 6),  // 右
        (11, 10), // 右下
        (7, 10),  // 下
        (3, 10),  // 左下
        (2, 6),   // 左
        (3, 2),   // 左上
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let grid = MascotGrid(canvasSize)
            switch status {
            case .idle: drawIdle(&context, grid)
            case .working: drawWorking(&context, grid)
            case .alert: drawAlert(&context, grid)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - 三套场景

    /// 空闲：整台悬停呼吸 + 眨眼 + 偶发小动作（辐条拧一格再拧回来）。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 呼吸到顶时整台抬起 1 块；t == 0 恰好呼到底，不位移。
        let breath = MascotMotion.breathe(t)
        var dy = -breath

        // 小动作的包络是 0→1→0，所以辐条「拧过去再拧回来」正好落在这一格上。
        let quirk = MascotMotion.quirk(t, duration: 0.15, seed: Self.seed)
        var rotation: CGFloat = 0
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0:
                rotation = quirk        // 拧满一格
                dy -= 0.25 * quirk      // 顺手抬一下，力气用在了辐条上
            default:
                rotation = 0.5 * quirk  // 只拧半格：抖一下
            }
        }

        MascotDraw.groundLine(&context, grid, row: 11, width: 11, lift: -dy)
        drawDroid(
            &context, grid,
            dy: dy, rotation: rotation,
            eyeWidth: 2, eyeHeight: max(0.35, 2 * MascotMotion.blink(t, seed: Self.seed)),
            eyeColor: .black)
    }

    /// 处理中：辐条当齿轮转。`t == 0` 辐条停在初始方位、头不颠、眼睛正好 2 块宽——代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 每 0.24 秒轻颠一下（每两格一次），比辐条慢一倍，读起来是「转的惯性」。
        let dy = -0.5 * MascotMotion.hop(t, beat: 0.24)
        let rotation = Self.gearRotation(t, beat: 0.12)
        // 眼睛宽度在 1.5…2.5 块间摆；用正弦保证 t == 0 时恰在中间态 2 块。
        let eyeWidth = 2 + 0.5 * MascotMotion.swing(t, period: 0.24)

        MascotDraw.groundLine(&context, grid, row: 11, width: 11, lift: -dy)
        drawDroid(
            &context, grid,
            dy: dy, rotation: rotation,
            eyeWidth: eyeWidth,
            eyeHeight: max(0.35, 2 * MascotMotion.blink(t, seed: Self.seed)),
            eyeColor: .black)
    }

    /// 待审批：辐条转速翻倍 + 独眼瞪大点亮（跳跃、缩放与光晕由统一层 `AgentMascot` 施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let rotation = Self.gearRotation(t, beat: 0.06)

        MascotDraw.groundLine(&context, grid, row: 11, width: 11)
        drawDroid(
            &context, grid,
            dy: 0, rotation: rotation,
            eyeWidth: 3, eyeHeight: 3,
            eyeColor: Self.body)
    }

    // MARK: - 画法

    /// 齿轮的连续方位（单位：格，顺时针）：每 `beat` 秒推进一格——前 60% 的时间把这一格
    /// 走完（缓入缓出），剩下 40% 停在格位上，像棘轮卡进齿位。`t == 0` 正好停在初始方位。
    ///
    /// 刻意不做成 `beat(t, beat:) % 8` 那样的整数跳变：八根辐条同色同形，整数格之间只是
    /// 互相置换，画面逐像素全等 —— 离散跳变在屏幕上是**看不见**的。留出一段走格的过程，
    /// 转才读得出来。
    private static func gearRotation(_ t: CGFloat, beat: CGFloat) -> CGFloat {
        let steps = t / beat
        let index = steps.rounded(.down)
        return index + MascotMotion.easeInOut(min(1, (steps - index) / 0.6))
    }

    /// 画出整台机械头机器人：八根辐条 → 头壳 → 独眼。
    ///
    /// - Parameters:
    ///   - dy: 整体纵向位移（像素块，负值向上），头壳与辐条一起走
    ///   - rotation: 辐条的连续方位（0…8，顺时针；整数 = 停在某个方位上）
    ///   - eyeWidth: 眼睛宽度（像素块）
    ///   - eyeHeight: 眼睛高度（像素块，眨眼时收窄）
    ///   - eyeColor: 眼睛颜色（空闲 / 处理中是挖空的黑，瞪眼时换成品牌橙）
    private func drawDroid(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, rotation: CGFloat,
        eyeWidth: CGFloat, eyeHeight: CGFloat, eyeColor: Color
    ) {
        // 八根辐条：各自沿着那一圈方位走（`rotation + slot` 是它的当前位置）。
        for slot in 0..<8 {
            let position = Self.spokePosition(rotation + CGFloat(slot))
            MascotDraw.block(
                &context,
                grid.rect(Self.snap(position.x), Self.snap(position.y), 2, 1, dy: dy),
                Self.spoke)
        }

        // 头壳：7×7 的退台方块——顶盖用品牌橙、主体与底行用暗一档的头壳色，
        // 顶 / 底行各内收一格拼出圆角。
        MascotDraw.block(&context, grid.rect(6, 3, 5, 1, dy: dy), Self.body)
        MascotDraw.block(&context, grid.rect(5, 4, 7, 5, dy: dy), Self.shell)
        MascotDraw.block(&context, grid.rect(6, 9, 5, 1, dy: dy), Self.shell)

        // 独眼：挖在头壳正中（头壳连续区域是 5…12 列、3…10 行，中心 8.5 / 6.5）。
        MascotDraw.block(
            &context,
            grid.rect(
                8.5 - eyeWidth / 2, 6.5 - eyeHeight / 2, eyeWidth, eyeHeight, dy: dy),
            eyeColor)
    }

    /// 辐条在连续方位 `rotation` 上的左上角：在相邻两个方位之间线性插值，
    /// 因此整数方位之外的位置也能画（空闲小动作的「拧一格」靠它）。
    private static func spokePosition(_ rotation: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let wrapped = rotation.truncatingRemainder(dividingBy: CGFloat(spokeSlots.count))
        let slot = Int(wrapped)
        let fraction = wrapped - CGFloat(slot)
        let from = spokeSlots[slot % spokeSlots.count]
        let to = spokeSlots[(slot + 1) % spokeSlots.count]
        return (from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction)
    }

    /// 把坐标量化到 0.25 块的台阶：亚像素的平滑位移会让方块糊边。
    private static func snap(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}