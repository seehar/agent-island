//
//  CursorMascot.swift
//  AgentIsland
//
//  Cursor 的像素立方体机器人：官方标记是黑白立方体，这里画成等距视角的方块——
//  顶面是两条斜边收出来的菱形（最亮）、左下侧面压暗、右下侧面居中，
//  中缝两侧各挖一只 1×1 的眼睛，底部两块小方块当腿。
//    · 空闲：整只立方体悬停半块地呼吸（腿跟着伸缩）、眨眼，偶尔歪一下或让顶面闪一下；
//    · 处理中：左右摇摆地走——两条腿按拍子交替抬脚、身体随步子各偏半块、顶面亮暗交替；
//    · 待审批：翻面（顶面拉到最亮、两个侧面一起压暗）并把眼睛瞪大——跳跃与光晕由
//      `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：立方体第 2…8 行 × 第 3…12 列，两条腿占第 9…10 行、底边钉在第 11 行。
//

import SwiftUI

struct CursorMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// Cursor 的品牌色是深灰 `0x606060`，在黑底上几乎看不见，所以主体一律取它的亮档：
    /// 顶面最亮、右下侧面居中、左下侧面压暗——中性灰的立体块就是 Cursor 的辨识点。
    private static let top = Color(mascotHex: 0xE4E4EA)
    /// 顶面的最亮档：走动时随拍子与 `face` 交替，待审批时定在它上面（「翻面」）。
    private static let glint = Color(mascotHex: 0xFFFFFF)
    /// 右下侧面（受光面）；走动的暗拍里顶面也落到这一档。
    private static let face = Color(mascotHex: 0xC6C6CE)
    /// 左下侧面（背光面）；待审批时右下侧面也压到这一档。
    private static let shade = Color(mascotHex: 0x7A7A86)

    private static let seed = MascotMotion.stableSeed("cursor")

    /// 立方体的轮廓：每行「所在行 + 起始列 + 宽度」。上两行收出顶面的两条斜边，
    /// 中间三行满宽（第 3…12 列），下两行再收回去——等距视角下就是一个六边形。
    private static let bodyRows: [(row: CGFloat, column: CGFloat, width: CGFloat)] = [
        (2, 6, 4),
        (3, 4, 8),
        (4, 3, 10), (5, 3, 10), (6, 3, 10),
        (7, 4, 8),
        (8, 5, 6),
    ]

    /// 顶面菱形：前三行与轮廓重合，第 5、6 行向中线收成菱形的下半（第 4 行最宽）。
    /// 菱形横跨中线（第 8 列），所以轮廓里剩下的部分正好是菱形左、右两个侧面，
    /// 它们在第 7、8 行上以中线为缝拼成立方体的正面棱。
    private static let topRows: [(row: CGFloat, column: CGFloat, width: CGFloat)] = [
        (2, 6, 4),
        (3, 4, 8),
        (4, 3, 10),
        (5, 5, 6),
        (6, 7, 2),
    ]

    /// 立方体的顶边 / 底边（网格行）、接地行，以及眼睛所在行。
    private static let bodyTop: CGFloat = 2
    private static let bodyBottom: CGFloat = 9
    private static let ground: CGFloat = 11
    private static let eyeRow: CGFloat = 7
    /// 两只眼睛的起始列（各 1 块宽），对称地贴在中缝两侧的面上。
    private static let eyeColumns: [CGFloat] = [6, 9]

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

    /// 空闲：悬停呼吸 + 眨眼 + 偶发小动作（歪一下 / 顶面闪一下）。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 吸气时整只立方体上浮半块，腿跟着拉长——读起来像在轻轻悬停
        let dy = Self.quantized(-0.5 * MascotMotion.breathe(t))
        var lean: CGFloat = 0
        var flash = false
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0: lean = quirk * 0.75
            default: flash = true
            }
        }

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8, lift: -dy)
        drawCube(
            &context, grid,
            dy: dy, shift: 0, lean: lean,
            top: flash ? Self.glint : Self.top, dimSides: false,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed),
            legs: [(x: 5, lift: 0), (x: 9, lift: 0)])
    }

    /// 处理中：左右摇摆地走。`t == 0` 是第 0 拍——双脚落地的中间态。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 每 0.3 秒一步，四拍一轮：落地 → 抬左脚 → 落地 → 抬右脚
        let step = MascotMotion.beat(t, beat: 0.3)
        let phase = step % 4
        let swing: CGFloat = 0.5

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8)
        drawCube(
            &context, grid,
            dy: 0,
            // 身体随步子左右各偏半块：第 1 拍偏右、第 3 拍偏左，落地拍回到中间
            shift: phase == 1 ? swing : (phase == 3 ? -swing : 0),
            lean: 0,
            // 顶面亮暗交替：单数拍提亮、双数拍落到暗档（`t == 0` 是双数拍）
            top: step % 2 == 0 ? Self.face : Self.glint,
            dimSides: false,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed),
            // 迈着步子：两条腿前后分开站，抬脚的那条缩成半截（脚离地一整块）
            legs: [(x: 4, lift: phase == 1 ? 1 : 0), (x: 10, lift: phase == 3 ? 1 : 0)])
    }

    /// 待审批：翻面 + 瞪眼（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 9)
        drawCube(
            &context, grid,
            dy: 0, shift: 0, lean: 0,
            top: Self.glint, dimSides: true,
            eyeOpen: 2,
            legs: [(x: 5, lift: 0), (x: 9, lift: 0)])
    }

    // MARK: - 画法

    /// 画出整只立方体机器人。
    ///
    /// - Parameters:
    ///   - dy: 整体的纵向位移（像素块，负值向上）；腿的底边始终钉在接地行上
    ///   - shift: 整体的横向位移（像素块，走动时左右摇摆用）
    ///   - lean: 倾斜量（像素块）：底边不动、越靠上的行被带得越多（歪一下用）
    ///   - top: 顶面菱形的颜色
    ///   - dimSides: 两个侧面一起压暗（翻面用）；否则右下侧面用受光档
    ///   - eyeOpen: 睁眼程度（1 = 常态的 1×1，<1 眨眼收窄，2 瞪大）
    ///   - legs: 两条腿的「起始列 + 抬脚量（像素块，1 = 整只脚离地）」
    private func drawCube(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, shift: CGFloat, lean: CGFloat,
        top: Color, dimSides: Bool, eyeOpen: CGFloat,
        legs: [(x: CGFloat, lift: CGFloat)]
    ) {
        // 腿：先画，顶边挂在立方体底边上、底边钉在接地行上，于是身体上浮时腿自己拉长；
        // 抬脚用「高度减少」表达，而不是整体上移（上移会让脚离开地面、却看不出落点）。
        let legTop = Self.bodyBottom + dy
        for leg in legs {
            let height = max(0.5, Self.ground - legTop - leg.lift)
            MascotDraw.block(&context, grid.rect(leg.x, legTop, 2, height), Self.shade)
        }

        // 立方体：逐行铺出轮廓，再把顶面菱形压在上面，菱形两侧剩下的就是两个侧面
        // （左边背光、右边受光），缝隙正好落在中线上，读起来就是一条立起来的棱。
        let seam = MascotGrid.centerColumn
        for body in Self.bodyRows {
            let dx = Self.offset(row: body.row, shift: shift, lean: lean)
            let diamond = Self.topRows.first { $0.row == body.row }
            if let diamond {
                MascotDraw.block(
                    &context, grid.rect(diamond.column, diamond.row, diamond.width, 1, dx: dx, dy: dy),
                    top)
            }

            // 菱形左边（没有菱形时整行左半）
            let leftEnd = diamond?.column ?? seam
            if leftEnd > body.column {
                MascotDraw.block(
                    &context, grid.rect(body.column, body.row, leftEnd - body.column, 1, dx: dx, dy: dy),
                    Self.shade)
            }

            // 菱形右边（没有菱形时整行右半）
            let rightStart = diamond.map { $0.column + $0.width } ?? seam
            let rightEnd = body.column + body.width
            if rightEnd > rightStart {
                MascotDraw.block(
                    &context, grid.rect(rightStart, body.row, rightEnd - rightStart, 1, dx: dx, dy: dy),
                    dimSides ? Self.shade : Self.face)
            }
        }

        // 眼睛最后画：贴在两个侧面上（中缝两侧各一只），挖空成黑
        drawEyes(
            &context, grid,
            dy: dy, dx: Self.offset(row: Self.eyeRow, shift: shift, lean: lean), open: eyeOpen)
    }

    /// 两只挖空的眼睛（`eyeColumns` 指定的列、各 1 块宽），纵向以 `eyeRow` 为中心张开。
    private func drawEyes(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, dx: CGFloat, open: CGFloat
    ) {
        let height = Self.quantized(max(0.25, open))
        let top = Self.quantized(Self.eyeRow + 0.5 - height / 2)
        for column in Self.eyeColumns {
            MascotDraw.block(&context, grid.rect(column, top, 1, height, dx: dx, dy: dy), .black)
        }
    }

    /// 第 `row` 行的横向位移（像素块）：`shift` 整只一起挪，`lean` 则底边不动、
    /// 越靠上的行偏得越多（于是立方体是「歪」过去的，不是滑过去的）。
    private static func offset(row: CGFloat, shift: CGFloat, lean: CGFloat) -> CGFloat {
        let depth = (bodyBottom - (row + 0.5)) / (bodyBottom - bodyTop)
        return quantized(shift + lean * depth)
    }

    /// 亚像素的位移会让像素块糊边，所以位移只走 0.25 块的台阶。
    private static func quantized(_ value: CGFloat) -> CGFloat {
        (value * 4).rounded() / 4
    }
}