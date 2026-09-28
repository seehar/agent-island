//
//  OpenCodeMascot.swift
//  AgentIsland
//
//  OpenCode 的像素终端屏。官方标记就是「外框 + 内孔色块」，这里把内孔做成它的脸：
//  近白的外框里空出一块黑屏幕，屏幕上只有一只眼睛和一截终端光标条。
//    · 空闲：屏幕整体 0…1 块呼吸（两只脚钉在地上、腿跟着伸缩）、眨眼，偶尔抖一下光标条 /
//      整块轻晃 / 屏幕闪一下；
//    · 处理中：屏幕按打字节拍刷新（代码在刷屏）、光标条在 1…4 块之间跳、两只脚交替抬一下；
//    · 待审批：外框向外鼓一格撑大自己、眼睛横向瞪开、光标条一直拉到内孔右壁。
//
//  网格占用（16×12）：外框第 2…13 列 × 第 2…9 行、两只脚在第 2 / 13 列（底边钉在第 11 行）；
//  警戒姿态下外框鼓成第 1…14 列 × 第 1…10 行，脚收进框内。
//

import SwiftUI

struct OpenCodeMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 外壳：OpenCode 的品牌色是中性灰（`AgentPalette` 的 brandColor `0x8E8B8B`），它在纯黑
    /// 舞台上太暗、刘海里会糊成一团，所以主体取同一色相的亮档——明度抬起来，灰调不变。
    private static let shell = Color(mascotHex: 0xD9D9DE)
    /// 品牌灰本体：光标条与两只脚用它；屏幕点亮时也是外壳色压暗到它下面一档。
    private static let brand = Color(mascotHex: 0x8E8B8B)
    private static let seed = MascotMotion.stableSeed("opencode")

    /// 外框（描边矩形）：第 2…13 列 × 第 2…9 行，四条边各 1 块宽。
    private static let frameX: CGFloat = 2
    private static let frameY: CGFloat = 2
    private static let frameWidth: CGFloat = 12
    private static let frameHeight: CGFloat = 8

    /// 内孔（屏幕）：外框向内缩一格，即第 3…12 列 × 第 3…8 行。
    private static let holeX: CGFloat = frameX + 1
    private static let holeY: CGFloat = frameY + 1
    private static let holeWidth: CGFloat = frameWidth - 2
    private static let holeHeight: CGFloat = frameHeight - 2

    /// 眼睛：2 块宽 × 2 块高，钉在屏幕的居中偏左（第 4…5 行、第 5…6 列），
    /// 与右下方那截光标条左右错开。
    private static let eyeCenterX: CGFloat = 6
    private static let eyeCenterY: CGFloat = 5

    /// 光标条：2 块宽，钉在第 8 列、第 6…7 行，向右伸缩。
    private static let cursorColumn: CGFloat = 8
    private static let cursorTop: CGFloat = 6
    private static let cursorHeight: CGFloat = 2

    /// 接地行：两只脚的底边钉在这一行。
    private static let ground: CGFloat = 11

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

    /// 空闲：屏幕整体呼吸 + 眨眼 + 偶发一次小动作。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)

        var dx: CGFloat = 0
        var glow: CGFloat = 0
        var cursorWidth: CGFloat = 2
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0:
                // 抖一下光标条：一截光标在屏上戳了戳（宽度量化到 0.25 块，边缘不糊）
                cursorWidth = 2 + (1.5 * quirk * 4).rounded() / 4
            case 1:
                // 整块轻晃：左右各挪一整块。取整块而不是亚像素——半块的位移会把外框的
                // 竖边糊成两条半亮的列，方块就不成方块了。
                dx = (MascotMotion.swing(t, period: 0.28) * quirk).rounded()
            default:
                // 屏幕闪一下
                glow = quirk
            }
        }

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8)
        drawChassis(&context, grid, dx: dx, dy: -breath, grow: 0, glow: glow)
        drawFace(
            &context, grid, dx: dx, dy: -breath,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed), eyeWide: 1, cursorWidth: cursorWidth)
        drawLegs(&context, grid, dx: dx, dy: -breath, lifts: [0, 0])
    }

    /// 处理中：屏幕按打字节拍刷新、光标条跟着跳、两只脚交替抬一下。
    /// `t == 0` 落在「屏幕较暗的那半拍 + 光标 2.5 块 + 两脚落地」的中间态。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 打字节拍：屏幕逐拍明暗交替（20fps 下每拍约 3.6 帧，读起来就是屏幕在快速刷屏），
        // 光标条也跟着换宽——两者同一组拍号，像代码一行行刷过去。
        let typing = MascotMotion.typingBeat(t, cadence: 0.18, seed: Self.seed)
        // 第 0 拍取暗的那一档，所以 `t == 0` 落在闪烁的中间态；亮的那一档仍然明显暗于光标条。
        let glow: CGFloat = typing.slot % 2 == 0 ? 0.5 : 1
        // 光标条在 1…4 块之间跳：宽度与屏幕用同一组拍号取值、0.5 块一档；
        // 第 0 档取 2.5 块，所以 `t == 0` 落在中间态而不是极端值。
        let widths: [CGFloat] = [2.5, 1, 4, 1.5, 3, 4, 1, 2.5]
        let cursorWidth = widths[typing.slot % widths.count]
        // 两只脚按更慢的拍子交替离地：一拍抬左脚、下一拍抬右脚，其余时间都踩在地上。
        let step = MascotMotion.beat(t, beat: 0.34) % 4
        let lifts: [CGFloat] = step == 1 ? [1, 0] : (step == 3 ? [0, 1] : [0, 0])

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 8)
        drawChassis(&context, grid, dx: 0, dy: 0, grow: 0, glow: glow)
        drawFace(
            &context, grid, dx: 0, dy: 0,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed), eyeWide: 1, cursorWidth: cursorWidth)
        drawLegs(&context, grid, dx: 0, dy: 0, lifts: lifts)
    }

    /// 待审批：外框向外鼓一格、眼睛瞪开、光标条拉满（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 向外鼓一格：外框从第 2…13 列 × 第 2…9 行撑成第 1…14 列 × 第 1…10 行。
        let grow: CGFloat = 1
        // 光标条拉满：一直顶到内孔右壁。内壁跟着外框一起外移了一格，所以宽度按几何推出来。
        let cursorWidth = Self.holeX + Self.holeWidth + grow - Self.cursorColumn

        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 10)
        drawChassis(&context, grid, dx: 0, dy: 0, grow: grow, glow: 0)
        drawFace(&context, grid, dx: 0, dy: 0, eyeOpen: 1, eyeWide: 1.75, cursorWidth: cursorWidth)
    }

    // MARK: - 画法

    /// 外壳：内孔（黑屏幕）+ 外框四条边。
    ///
    /// - Parameters:
    ///   - dx / dy: 屏幕整体的位移（像素块，负的 dy 是上浮）
    ///   - grow: 外框向外鼓出的格数（0 = 常态，1 = 待审批的警戒姿态）
    ///   - glow: 屏幕被点亮的程度（0…1），处理中的「代码刷屏」与空闲的「闪一下」共用
    private func drawChassis(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dx: CGFloat, dy: CGFloat, grow: CGFloat, glow: CGFloat
    ) {
        let screen = grid.rect(
            Self.holeX - grow, Self.holeY - grow,
            Self.holeWidth + 2 * grow, Self.holeHeight + 2 * grow, dx: dx, dy: dy)

        // 内孔先铺一层黑：它既是 OpenCode 标记里的「内孔色块」，也把统一层的品牌色光晕挡在
        // 屏幕外——待审批时光晕在外面闪，屏里始终是深色底，眼睛与光标条才立得住。
        MascotDraw.block(&context, screen, .black)

        // 屏幕点亮：最亮也压在外壳色的 38%（实测约 96/255），比光标条的品牌灰（140/255）明显
        // 暗一档——刷屏闪得再快，屏上的眼睛与光标条也一直认得出（离屏定帧量过亮度）。
        if glow > 0 {
            MascotDraw.block(&context, screen, Self.shell.opacity(0.38 * glow))
        }

        // 外框：上 / 下 / 左 / 右四条边，各 1 块宽。
        let outerX = Self.frameX - grow
        let outerY = Self.frameY - grow
        let outerWidth = Self.frameWidth + 2 * grow
        let outerHeight = Self.frameHeight + 2 * grow
        MascotDraw.block(
            &context, grid.rect(outerX, outerY, outerWidth, 1, dx: dx, dy: dy), Self.shell)
        MascotDraw.block(
            &context, grid.rect(outerX, outerY + outerHeight - 1, outerWidth, 1, dx: dx, dy: dy),
            Self.shell)
        MascotDraw.block(
            &context, grid.rect(outerX, outerY + 1, 1, outerHeight - 2, dx: dx, dy: dy), Self.shell)
        MascotDraw.block(
            &context,
            grid.rect(outerX + outerWidth - 1, outerY + 1, 1, outerHeight - 2, dx: dx, dy: dy),
            Self.shell)
    }

    /// 脸：一只眼睛（外壳色）+ 一截终端光标条（品牌灰）。
    ///
    /// - Parameters:
    ///   - eyeOpen: 睁眼程度（1 = 睁满、0 = 闭合）。眨眼时纵向收窄，始终垂直居中
    ///   - eyeWide: 眼睛的横向倍数（1 = 2 块宽）。待审批瞪眼只往宽里长，免得纵向压到光标条
    ///   - cursorWidth: 光标条宽度（像素块），左端钉在第 8 列向右伸
    private func drawFace(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dx: CGFloat, dy: CGFloat, eyeOpen: CGFloat, eyeWide: CGFloat, cursorWidth: CGFloat
    ) {
        let eyeHeight = max(0.3, 2 * eyeOpen)
        let eyeWidth = 2 * eyeWide
        MascotDraw.block(
            &context,
            grid.rect(
                Self.eyeCenterX - eyeWidth / 2, Self.eyeCenterY - eyeHeight / 2,
                eyeWidth, eyeHeight, dx: dx, dy: dy),
            Self.shell)

        MascotDraw.block(
            &context,
            grid.rect(
                Self.cursorColumn, Self.cursorTop, cursorWidth, Self.cursorHeight, dx: dx, dy: dy),
            Self.brand)
    }

    /// 两只脚：从外框下沿（第 10 行）挂到地面（第 11 行），钉在外框底部的两个角上
    /// （第 2 列与第 13 列，正对着外框左右两条边）。
    ///
    /// 呼吸时屏幕整体上浮、这段就被拉长——脚始终踩在地上。抬脚用「变短」表达而不是
    /// 「整体上移」，上移会让脚离开地面、看起来像飘着。
    ///
    /// - Parameter lifts: 两只脚各自的抬脚量（像素块，0 = 落地）
    private func drawLegs(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dx: CGFloat, dy: CGFloat, lifts: [CGFloat]
    ) {
        let top = Self.frameY + Self.frameHeight + dy
        for (index, column) in [Self.frameX, Self.frameX + Self.frameWidth - 1].enumerated() {
            let height = max(0.3, Self.ground - top - lifts[index])
            MascotDraw.block(&context, grid.rect(column, top, 1, height, dx: dx), Self.brand)
        }
    }
}