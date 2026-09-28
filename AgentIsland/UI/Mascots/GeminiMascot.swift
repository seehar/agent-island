//
//  GeminiMascot.swift
//  AgentIsland
//
//  Gemini 的像素星芒。官方标记是四角星（sparkle），这里把它做成会呼吸的星芒精灵：
//    · 空闲：四条尖角随呼吸各进 1 块再退回、眨眼，偶尔歪一下头 / 抖一下耳 / 摆一下尾，
//      星芒外侧还会闪一颗小星点；
//    · 处理中：四条尖角按各自的节拍交替伸长（像在脉动），3 颗小星点沿轨道绕中心转，
//      眼睛同时亮起来；
//    · 待审批：四条尖角同时张到最开、眼睛瞪大——「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：星芒占第 1…10 行 × 第 3…12 列（上下尖角各 5 块高、左右尖角各 5 块宽，
//  中间 6 块宽 × 4 块高是实心块），底边钉在接地的第 11 行；四条尖角的尖端各点亮成 2×2 的亮块；
//  眼睛挖在第 5…6 行 × 第 6 / 9 列。绕行小星点走直径 12 块的轨道，会用到画布上下各 2 块的余量
//  （网格只有 12 行，画布按 16 块见方居中，所以行 0 与行 12 都还在画布内）。
//

import SwiftUI

