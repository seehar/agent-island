//
//  KimiMascot.swift
//  AgentIsland
//
//  Kimi 的像素角色：官方标记「K + 右上角一颗圆点」被拆成两个活的部件——
//  K 字机器人（一竖 + 上下两条退台斜臂）和绕着它走的圆点伙伴，那颗点就是它的「眼」。
//    · 空闲：K 呼吸起伏，圆点沿 12 格轨道慢慢绕行、偶尔眨眼，小动作在「K 轻晃 / 圆点跳一下」之间轮换；
//    · 处理中：圆点每 0.12 秒挪一格、12 格绕一圈，K 随步子小幅起伏，一竖上另有一格光标上下跑；
//    · 待审批：圆点涨到 3×3 停在 K 正上方、一竖拉高一格——惊到站直
//      （整体跳跃、缩放与光晕由 `AgentMascot` 的统一层施加）。
//
//  网格占用（16×12）：K 第 2…10 行 × 第 3…12 列；圆点 2×2 沿 12 格轨道绕行，
//  轨道最外缘探到第 1…11 行与第 0…14 列；接地线画在第 11 行。
//

import SwiftUI

struct KimiMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// K 主体取品牌蓝的亮档：`0x0B62D6` 在黑底上偏暗，直接画会沉进舞台里。
    /// 暗色部件（一竖上的光标）与右上那颗圆点保留品牌蓝本身，色相不变。
    private static let body = Color(mascotHex: 0x3D7BE8)
    private static let brand = Color(mascotHex: 0x0B62D6)

    private static let seed = MascotMotion.stableSeed("kimi")

    // MARK: - 几何（16×12 网格，单位是像素块）

    /// 一竖：2 块宽、第 2…10 行，底边正好落在接地行（第 11 行）上。
    private static let stemX: CGFloat = 3
    private static let stemWidth: CGFloat = 2
    private static let stemTop: CGFloat = 2
    /// 一竖的底边（第 10 行的下沿）。
    private static let stemBottom: CGFloat = 11
    /// 受惊时一竖向上拉高一块。
    private static let stemTopAlert: CGFloat = 1

    /// 上下两条斜臂：各 4 块 2×2 的退台方块，从腰（第 5…6 行）沿斜上方 / 斜下方退到臂尖。
    private static let upperArm: [(row: CGFloat, column: CGFloat)] = [
        (5, 5), (4, 7), (3, 9), (2, 11),
    ]
    private static let lowerArm: [(row: CGFloat, column: CGFloat)] = [
        (6, 5), (7, 7), (8, 9), (9, 11),
    ]
    /// 每块斜臂方块的边长。
    private static let armBlock: CGFloat = 2

    /// 圆点的 12 格环绕轨道（常量表）：从 K 的右上角起顺时针一圈，每格是圆点的左上角。
    /// 轨道贴着 K 的轮廓走，任何一格都不会压在 K 身上——圆点是绕着 K 转，不是穿过它；
    /// 底下三格特意避开一竖与右下臂尖，因此贴在 K 的底边上走也不打架。
    private static let orbit: [(x: CGFloat, y: CGFloat)] = [
        (13, 1), (13, 4), (13, 7), (13, 10),  // 右侧：自上而下
        (9, 10), (5, 10),  // 底下：避开一竖（第 3…4 列）与右下臂尖（第 11…12 列）
        (0, 10), (0, 7), (0, 4), (0, 1),  // 左侧：自下而上
        (5, 1), (9, 1),  // 顶上：避开右上臂尖
    ]

    /// 圆点的边长（块）。
    private static let dotSide: CGFloat = 2
    /// 受惊时圆点涨到这么大，浮在 K 的正上方。
    private static let dotSideAlert: CGFloat = 3
    /// 受惊时圆点停的列：K 的横向中心在第 8 列，3 块宽贴着中心取左边第 6 列——
    /// 取整数格是为了块边落在整格上，涨大那颗点才不会糊边。
    private static let dotXAlert: CGFloat = 6

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

    /// 空闲：K 呼吸起伏，圆点每 0.5 秒挪一格慢慢绕行并偶尔眨眼；
    /// 小动作在「K 轻晃」与「圆点跳一下」之间轮换。
    /// `t == 0` 是呼吸的谷底、圆点停在右上角那一格、两眼睁满——代表帧。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let quirk = MascotMotion.quirk(t, seed: Self.seed)

        var bodyDx: CGFloat = 0
        var dotDy: CGFloat = 0
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0:
                // K 轻轻晃一下
                bodyDx = Self.quantized(0.5 * quirk)
            default:
                // 圆点向上跳一下
                dotDy = -Self.quantized(quirk)
            }
        }

        let bodyDy = -0.5 * breath
        MascotDraw.groundLine(&context, grid, row: 11, width: 8, lift: -bodyDy)
        drawK(&context, grid, stemTop: Self.stemTop, dx: bodyDx, dy: bodyDy, cursorRow: nil)
        drawDot(
            &context, grid, slot: MascotMotion.beat(t, beat: 0.5), dy: dotDy,
            blink: MascotMotion.blink(t, seed: Self.seed))
    }

    /// 处理中：圆点每 0.12 秒挪一格、12 格绕一圈，K 随步子小幅起伏，
    /// 一竖上另有一格光标上下跑。`t == 0` 时圆点在轨道起点（右上角）、光标在一竖顶端。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let slot = MascotMotion.beat(t, beat: 0.12)
        let bodyDy = Self.quantized(-0.4 * MascotMotion.hop(t, beat: 0.48))

        MascotDraw.groundLine(&context, grid, row: 11, width: 8, lift: -bodyDy)
        drawK(
            &context, grid, stemTop: Self.stemTop, dx: 0, dy: bodyDy,
            cursorRow: Self.cursorRow(at: slot))
        // 拖两格残影：圆点跑得快，残影是「它在绕圈」最直接的读法
        drawDot(&context, grid, slot: slot, trail: 2)
    }

    /// 待审批：圆点涨到 3×3 停在 K 的正上方，一竖向上拉高一格（惊到站直）。
    /// 姿态是静态的——弹跳与光晕由统一层施加，这里只负责「注意到你了」的样子。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: 11, width: 8)
        drawK(&context, grid, stemTop: Self.stemTopAlert, dx: 0, dy: 0, cursorRow: nil)

        MascotDraw.block(
            &context,
            grid.rect(Self.dotXAlert, 0, Self.dotSideAlert, Self.dotSideAlert),
            Self.brand)
    }

    // MARK: - 画法

    /// 画出整个 K：上下两条退台斜臂 + 一竖。
    ///
    /// - Parameters:
    ///   - stemTop: 一竖的顶边（受惊时上提一块）
    ///   - dx / dy: 整只 K 的局部位移（轻晃 / 起伏）
    ///   - cursorRow: 光标所在行；非空时在一竖上叠一格暗块（处理中的「光标」）
    private func drawK(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        stemTop: CGFloat, dx: CGFloat, dy: CGFloat, cursorRow: CGFloat?
    ) {
        // 两条斜臂：先画臂再画竖，交界处由竖盖住，腰（第 5…6 行）因此是实心的
        for block in Self.upperArm + Self.lowerArm {
            MascotDraw.block(
                &context,
                grid.rect(block.column, block.row, Self.armBlock, Self.armBlock, dx: dx, dy: dy),
                Self.body)
        }

        // 一竖：2 块宽，底边钉在接地行上
        MascotDraw.block(
            &context,
            grid.rect(Self.stemX, stemTop, Self.stemWidth, Self.stemBottom - stemTop, dx: dx, dy: dy),
            Self.body)

        // 光标：一竖上的一格暗块，沿竖笔上下跑
        if let cursorRow {
            MascotDraw.block(
                &context, grid.rect(Self.stemX, cursorRow, Self.stemWidth, 1, dx: dx, dy: dy),
                Self.brand)
        }
    }

    /// 画出圆点：按 12 格轨道定位（`slot` 自动取模）。
    ///
    /// - Parameters:
    ///   - dy: 小动作的跳跃位移（像素块）
    ///   - blink: 睁眼程度（1 = 睁满）。小于 1 时纵向压扁并保持垂直居中——
    ///     这颗圆点就是角色的「眼」，眨眼画在它身上
    ///   - trail: 身后拖几格残影（处理中快速绕圈时用）。残影取轨道上 `slot` 之前的那几格，
    ///     逐格淡下去——圆点跑起来时这才是「它在绕圈」最直接的读法
    private func drawDot(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        slot: Int, dy: CGFloat = 0, blink: CGFloat = 1, trail: Int = 0
    ) {
        let count = Self.orbit.count
        for back in stride(from: trail, through: 1, by: -1) {
            let ghost = Self.orbit[((slot - back) % count + count) % count]
            MascotDraw.block(
                &context, grid.rect(ghost.x, ghost.y, Self.dotSide, Self.dotSide),
                Self.brand.opacity(0.5 / CGFloat(back)))
        }

        let spot = Self.orbit[slot % count]
        let height = max(0.5, Self.dotSide * blink)
        MascotDraw.block(
            &context,
            grid.rect(spot.x, spot.y + (Self.dotSide - height) / 2 + dy, Self.dotSide, height),
            Self.brand)
    }

    // MARK: - 小工具

    /// 光标在一竖上的位置：第 2…10 行之间往返，跟着离散的 `slot` 一格一格地走。
    private static func cursorRow(at slot: Int) -> CGFloat {
        let positions = Int(stemBottom - 1 - stemTop) + 1
        let step = slot % (2 * (positions - 1))
        return stemTop + CGFloat(step <= positions - 1 ? step : 2 * (positions - 1) - step)
    }

    /// 小于一块的位移量化到 0.25 块：像素块是方的，落在半块上会糊边。
    private static func quantized(_ offset: CGFloat) -> CGFloat {
        (offset * 4).rounded() / 4
    }
}