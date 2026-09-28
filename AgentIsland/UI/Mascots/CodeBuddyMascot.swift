//
//  CodeBuddyMascot.swift
//  AgentIsland
//
//  CodeBuddy 的像素角色：一条飘带机器人。圆胖的浅紫底座蹲在下方（两只挖空的眼睛就是它的脸），
//  一条亮紫的折带从座顶升起、S 形地横贯上半身，带的左右各飘一枚小件。
//    · 空闲：折带跟着呼吸一路荡过去（每块按行号错开相位），眼睛眨，小件飘一格 / 带尾抖一下轮换；
//    · 处理中：折带变成 0.6 秒一拍的波浪（每块按行号错相），底座随波轻颠，两枚小件沿带子反向滑动；
//    · 待审批：折带绷直归位、带尾向上翘一格、眼睛瞪大——「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：折带 3…13 列 × 2…8 行、小件 1.25…14.75 列、圆座 9 块宽 × 3 行高（第 8…10 行），
//  底边接地于第 11 行。
//

import SwiftUI

struct CodeBuddyMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 折带取品牌浅紫 `0xB4A4FC` 的亮档（黑底上折带必须先被看见），座体用品牌浅紫本身、
    /// 贴地那一行压暗一档做体积感。眼睛是挖空——舞台底色本来就是黑的，直接用黑块，
    /// 因此一共只有 4 种颜色。
    private static let ribbon = Color(mascotHex: 0xE0D8FF)
    private static let seat = Color(mascotHex: 0xB4A4FC)
    private static let seatShade = Color(mascotHex: 0x8E7BF0)
    private static let seed = MascotMotion.stableSeed("codebuddy")

    /// 折带：7 块「折页」（每块 2 块宽 × 1 块高）拼成一条 S 形带，横跨第 3…13 列（10 列）。
    /// 行号取到 2…7——比形象描述里的 3…7 高一行，这样「折带顶边 → 圆座底边（第 11 行）」
    /// 才够 9 行的主体高度。
    private static let ribbonSegments: [(x: CGFloat, row: CGFloat)] = [
        (3.0, 4.5), (4.33, 2.0), (5.67, 2.0),
        (7.0, 4.5), (8.33, 7.0), (9.67, 7.0), (11.0, 4.5),
    ]

    /// 圆座的三行轮廓（起始列 + 宽度）：顶行收窄，读起来是个圆胖的底。
    private static let seatRows: [(column: CGFloat, width: CGFloat)] = [
        (4.5, 7), (3.5, 9), (3.5, 9),
    ]
    /// 圆座的顶行（第 8 行），下面两行依次 +1。
    private static let seatTop: CGFloat = 8

    /// 两只挖空的眼睛：各 1 块宽、2 块高，睁眼时在座体里垂直居中。
    private static let eyeColumns: [CGFloat] = [6, 9]
    private static let eyeCenterRow: CGFloat = 9.5

    /// 两枚小件的静息位（各 1×1 块），一左一右飘在带子外侧。
    private static let trinketColumns: [CGFloat] = [1.25, 13.75]
    private static let trinketRow: CGFloat = 4.5

    /// 接地线所在行。
    private static let groundRow: CGFloat = 11

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

    /// 空闲：呼吸 + 眨眼 + 偶发小动作。呼吸是摆动的幅度包络，所以 `t == 0` 时整条带停在静息位。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let seatDy = -0.5 * breath

        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        let variant = MascotMotion.quirkVariant(t, count: 2, seed: Self.seed)
        // 小动作一：两枚小件一起飘起一格（像被风兜了一下）。
        let trinketDy = variant == 0 ? -Self.snap(quirk) : 0
        // 小动作二：带尾快速上下扇一下。
        let tailDy =
            variant == 1 ? Self.snap(0.6 * quirk * MascotMotion.swing(t, period: 0.16)) : 0

        MascotDraw.groundLine(&context, grid, row: Self.groundRow, width: 9, lift: -seatDy)
        drawSeat(
            &context, grid, dy: seatDy, eyeOpen: MascotMotion.blink(t, seed: Self.seed))

        for (index, segment) in Self.ribbonSegments.enumerated() {
            // 每块按行号错开 25 度相位，于是波形沿着带子一路走；幅度受呼吸调制。
            let wave = MascotMotion.swing(t, period: 2.4, phase: segment.row * 25)
            let isTail = index == Self.ribbonSegments.count - 1
            drawRibbonSegment(
                &context, grid, segment, dy: Self.snap(0.9 * breath * wave) + (isTail ? tailDy : 0))
        }

        drawTrinkets(&context, grid, leftDx: 0, rightDx: 0, dy: trinketDy)
    }

    /// 处理中：折带变波浪——每块按行号错相、0.6 秒一拍、振幅 0.75 块；底座随波轻颠；
    /// 两枚小件沿带子反向滑动。所有位移都扣掉了 `t == 0` 的基准值，起始帧整条带对齐静息位。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let hop = MascotMotion.hop(t, beat: 0.6)
        let seatDy = -0.5 * hop

        MascotDraw.groundLine(&context, grid, row: Self.groundRow, width: 9, lift: -seatDy)
        drawSeat(
            &context, grid, dy: seatDy, eyeOpen: MascotMotion.blink(t, seed: Self.seed))

        for segment in Self.ribbonSegments {
            let dy = Self.snap(
                0.75 * Self.waveOffset(t, period: 0.6, phase: segment.row * 40))
            drawRibbonSegment(&context, grid, segment, dy: dy)
        }

        // 两枚小件相位差 180 度：一枚滑向带子、另一枚同时退开，读起来像在运东西。
        drawTrinkets(
            &context, grid,
            leftDx: Self.snap(Self.waveOffset(t, period: 1.2, phase: 0)),
            rightDx: Self.snap(Self.waveOffset(t, period: 1.2, phase: 180)),
            dy: 0)
    }

    /// 待审批：折带绷直归位、带尾翘起一格、眼睛瞪大（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: Self.groundRow, width: 9)
        drawSeat(&context, grid, dy: 0, eyeOpen: 1.35)

        for (index, segment) in Self.ribbonSegments.enumerated() {
            // 末块是带尾：翘起一格，整条带因此「支棱起来」。
            let isTail = index == Self.ribbonSegments.count - 1
            drawRibbonSegment(&context, grid, segment, dy: isTail ? -1 : 0)
        }

        drawTrinkets(&context, grid, leftDx: 0, rightDx: 0, dy: 0)
    }

    // MARK: - 画法

    /// 圆座：三行轮廓按宽度收放，贴地那一行压暗一档做体积感；两只眼睛是挖空的黑块。
    private func drawSeat(
        _ context: inout GraphicsContext, _ grid: MascotGrid, dy: CGFloat, eyeOpen: CGFloat
    ) {
        for (index, row) in Self.seatRows.enumerated() {
            let isBottom = index == Self.seatRows.count - 1
            MascotDraw.block(
                &context,
                grid.rect(row.column, Self.seatTop + CGFloat(index), row.width, 1, dy: dy),
                isBottom ? Self.seatShade : Self.seat)
        }

        // 眼睛：挖空（黑块），眨眼时纵向收窄并保持垂直居中
        let eyeHeight = max(0.35, 2 * eyeOpen)
        let eyeTop = Self.eyeCenterRow - eyeHeight / 2
        for column in Self.eyeColumns {
            MascotDraw.block(&context, grid.rect(column, eyeTop, 1, eyeHeight, dy: dy), .black)
        }
    }

    /// 折带的一块：2 块宽 × 1 块高，`dy` 是它相对静息位的纵向位移（像素块）。
    private func drawRibbonSegment(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        _ segment: (x: CGFloat, row: CGFloat), dy: CGFloat
    ) {
        MascotDraw.block(&context, grid.rect(segment.x, segment.row, 2, 1, dy: dy), Self.ribbon)
    }

    /// 两枚小件：一左一右飘在带子外侧，各 1×1 块。
    private func drawTrinkets(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        leftDx: CGFloat, rightDx: CGFloat, dy: CGFloat
    ) {
        MascotDraw.block(
            &context,
            grid.rect(Self.trinketColumns[0], Self.trinketRow, 1, 1, dx: leftDx, dy: dy),
            Self.ribbon)
        MascotDraw.block(
            &context,
            grid.rect(Self.trinketColumns[1], Self.trinketRow, 1, 1, dx: rightDx, dy: dy),
            Self.ribbon)
    }

    // MARK: - 运动

    /// 行波位移（-1…1 的系数）：每块按 `phase` 错开相位，但减掉 `t == 0` 的基准值——
    /// 契约要求 `t == 0` 是「所有块对齐」的那一帧，直接用 `swing` 会因为相位差停在弯折姿态上。
    private static func waveOffset(_ t: CGFloat, period: CGFloat, phase: CGFloat) -> CGFloat {
        (MascotMotion.swing(t, period: period, phase: phase)
            - MascotMotion.swing(0, period: period, phase: phase)) / 2
    }

    /// 把位移对齐到 0.25 格的台阶：亚像素的平滑位移会让方块边缘糊掉。
    private static func snap(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}