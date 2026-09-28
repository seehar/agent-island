//
//  OhMyPiMascot.swift
//  AgentIsland
//
//  Oh My Pi（`omp`）的像素角色。它的官方标记是一个 π，这里把 π 画成一个小人：
//  顶横当「头 / 肩」（12 块宽、2 块高，眼睛从里面挖空），两条竖笔当腿；
//  右腿按官方 π 的形状再往下多探一块，是个长腿。
//    · 空闲：呼吸时头抬起、脚底钉住，腿跟着伸缩；眨眼；偶尔歪一下头 / 抬一只脚 / 换只脚站；
//    · 处理中：两条腿按 0.15 秒一拍交替踏步（抬脚用「腿变短」表达，脚底始终在地面），
//      头随步子轻颠并小幅左右摆；身子压低一块、眼睛眯起来 —— 这是常驻的干活架势，
//      「静止」档位下才分得出它和空闲；
//    · 待审批：双腿并拢站直、头抬起一块、眼睛瞪大 —— 「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：顶横 2…14 列 × 2…4 行、双腿 3…5 与 11…13 列 × 4…11 行
//  （右腿到第 12 行）、接地线在第 11 行。
//

import SwiftUI

struct OhMyPiMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 品牌紫取 omp 图标渐变的中间色标 `#9B4DFF`（与 `AgentPalette` 的 `.ohMyPi` 同色），
    /// 腿压暗一档做前后关系。眼睛是挖空——舞台底色本来就是黑的，所以直接用黑块，
    /// 不需要第四种颜色。
    private static let body = Color(mascotHex: 0x9B4DFF)
    private static let leg = Color(mascotHex: 0x7A3FD0)
    private static let seed = MascotMotion.stableSeed("omp")

    // MARK: - 几何（网格坐标，单位是像素块）

    /// 顶横（头 / 肩）：12 列宽、2 行高的一横，开在顶部第 2 行。
    private static let barX: CGFloat = 2
    private static let barY: CGFloat = 2
    private static let barW: CGFloat = 12
    private static let barH: CGFloat = 2

    /// 两条腿：各 2 列宽，顶边挂在顶横下沿（第 4 行），列位置对称于中线。
    private static let legW: CGFloat = 2
    private static let legY: CGFloat = 4
    private static let legColumns: [CGFloat] = [3, 11]
    /// 两条腿各自的脚底（底边所在的网格线）。左腿落在接地行上，右腿按官方 π 多探一块。
    private static let feet: [CGFloat] = [11, 12]

    /// 眼睛：挖在顶横里，各 2 列宽；`eyeY` 是眼的中线（正好是头的中线）。
    private static let eyeColumns: [CGFloat] = [5, 9]
    private static let eyeW: CGFloat = 2
    private static let eyeH: CGFloat = 1.4
    private static let eyeY: CGFloat = 3

    /// 接地行。
    private static let ground: CGFloat = 11

    /// 干活的架势（处理中常驻，见 `drawWorking`）：身子压低多少块、眼睛眯到几分。
    /// 眯眼只压 20%：眼睛是这张脸仅有的五官，压得太狠在小尺寸下会看成没画出来。
    private static let crouch: CGFloat = 1
    private static let squint: CGFloat = 0.8

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

    /// 空闲：呼吸（头抬起、腿跟着伸缩）+ 眨眼 + 偶发小动作。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 脚底钉在地上，所以呼吸只抬得动头：头越往上，腿被拉得越长
        let breath = MascotMotion.breathe(t)
        var barDx: CGFloat = 0
        let barDy = -breath
        var lifts: [CGFloat] = [0, 0]

        // 小动作：每 7 秒至多来一次，在「歪头 / 抬左脚 / 换脚站」之间轮换
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0:
                barDx = quirk  // 歪头：头往右挪一块
            case 1:
                lifts[0] = quirk  // 抬一下左脚
            default:
                barDx = -quirk  // 换脚站：身体往左压，右脚变轻
                lifts[1] = quirk
            }
        }

        // 脚底从不离地，所以接地线不收缩——呼吸只抬得动上面的头
        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 9, lift: 0)
        drawPi(
            &context, grid,
            barDx: stepped(barDx), barDy: barDy, lifts: lifts,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed))
    }

    /// 处理中：两腿交替踏步。`t == 0` 落在双脚落地的中间态，是这套动作的代表帧。
    ///
    /// 除了踏步，这身「干活的架势」是**常驻**的：身子压低一块（腿屈着）、眼睛眯起来。
    /// 少了它就麻烦——踏步的第 0 拍本来就是双脚落地，而呼吸呼到底、小动作又没来的空闲帧
    /// 也长这样，于是「静止」档位下处理中与空闲会画成同一张图。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 0.15 秒一拍：第 0 / 2 拍双脚落地，第 1 / 3 拍交替抬脚（抬脚 = 该腿变短）
        let phases: [[CGFloat]] = [[0, 0], [1, 0], [0, 0], [0, 1]]
        let lift = phases[MascotMotion.beat(t, beat: 0.15) % phases.count]
        // 每踏步头轻轻颠一下；`t == 0` 正好在落地的最低点（hop 在相位 0 处为 0）
        let bob = MascotMotion.hop(t, beat: 0.15)

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 9, lift: 0)
        drawPi(
            &context, grid,
            // 头随步子小幅左右摆：两步一个来回，幅度半块
            barDx: stepped(MascotMotion.swing(t, period: 0.3) * 0.5),
            barDy: Self.crouch - 0.5 * bob,
            lifts: lift,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed) * Self.squint)
    }

    /// 待审批：双腿并拢站直、头抬起一块、眼睛瞪大（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 9, lift: 0)
        drawPi(
            &context, grid,
            barDx: 0, barDy: -1, lifts: [0, 0],
            stance: 2, eyeOpen: 1, eyeWiden: 1.2)
    }

    // MARK: - 画法

    /// 画出整只「π 小人」。
    ///
    /// - Parameters:
    ///   - barDx: 顶横（头）的横向位移（像素块，正值向右）；腿不动，所以读起来是「歪头」
    ///   - barDy: 顶横（头）的纵向位移（像素块，负值向上）；腿的顶边跟着走、脚底钉住，
    ///     腿因此自己伸缩
    ///   - lifts: 两条腿各自的抬脚量（像素块）；抬脚 = 腿变短，脚底不离地
    ///   - stance: 双腿向内并拢的量（像素块），站直时用
    ///   - eyeOpen: 睁眼程度（1 = 睁满、0 = 闭合），只压高度
    ///   - eyeWiden: 额外的睁大倍数（瞪眼用），高度与宽度一起放大
    private func drawPi(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        barDx: CGFloat, barDy: CGFloat, lifts: [CGFloat],
        stance: CGFloat = 0, eyeOpen: CGFloat = 1, eyeWiden: CGFloat = 1
    ) {
        // 两条腿：顶边挂在头底下（头抬起时腿被拉长）、底边钉在自己的脚底
        // （抬脚时腿自己变短，而不是整体上移把脚拎离地面）。
        let legTop = Self.legY + barDy
        for (index, column) in Self.legColumns.enumerated() {
            // 并拢：左腿往右、右腿往左，各挪 `stance` 块
            let inward = index == 0 ? stance : -stance
            let height = max(0.5, Self.feet[index] - legTop - lifts[index])
            MascotDraw.block(
                &context,
                grid.rect(column + inward, legTop, Self.legW, height),
                Self.leg)
        }

        // 头 / 肩：π 的顶横。画在腿之后，头抬起时盖住腿的顶边，接口看不出缝。
        MascotDraw.block(
            &context,
            grid.rect(Self.barX, Self.barY, Self.barW, Self.barH, dx: barDx, dy: barDy),
            Self.body)

        // 眼睛：从顶横里挖空（黑块），纵向以头的中线为轴缩放——
        // 眨眼时收窄成一条缝，瞪眼时同时变高变宽。
        let eyeHeight = max(0.35, Self.eyeH * eyeOpen * eyeWiden)
        let eyeWidth = Self.eyeW * eyeWiden
        let eyeTop = Self.eyeY + barDy - eyeHeight / 2
        for column in Self.eyeColumns {
            MascotDraw.block(
                &context,
                grid.rect(
                    column + barDx - (eyeWidth - Self.eyeW) / 2, eyeTop, eyeWidth, eyeHeight),
                .black)
        }
    }

    /// 位移量化到 0.25 块：亚像素的平滑位移会让方块糊边。
    private func stepped(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}