struct GeminiMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 星芒主体取 Gemini 的品牌紫。舞台底色是黑的，所以直接用它偏亮的一档，
    /// 刘海上也认得出是哪个 Agent。
    private static let body = Color(mascotHex: 0x8C74D4)
    /// 尖端与绕行小星点的亮档：同一色相亮一档，黑底上才看得见。
    private static let tip = Color(mascotHex: 0xB9A6F0)
    private static let seed = MascotMotion.stableSeed("gemini")

    /// 星芒的行表：每行「所在行 + 宽度」。宽度以网格中线（第 8 列）为中心，
    /// 从尖端的 2 块逐级退台到中段的 10 块——四条尖角就藏在这张表里：
    /// 最外两行是上下尖角（各 2 块宽），中段两行是左右尖角（各 10 块宽）。
    private static let starRows: [(row: CGFloat, width: CGFloat)] = [
        (1, 2), (2, 2), (3, 4), (4, 6), (5, 10), (6, 10), (7, 6), (8, 4), (9, 2), (10, 2),
    ]

    /// 星芒的纵向中线（行）：眼睛以此为中心，绕行小星点以此当圆心。
    private static let centerRow: CGFloat = 6

    /// 绕行小星点：轨道直径 12 块（半径 6 块）、3.6 秒一圈。
    private static let orbitRadius: CGFloat = 6
    private static let orbitPeriod: CGFloat = 3.6

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

    /// 空闲：呼吸让四条尖角各进 1 块（不用透明度）、眨眼，偶尔歪头 / 抖耳 / 摆尾。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let quirk = MascotMotion.quirk(t, seed: Self.seed)

        var topDx: CGFloat = 0
        var bottomDx: CGFloat = 0
        var leftExtra: CGFloat = 0
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0:
                topDx = Self.step(quirk)  // 歪头：上尖角往右歪 1 块
            case 1:
                leftExtra = quirk  // 抖耳：左横尖角多伸 1 块
            default:
                bottomDx = -Self.step(quirk)  // 摆尾：下尖角往左摆 1 块
            }
        }

        MascotDraw.groundLine(&context, grid, row: 11, width: 8)
        drawStar(
            &context, grid,
            top: breath, bottom: breath, left: breath + leftExtra, right: breath,
            topDx: topDx, bottomDx: bottomDx)
        drawFace(&context, grid, height: 2 * MascotMotion.blink(t, seed: Self.seed), lit: false)

        // 小星点：停在上尖角的右外侧，平时不画，闪起来时连四向的碎光一起长出来
        let spark = MascotMotion.twinkle(t, period: 2.4)
        if spark > 0.08 {
            drawSpark(&context, grid, column: 11.5, row: 2, spark: spark)
        }
    }

    /// 处理中：四条尖角错开四分之一周期交替伸长（脉动），小星点绕圈、眼睛亮起来。
    /// `t == 0` 时四条尖角都在基准姿态、小星点停在轨道起点，是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 四条尖角各差四分之一周期：先上、再右、然后下、最后左
        let period: CGFloat = 1.2
        drawStar(
            &context, grid,
            top: MascotMotion.twinkle(t, period: period),
            bottom: MascotMotion.twinkle(t - period / 2, period: period),
            left: MascotMotion.twinkle(t - period * 3 / 4, period: period),
            right: MascotMotion.twinkle(t - period / 4, period: period),
            topDx: 0, bottomDx: 0)
        MascotDraw.groundLine(&context, grid, row: 11, width: 8)
        drawFace(&context, grid, height: 2, lit: true)

        // 3 颗小星点绕中心转：角度由 `t` 算，位置量化到 0.25 块（亚像素位移会糊边）
        for index in 0..<3 {
            let angle = (t / Self.orbitPeriod + CGFloat(index) / 3) * 2 * .pi
            drawSpark(
                &context, grid,
                column: MascotGrid.centerColumn + Self.orbitRadius * cos(angle),
                row: Self.centerRow + Self.orbitRadius * sin(angle),
                spark: MascotMotion.twinkle(t - CGFloat(index) * 0.3, period: 0.9))
        }
    }

    /// 待审批：四条尖角同时张到最开，眼睛瞪大（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: 11, width: 10)
        drawStar(&context, grid, top: 1, bottom: 1, left: 1, right: 1, topDx: 0, bottomDx: 0)
        drawFace(&context, grid, height: 3, width: 2, lit: false)
    }

    // MARK: - 画法

    /// 画出星芒本体：先按行表铺主体，再把四条尖角的尖端点亮。
    ///
    /// - Parameters:
    ///   - top: 上尖角向外伸出的量（块）：0 是基准姿态、1 是张到最开
    ///   - bottom: 下尖角向外伸出的量（块）
    ///   - left: 左尖角向外伸出的量（块）
    ///   - right: 右尖角向外伸出的量（块）
    ///   - topDx: 上尖角的横向摆动（块，歪头用）
    ///   - bottomDx: 下尖角的横向摆动（块，摆尾用）
    private func drawStar(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat,
        topDx: CGFloat, bottomDx: CGFloat
    ) {
        for entry in Self.starRows {
            var x = grid.centeredX(entry.width)
            var y = entry.row
            var width = entry.width
            var height: CGFloat = 1
            if entry.row <= 2 {
                // 上尖角的两行：整段向上长，退台因此跟着拉长
                y -= top
                x += topDx
                height += top
            } else if entry.row >= 9 {
                // 下尖角的两行：整段向下长
                x += bottomDx
                height += bottom
            } else if entry.row == 5 || entry.row == 6 {
                // 左右尖角的两行：两端各向外长
                x -= left
                width += left + right
            }
            MascotDraw.block(&context, grid.rect(x, y, width, height), Self.body)
        }

        // 四条尖角的尖端点亮成亮档：各 2×2 一块，跟着尖角一起进 / 一起摆
        MascotDraw.block(&context, grid.rect(7 + topDx, 1 - top, 2, 2), Self.tip)
        MascotDraw.block(&context, grid.rect(7 + bottomDx, 9 + bottom, 2, 2), Self.tip)
        MascotDraw.block(&context, grid.rect(3 - left, 5, 2, 2), Self.tip)
        MascotDraw.block(&context, grid.rect(11 + right, 5, 2, 2), Self.tip)
    }

    /// 眼睛：挖空成黑块（舞台底色本来就是黑的），上下各留一行主体，所以是嵌在星芒里的两点。
    ///
    /// - Parameters:
    ///   - height: 眼睛高度（块）：眨眼时收窄、瞪眼时放大，恒以星芒中线为中心
    ///   - width: 眼睛宽度（块）：常态 1 块，瞪大时向外各长 1 块
    ///   - lit: 处理中亮起来（换成亮档当瞳色），其余时候是挖空的黑
    private func drawFace(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        height: CGFloat, width: CGFloat = 1, lit: Bool
    ) {
        let eyeHeight = max(0.5, height)
        let top = Self.step(Self.centerRow - eyeHeight / 2)
        let color: Color = lit ? Self.tip : .black
        // 内缘钉在第 7 / 9 列：眼睛变宽时朝外长，两只因此始终对称于中线
        MascotDraw.block(&context, grid.rect(7 - width, top, width, eyeHeight), color)
        MascotDraw.block(&context, grid.rect(9, top, width, eyeHeight), color)
    }

    /// 一颗小星点：中心 1 块，`spark` 高时朝四个方向各长半块碎光——像星光闪了一下。
    private func drawSpark(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        column: CGFloat, row: CGFloat, spark: CGFloat
    ) {
        let x = Self.step(column)
        let y = Self.step(row)
        MascotDraw.block(&context, grid.rect(x, y, 1, 1), Self.tip)
        guard spark > 0.55 else { return }
        MascotDraw.block(&context, grid.rect(x + 0.25, y - 0.5, 0.5, 0.5), Self.tip)
        MascotDraw.block(&context, grid.rect(x + 0.25, y + 1, 0.5, 0.5), Self.tip)
        MascotDraw.block(&context, grid.rect(x - 0.5, y + 0.25, 0.5, 0.5), Self.tip)
        MascotDraw.block(&context, grid.rect(x + 1, y + 0.25, 0.5, 0.5), Self.tip)
    }

    /// 亚像素台阶：小件的位移量化到 0.25 块，像素块的边因此不会被磨糊。
    private static func step(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}