//
//  PiMascot.swift
//  AgentIsland
//
//  Pi（pi.dev）的像素角色。它的官方标记是一枚由 5 块矩形拼成的字母 P：通高的左竖笔、
//  压在竖笔顶上的横、碗右侧的一竖、碗底的一横，以及从碗右下角垂到地面的长腿。
//  这里把碗里那块挖空（内孔）当眼睛，于是这枚字形自己就有一张脸。
//    · 空闲：呼吸时上半身抬起、竖笔跟着拉长，眨眼，偶尔整枚轻晃 / 内孔整个黑一下 / 抬一下长腿；
//    · 处理中：压扁弹跳——起跳时整体抬起半块（腿被拉长），落地时再压下半块（下半段变短）；
//    · 待审批：瞪眼（黑块撑满内孔）+ 长腿抬起一格，下半段的缺口因此张开。
//
//  网格占用（16×12）：整体 8 列 × 9 行（第 4…11 列、第 2…10 行），左竖笔与长腿的
//  底边都钉在第 11 行的接地线上（起跳时竖笔自己伸缩）。
//

import SwiftUI

struct PiMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// Pi 的品牌蓝（与 `AgentPalette` 的 `.pi` 同色系）。内孔与眼睛用黑——舞台底色本来
    /// 就是黑的，「挖空」只要不画就是空的，眼睛那块黑因此不需要第三种颜色。
    private static let shell = Color(mascotHex: 0x4D9ABF)

    private static let seed = MascotMotion.stableSeed("pi")

    // MARK: - 几何（网格坐标，单位是像素块）
    //
    // 官方标记的 560×560 方框是 4×4 格，一格边长恰好是这里的 2 块像素——照这个比例摆，
    // 一枚 P 占 8 块宽、笔画粗 2 块、内孔 2×2 块，与官方同形。官方最下面那一格（左竖笔
    // 与长腿所在的一格）在这里给 3 行（第 8…10 行），长腿因此沉得下来、也抬得起来。

    /// 所有笔画的粗细（官方一格的边长）。
    private static let stroke: CGFloat = 2
    /// 左竖笔（通高）的左边缘。
    private static let stemColumn: CGFloat = 4
    /// 内孔（眼睛）的左边缘。
    private static let counterColumn: CGFloat = 6
    /// 碗的右侧（官方右上那一块）的左边缘。
    private static let bowlColumn: CGFloat = 8
    /// 长腿的左边缘。
    private static let legColumn: CGFloat = 10

    /// 顶横 / 内孔所在格 / 碗底 / 下段的上边缘。
    private static let topRow: CGFloat = 2
    private static let counterRow: CGFloat = 4
    private static let middleRow: CGFloat = 6
    /// 接地行：两根竖笔的底边都钉在这里。
    private static let ground: CGFloat = 11

    /// 顶横 / 碗底 / 内孔的高度（2 块 = 官方的一格）。
    private static let barHeight: CGFloat = 2
    /// 眼睛里那块黑睁满时的高度：2 块宽 × 1 块高，上下各留半块蓝色眼睑。
    private static let openEyeHeight: CGFloat = 1
    /// 干活的架势：处理中眼睛常驻眯着的倍数。少了它就麻烦——踏步与弹跳的第 0 帧本来
    /// 就是四平八稳站着，而呼吸呼到底、小动作又没来的空闲帧也长这样，于是「静止」档
    /// 下处理中与空闲会画成同一张图。
    private static let squint: CGFloat = 0.6

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

    /// 空闲：呼吸（上半身抬起 0…1 块、竖笔跟着伸缩）+ 眨眼 + 偶发小动作。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let quirk = MascotMotion.quirk(t, seed: Self.seed)

        var dx: CGFloat = 0
        var eyeOpen = MascotMotion.blink(t, seed: Self.seed)
        var legLift: CGFloat = 0
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0:
                // 整枚轻晃一下：随摆动左右各挪半块以内
                dx = quirk * MascotMotion.swing(t, period: 1.6) * 0.5
            case 1:
                // 内孔整个黑一下：黑块撑满那块挖空
                eyeOpen = max(eyeOpen, quirk * 2)
            default:
                // 换脚站：长腿抬起来一下
                legLift = quirk
            }
        }

        // 脚底钉在接地行上，所以呼吸只抬得动上半身：竖笔被拉长，接地线跟着收窄
        let dy = -breath
        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8, lift: max(0, -dy))
        drawLetter(&context, grid, dy: dy, dx: dx, eyeOpen: eyeOpen, legLift: legLift)
    }

    /// 处理中：压扁弹跳。起跳时整体抬起半块（竖笔被拉长），落地时再往下压半块
    /// （下半段变短，读作蹲了一下）。`t == 0` 是四平八稳站着的中间态：跳与压都还没发生。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let hop = MascotMotion.hop(t, beat: 0.55)
        let squash = MascotMotion.landingSquash(t, beat: 0.55)
        let dy = -0.5 * hop + 0.5 * squash

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8, lift: max(0, -dy))
        drawLetter(
            &context, grid, dy: dy, dx: 0,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed) * Self.squint,
            legLift: 0)
    }

    /// 待审批：瞪眼（黑块撑满内孔）+ 长腿抬起一格，下半段的缺口因此张开。
    /// 整体跳跃、缩放与光晕由 `AgentMascot` 的统一层施加。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8)
        drawLetter(&context, grid, dy: 0, dx: 0, eyeOpen: 2, legLift: 1)
    }

    // MARK: - 画法

    /// 画出整枚 P。
    ///
    /// - Parameters:
    ///   - dy: 上半身的纵向位移（像素块，负值向上）。两根竖笔的底边钉在接地行上、顶边跟着
    ///     上半身走，竖笔因此自己伸缩：上抬拉长、下压变短。
    ///   - dx: 整枚的横向位移（像素块），小动作的轻晃用。
    ///   - eyeOpen: 睁眼程度（1 = 睁满成 2 块宽 × 1 块高、0 = 收成一条缝、2 = 把内孔瞪满）。
    ///   - legLift: 长腿下端抬起的块数；抬脚用「腿变短」表达，脚底因此不离地。
    private func drawLetter(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, dx: CGFloat, eyeOpen: CGFloat, legLift: CGFloat
    ) {
        // 整枚的位移与小件的位移都量化到 1/4 块：亚像素的平滑位移会让方块糊边
        let dx = stepped(dx)
        let legLift = stepped(legLift)

        // 左竖笔：从顶横的上边缘一路通到接地行，底边钉死
        let stemTop = Self.topRow + dy
        MascotDraw.block(
            &context,
            grid.rect(Self.stemColumn, stemTop, Self.stroke, Self.ground - stemTop, dx: dx),
            Self.shell)

        // 顶横：压在左竖笔的顶上，横跨「左竖笔 + 内孔 + 碗的右侧」三格
        MascotDraw.block(
            &context,
            grid.rect(Self.stemColumn, Self.topRow + dy, Self.stroke * 3, Self.barHeight, dx: dx),
            Self.shell)

        // 碗的右侧（官方右上那一块）：内孔右边的一竖
        MascotDraw.block(
            &context,
            grid.rect(Self.bowlColumn, Self.counterRow + dy, Self.stroke, Self.barHeight, dx: dx),
            Self.shell)

        // 碗底（官方的一横）：内孔下面的一横，把碗合上
        MascotDraw.block(
            &context,
            grid.rect(
                Self.counterColumn, Self.middleRow + dy, Self.stroke, Self.barHeight, dx: dx),
            Self.shell)

        // 长腿：顶边对齐碗底的上边缘、底边钉在接地行（抬脚 = 底边上移，腿变短）
        let legTop = Self.middleRow + dy
        let legBottom = Self.ground - legLift
        MascotDraw.block(
            &context,
            grid.rect(Self.legColumn, legTop, Self.stroke, legBottom - legTop, dx: dx),
            Self.shell)

        // 眼睛就是内孔：一块黑（挖空），上下各留半块蓝眼睑。眨眼时眼睑合拢、内孔收成
        // 一条缝；瞪眼时黑块撑满内孔，那块挖空整个黑掉。
        let height = min(Self.barHeight, max(0.25, Self.openEyeHeight * eyeOpen))
        let lid = (Self.barHeight - height) / 2
        let eyeTop = Self.counterRow + dy + lid
        MascotDraw.block(
            &context, grid.rect(Self.counterColumn, eyeTop, Self.stroke, height, dx: dx), .black)
        MascotDraw.block(
            &context,
            grid.rect(Self.counterColumn, Self.counterRow + dy, Self.stroke, lid, dx: dx),
            Self.shell)
        MascotDraw.block(
            &context,
            grid.rect(Self.counterColumn, eyeTop + height, Self.stroke, lid, dx: dx),
            Self.shell)
    }

    /// 位移量化到 0.25 块。
    private func stepped(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}