//
//  QoderMascot.swift
//  AgentIsland
//
//  Qoder 的像素圆环机器人。官方标记是「圆环 + 一道斜向缺口」，这里把圆环竖起来当身体：
//  缺口就是它的嘴，环的上半挖两只眼睛。
//    · 空闲：环随呼吸上下各浮半块、眨眼，偶尔轻晃一下或把缺口张一张；
//    · 处理中：缺口沿圆环的 12 个扇区逐格滚转（每 0.25s 挪一格），整枚环随节拍上下颠；
//    · 待审批：缺口张大成 O 形、眼睛瞪大——整体跳跃与光晕由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：外径 11 块、环宽约 2 块，占第 1…11 行、第 3…13 列；接地线在第 11 行。
//

import SwiftUI

struct QoderMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// Qoder 的品牌绿是亮绿，在黑舞台上很醒目；内环压暗一档，做出两道环带的层次。
    /// 眼睛、环心与缺口都是**挖空**——舞台底色本来就是黑的，所以直接用黑块，不需要第四种颜色。
    private static let ring = Color(mascotHex: 0x2CDC5C)
    private static let ringInner = Color(mascotHex: 0x1FA344)
    private static let seed = MascotMotion.stableSeed("qoder")

    /// 圆环的几何：环心在第 6 行、第 8 列。`outerHalfWidths` 是每一行的水平半宽（像素块），
    /// 逐行退台拼出外圆（第 1…11 行）；`holeHalfWidths` 是同一行的挖空半宽。两者之间那一圈
    /// 就是环带：外圈品牌绿一块、内圈暗档一块。
    private static let outerHalfWidths: [CGFloat] = [2.5, 4, 4.5, 5, 5, 5, 5, 5, 4.5, 4, 2.5]
    private static let holeHalfWidths: [CGFloat] = [0, 1, 2, 2.5, 3, 3, 3, 2.5, 2, 1, 0]
    private static let ringTopRow: CGFloat = 1

    /// 缺口的 12 个扇区位置（缺口方块的左上角，像素块），按顺时针每格 30° 排布。
    /// 扇区 0 落在「下方偏右」，是滚转的初始位，也是 `t == 0` 的定格位置；
    /// 每个位置都压在环带上（否则缺口落在挖空的环心里，等于没画）。
    private static let gapCells: [(x: CGFloat, y: CGFloat)] = [
        (10.5, 8.5), (11, 6), (11, 4), (10.5, 2), (8, 0.5), (5.5, 0.5),
        (4, 2), (3, 4), (3, 6), (3.5, 8), (4, 10), (7.5, 10.5),
    ]
    /// 缺口的基准尺寸（像素块）：空闲与处理中是环上的一小段缺口，待审批时横向张成两倍。
    private static let gapWidth: CGFloat = 1.5
    private static let gapHeight: CGFloat = 1.5

    /// 眼睛在第 4 行（环的上半），左右各挖一格。环心在列 8，因此两眼的中心是列 4.5 / 11.5。
    private static let eyeRow: CGFloat = 4
    private static let eyeOffset: CGFloat = 3.5
    /// 干活时眼睛眯成的细缝：处理中的常态睁眼度（乘在眨眼的开合上）。
    private static let focusedEye: CGFloat = 0.55

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

    /// 空闲：呼吸（环上下各浮半块）+ 眨眼 + 偶发小动作（轻晃 / 缺口张一下）。
    /// `t == 0` 是最有代表性的一帧：环不偏不倚、眼睛睁着、缺口停在初始扇区。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let quirk = MascotMotion.quirk(t, seed: Self.seed)

        var ringDx: CGFloat = 0
        var mouthWidth = Self.gapWidth
        var mouthHeight = Self.gapHeight
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0:
                // 环轻晃：位移量化到 0.25 块，亚像素的平滑位移会让像素块糊边
                ringDx = Self.quantize(MascotMotion.swing(t, period: 1.6) * 0.5 * quirk)
            default:
                // 缺口张一下
                mouthWidth += 1
                mouthHeight += 0.5
            }
        }

        drawRing(
            &context, grid,
            // 纵向位移也要量化：环是**逐行铺的方块**，非整块偏移会让每一行的接缝落在半像素上，
            // 整枚环因此出现一叠横向细纹（空闲也一直在呼吸，所以这条不只是处理中要守）。
            dx: ringDx, dy: Self.quantize(-0.5 * breath),
            gapSector: 0, gapWidth: mouthWidth, gapHeight: mouthHeight,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed))
    }

    /// 处理中：缺口沿圆环滚转——每 0.25s 往前挪一格（12 格走完一圈），缺口后面拖着两格
    /// 滚过的痕迹，整枚环随节拍上下颠。不做整体旋转（像素块转了会糊），用「缺口换格」表达滚动。
    /// `t == 0` 缺口停在初始扇区、拖影跟在它后面，眼睛眯成干活时的细缝。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let sector = MascotMotion.beat(t, beat: 0.25) % Self.gapCells.count

        drawRing(
            &context, grid,
            dx: 0, dy: Self.quantize(-0.6 * MascotMotion.hop(t, beat: 0.25)),
            gapSector: sector, gapWidth: Self.gapWidth, gapHeight: Self.gapHeight,
            eyeOpen: Self.focusedEye * MascotMotion.blink(t, seed: Self.seed),
            trailSectors: [sector - 1, sector - 2])
    }

    /// 待审批：缺口横向张成两倍（读作「O 形」的大嘴）、眼睛瞪大。
    /// 跳跃、缩放与光晕由 `AgentMascot` 的统一层施加，这里只摆姿态。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        drawRing(
            &context, grid,
            dx: 0, dy: 0,
            gapSector: 0, gapWidth: Self.gapWidth * 2, gapHeight: Self.gapHeight + 0.5,
            eyeOpen: 1.5)
    }

    // MARK: - 画法

    /// 画出整枚圆环机器人。
    ///
    /// - Parameters:
    ///   - dx: 整枚环的横向位移（像素块，已量化到 0.25 块）
    ///   - dy: 整枚环的纵向位移（像素块，负值向上）；同时决定接地线的离地高度
    ///   - gapSector: 缺口所在的扇区（0…11，见 `gapCells`）
    ///   - gapWidth: 缺口的宽（像素块）
    ///   - gapHeight: 缺口的高（像素块）
    ///   - eyeOpen: 睁眼程度（1 = 睁满、0 = 闭合、>1 = 瞪大）
    ///   - trailSectors: 缺口身后留拖影的扇区（滚转用）；空数组表示不画拖影
    private func drawRing(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dx: CGFloat, dy: CGFloat,
        gapSector: Int, gapWidth: CGFloat, gapHeight: CGFloat, eyeOpen: CGFloat,
        trailSectors: [Int] = []
    ) {
        // 接地线先画，让环的底边压在它上面；环抬起时线跟着收窄变淡
        MascotDraw.groundLine(&context, grid, row: 11, width: 9, lift: max(0, -dy))

        // 环身：逐行退台。每行先铺满品牌绿，再叠内环暗档，最后把环心挖空——
        // 留下的那一圈就是环带（外圈绿一块、内圈暗一块）。
        for (index, outerHalf) in Self.outerHalfWidths.enumerated() {
            let row = Self.ringTopRow + CGFloat(index)

            MascotDraw.block(
                &context,
                grid.rect(grid.centeredX(outerHalf * 2), row, outerHalf * 2, 1, dx: dx, dy: dy),
                Self.ring)

            let innerHalf = outerHalf - 1
            MascotDraw.block(
                &context,
                grid.rect(grid.centeredX(innerHalf * 2), row, innerHalf * 2, 1, dx: dx, dy: dy),
                Self.ringInner)

            let holeHalf = Self.holeHalfWidths[index]
            if holeHalf > 0 {
                MascotDraw.block(
                    &context,
                    grid.rect(grid.centeredX(holeHalf * 2), row, holeHalf * 2, 1, dx: dx, dy: dy),
                    .black)
            }
        }

        // 滚转的拖影：缺口后面的扇区各压一小块内环暗档，读起来是「刚滚过这里」。
        for sector in trailSectors {
            let trail = Self.gapCells[(sector % Self.gapCells.count + Self.gapCells.count) % Self.gapCells.count]
            let inset = (Self.gapWidth - 1) / 2
            MascotDraw.block(
                &context,
                grid.rect(trail.x + inset, trail.y + inset, 1, 1, dx: dx, dy: dy),
                Self.ringInner)
        }

        // 缺口（嘴）：盖在环带上的一小块黑。舞台底色是黑的，于是读作「环断了一截」。
        let gap = Self.gapCells[gapSector % Self.gapCells.count]
        MascotDraw.block(
            &context, grid.rect(gap.x, gap.y, gapWidth, gapHeight, dx: dx, dy: dy), .black)

        // 眼睛：环上半的两处挖空，左右对称；眨眼时纵向收窄并保持垂直居中，瞪眼时略微放大。
        let eyeWidth = max(0.6, eyeOpen)
        let eyeHeight = max(0.3, eyeOpen)
        let eyeTop = Self.eyeRow + (1 - eyeHeight) / 2
        for side in [CGFloat(-1), 1] {
            MascotDraw.block(
                &context,
                grid.rect(
                    MascotGrid.centerColumn + side * Self.eyeOffset - eyeWidth / 2,
                    eyeTop, eyeWidth, eyeHeight, dx: dx, dy: dy),
                .black)
        }
    }

    /// 把整枚环的位移量化到 0.25 块：亚像素的平滑位移会让像素块糊边，而环是逐行铺的，
    /// 非整块偏移还会让行与行的接缝落在半像素上（表现为环上出现一叠横向细纹）。
    private static func quantize(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}