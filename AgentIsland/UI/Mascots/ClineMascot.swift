//
//  ClineMascot.swift
//  AgentIsland
//
//  Cline 的像素等化器。官方标记是「外壳 + 三根竖条」，这里把它做成一台会干活的控制台：
//  一块近白的圆角外壳里挖出三条黑色竖槽，三根柱子在里面上下走，柱顶各一颗指示灯。
//    · 空闲：三根柱错开 1/4 周期轻轻起伏、指示灯慢闪（三颗相位错开），偶尔三根一起抽一下
//      或单独一根跳一下；
//    · 处理中：三根柱每 0.2s 进一拍轮流跳到壳内顶——等化器的招牌动作，指示灯跟着那根亮；
//    · 待审批：三根一起拉满到壳顶、三颗灯同时满亮——「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：外壳 3…12 列 × 3…11 行（首行是顶盖、末行是压在接地线上的底座，
//  两行各内缩一格当圆角）；三根柱各 2 块宽（第 4 / 7 / 10 列起），柱底钉在第 11 行，
//  最高 7 块（含柱顶那一块指示灯），正好顶到壳内竖槽的上沿。
//

import SwiftUI

struct ClineMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// Cline 的品牌色是近白（`AgentPalette` 里那一档中性灰），外壳用它才认得出是哪个 Agent；
    /// 柱体压暗一档当体积感，指示灯提亮到纯白。舞台底色是黑的，因此竖槽直接用黑块挖空。
    private static let body = Color(mascotHex: 0xECECEC)
    private static let column = Color(mascotHex: 0xB9B9C4)
    private static let lamp = Color(mascotHex: 0xFFFFFF)
    private static let seed = MascotMotion.stableSeed("cline")

    /// 外壳轮廓：每行「所在行 + 起始列 + 宽度」。首行是顶盖、末行是落在接地线上的底座，
    /// 两行各内缩一格——方网格里因此读得出圆角，接地线也会在底座两侧各露出一点。
    private static let shellRows: [(row: CGFloat, column: CGFloat, width: CGFloat)] = [
        (3, 4, 8),
        (4, 3, 10), (5, 3, 10), (6, 3, 10),
        (7, 3, 10), (8, 3, 10), (9, 3, 10), (10, 3, 10),
        (11, 4, 8),
    ]

    /// 三根柱的起始列与静息高度（像素块）：左 3、中 6、右 4——高低错开才像均衡器。
    private static let barColumns: [CGFloat] = [4, 7, 10]
    private static let barRest: [CGFloat] = [3, 6, 4]
    /// 柱宽（2 块）、柱底所在行（= 接地行）与柱顶能到的最高总高（含指示灯）。
    private static let barWidth: CGFloat = 2
    private static let groundRow: CGFloat = 11
    private static let barPeak: CGFloat = 7
    /// 三条竖槽的行段：槽顶第 4 行、高 7 块——柱子正好在槽里走到上沿。
    private static let slotTop: CGFloat = 4
    private static let slotHeight: CGFloat = barPeak

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

    /// 空闲：三根柱错开 1/4 周期起伏 + 指示灯慢闪（带眨眼）+ 偶发小动作。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        var heights = Self.barRest
        var lamps = [CGFloat](repeating: 0, count: Self.barRest.count)

        for index in heights.indices {
            // 相位差 1/4 周期；把 `t == 0` 的那一相减掉，静止档因此正好停在静息高度。
            let phase = CGFloat(index) * 90
            let drift = 0.5 * (MascotMotion.swing(t, period: 3.2, phase: phase)
                - MascotMotion.swing(0, period: 3.2, phase: phase))
            heights[index] += drift
            // 三颗灯错开相位慢闪（1.8s 才闪一次读起来是「慢」）；眨眼时整排一起暗一下
            lamps[index] = MascotMotion.twinkle(t + CGFloat(index) * 0.45, period: 1.8)
                * MascotMotion.blink(t, seed: Self.seed)
        }

        // 小动作：三根一起抽一下（0），或单独一根跳一下（1）——抽到哪根按周期哈希轮换
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0:
                for index in heights.indices { heights[index] += quirk }
            default:
                let index = MascotMotion.quirkVariant(
                    t, count: heights.count, seed: Self.seed ^ 0xB0)
                heights[index] += quirk
            }
        }

        // 亚像素位移会让像素块糊边：起伏与抽动一律量化到 1/4 块的台阶
        for index in heights.indices { heights[index] = (heights[index] * 4).rounded() / 4 }

        drawConsole(&context, grid, heights: heights, lamps: lamps)
    }

    /// 处理中：三根柱每 0.2s 进一拍轮流跳到壳内顶，指示灯跟着跳的那根亮。
    /// `t == 0` 落在拍子的起点（升起量还是 0，三根都在静息高度），是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 这一拍轮到哪一根。当前那根在**整拍**里升到顶再落回（0.2s 一个来回），
        // 而不是「跳一下就停」——均衡器一半时间不动的话就不像在干活了。
        let current = MascotMotion.beat(t, beat: 0.2) % Self.barRest.count
        let phase = (t / 0.2).truncatingRemainder(dividingBy: 1)
        let rise = MascotMotion.easeInOut(
            MascotMotion.lerp(
                [(at: 0, value: 0), (at: 0.5, value: 1), (at: 1, value: 0)], at: phase))

        var heights = Self.barRest
        var lamps = [CGFloat](repeating: 0.35, count: Self.barRest.count)
        for index in heights.indices where index == current {
            // 亚像素位移会让像素块糊边：抬升量化到 1/4 块的台阶
            heights[index] = ((Self.barRest[index] + (Self.barPeak - Self.barRest[index]) * rise)
                * 4).rounded() / 4
            // 当前那根的灯整拍都亮着（一眼看出这一拍轮到谁），升到顶时再亮一档
            lamps[index] = 0.8 + 0.2 * rise
        }

        drawConsole(&context, grid, heights: heights, lamps: lamps)
    }

    /// 待审批：三根一起拉满到壳顶、三颗灯同时满亮（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let heights = [CGFloat](repeating: Self.barPeak, count: Self.barRest.count)
        let lamps = [CGFloat](repeating: 1, count: Self.barRest.count)
        drawConsole(&context, grid, heights: heights, lamps: lamps)
    }

    // MARK: - 画法

    /// 画出整台控制台：接地线 + 圆角外壳 + 三条竖槽 + 三根柱。
    ///
    /// 控制台是拧在地板上的（只有柱子在动），所以外壳与接地线都不随场景位移。
    ///
    /// - Parameters:
    ///   - heights: 三根柱的总高（含柱顶那块指示灯，像素块），柱底恒在第 11 行
    ///   - lamps: 三颗指示灯的亮起程度（1 = 满亮、0 = 灭）
    private func drawConsole(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        heights: [CGFloat], lamps: [CGFloat]
    ) {
        // 接地线：控制台压在它上面
        MascotDraw.groundLine(&context, grid, row: Self.groundRow, width: 10)

        // 外壳：圆角靠首尾两行各内缩一格做出来（网格是方的，没有圆角可画）
        for row in Self.shellRows {
            MascotDraw.block(&context, grid.rect(row.column, row.row, row.width, 1), Self.body)
        }

        // 竖槽与柱子：先挖黑槽，柱子再画在槽里——槽在那根柱子上方留下的黑，
        // 就是这根柱还没占满的行程
        for (index, x) in Self.barColumns.enumerated() {
            MascotDraw.block(
                &context, grid.rect(x, Self.slotTop, Self.barWidth, Self.slotHeight), .black)
            drawBar(&context, grid, x: x, total: heights[index], lampLevel: lamps[index])
        }
    }

    /// 一根柱：柱体 + 柱顶那一块指示灯。
    ///
    /// - Parameters:
    ///   - x: 柱的起始列
    ///   - total: 含指示灯的总高（像素块），柱底钉在第 11 行
    ///   - lampLevel: 指示灯的亮起程度
    private func drawBar(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        x: CGFloat, total: CGFloat, lampLevel: CGFloat
    ) {
        // 指示灯恒占顶上的一块，柱体是剩下的部分
        let lampHeight: CGFloat = 1
        let bodyHeight = max(0.5, total - lampHeight)
        MascotDraw.block(
            &context, grid.rect(x, Self.groundRow - bodyHeight, Self.barWidth, bodyHeight),
            Self.column)
        // 灯灭时压到 35% 亮度：在黑槽里读起来是「熄着的灯」，而不是一块暗斑
        MascotDraw.block(
            &context, grid.rect(x, Self.groundRow - total, Self.barWidth, lampHeight),
            Self.lamp.opacity(0.35 + 0.65 * lampLevel))
    }
}