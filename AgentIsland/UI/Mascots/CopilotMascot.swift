//
//  CopilotMascot.swift
//  AgentIsland
//
//  GitHub Copilot 的像素角色。官方标记是「圆角外框 + 顶部两道开口 + 下缘两腿」，这里把它
//  画成一台护目镜脸机器人：外框占第 2…8 行、第 2…13 列，边宽一块，四角各切一格成圆角，
//  上边在中线两侧各留一道开口；框内是一整块浅灰面屏，面屏上一条深灰护目镜带横贯第 4 行，
//  中间断开一格当鼻梁；带子下方是两只挖空的黑色眼镜开口（各 3 块宽、2 块高）＝眼睛；
//  外框下缘伸出两条腿，底边钉在第 11 行的接地线上。
//    · 空闲：整体呼吸起伏、眨眼，偶尔让扫描条在护目镜上走一遭 / 双腿轮流轻敲一下；
//    · 处理中：双腿每 0.15s 交替踏步（脚底钉在地面），扫描条每 0.6s 从左扫到右，框随步子
//      轻颠；`t == 0` 是「双腿落地 + 扫描条在起点」的代表帧；
//    · 待审批：眼睛开口拉高到 3 块、护目镜整体上提一格（跳跃与光晕由 `AgentMascot` 施加）。
//
//  网格占用（16×12）：外框第 2…8 行、第 2…13 列，双腿 9…10 行，接地线在第 11 行。
//

import SwiftUI

struct CopilotMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 面屏取品牌灰；外框、护目镜带与双腿压暗一档做结构感；扫描条取纯白，在黑底上最跳。
    /// 眼睛是挖空——舞台底色本来就是黑的，所以直接用黑块，不需要第四种颜色。
    private static let plate = Color(mascotHex: 0xC2C2C2)
    private static let frame = Color(mascotHex: 0x8E8E96)
    private static let scan = Color(mascotHex: 0xFFFFFF)

    private static let seed = MascotMotion.stableSeed("copilot")

    /// 外框的四条边（网格坐标，左上原点）。
    private static let frameLeft: CGFloat = 2
    private static let frameRight: CGFloat = 13
    private static let frameTop: CGFloat = 2
    private static let frameBottom: CGFloat = 8
    /// 护目镜带所在行。
    private static let strapRow: CGFloat = 4
    /// 双眼纵向中心所在行。
    private static let eyeCenter: CGFloat = 6
    /// 接地行：双腿底边钉在这里。
    private static let ground: CGFloat = 11

    /// 扫描条的行程：从第 3 列走到第 12 列（共 9 块）。
    private static let scanMinX: CGFloat = 3
    private static let scanSpan: CGFloat = 9

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

    /// 空闲：呼吸 + 眨眼 + 偶发小动作。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        var scanX: CGFloat?
        var leftLift: CGFloat = 0
        var rightLift: CGFloat = 0

        // 小动作三选一：扫描条扫一遍 / 左腿轻敲 / 右腿轻敲
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0:
                // 扫描条在护目镜上从左到右走一遭
                scanX = Self.stepped(Self.scanMinX + quirk * Self.scanSpan, step: 0.5)
            case 1:
                // 左腿轻敲一下
                leftLift = Self.stepped(0.5 * quirk)
            default:
                // 右腿轻敲一下
                rightLift = Self.stepped(0.5 * quirk)
            }
        }

        drawBot(
            &context, grid,
            dy: -0.5 * MascotMotion.breathe(t),
            goggleDy: 0,
            eyeHeight: 2 * MascotMotion.blink(t, seed: Self.seed),
            leftLift: leftLift,
            rightLift: rightLift,
            scanX: scanX)
    }

    /// 处理中：双腿交替踏步、扫描条连续横扫、框随步子轻颠。
    /// `t == 0` 恰好落在第一拍（双腿落地）且扫描条在最左端，是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 四拍循环：落地 / 左腿抬 / 落地 / 右腿抬——脚步因此左右交替，t == 0 双腿落地
        let phase = MascotMotion.beat(t, beat: 0.15) % 4
        let leftLift: CGFloat = phase == 1 ? 1 : 0
        let rightLift: CGFloat = phase == 3 ? 1 : 0

        // 扫描条每 0.6s 从左扫到右：相位 -90° 让 t == 0 落在最左端的起点
        let sweep = (MascotMotion.swing(t, period: 0.6, phase: -90) + 1) / 2
        let scanX = Self.stepped(Self.scanMinX + sweep * Self.scanSpan, step: 0.5)

        drawBot(
            &context, grid,
            dy: -0.4 * MascotMotion.hop(t, beat: 0.3),
            goggleDy: 0,
            eyeHeight: 2,
            leftLift: leftLift,
            rightLift: rightLift,
            scanX: scanX)
    }

    /// 待审批：眼睛开口拉高、护目镜整体上提一格，直勾勾盯着你（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        drawBot(
            &context, grid,
            dy: 0,
            goggleDy: -1,
            eyeHeight: 3,
            leftLift: 0,
            rightLift: 0,
            scanX: nil)
    }

    // MARK: - 画法

    /// 画出整台机器人。
    ///
    /// - Parameters:
    ///   - dy: 全身的纵向位移（像素块，负值向上）
    ///   - goggleDy: 护目镜（带子 + 双眼）相对外框的额外位移（待审批时上提一格）
    ///   - eyeHeight: 眼睛开口的高度（像素块）：眨眼里收窄、瞪眼时拉高
    ///   - leftLift: 左腿的抬脚量（像素块），脚底因此离开地面
    ///   - rightLift: 右腿的抬脚量（像素块）
    ///   - scanX: 扫描条的起始列（nil 表示这一帧不画扫描条）
    private func drawBot(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, goggleDy: CGFloat, eyeHeight: CGFloat,
        leftLift: CGFloat, rightLift: CGFloat, scanX: CGFloat?
    ) {
        // 接地线：整体离地时收窄变淡
        MascotDraw.groundLine(&context, grid, row: Self.ground, width: 10, lift: -dy)

        // 面屏：外框内部的整块浅灰底，护目镜带与双眼都画在它上面
        MascotDraw.block(&context, grid.rect(3, 3, 10, 5, dy: dy), Self.plate)

        // 护目镜带：横贯第 4 行，中间断开一格（第 7 列）当鼻梁
        MascotDraw.block(
            &context, grid.rect(3, Self.strapRow, 4, 1, dy: dy + goggleDy), Self.frame)
        MascotDraw.block(
            &context, grid.rect(8, Self.strapRow, 5, 1, dy: dy + goggleDy), Self.frame)

        // 双眼：挖空的黑色开口，按 eyeCenter 纵向居中，眨眼时整体上下一起收
        let height = max(0.4, eyeHeight)
        let eyeTop = Self.eyeCenter + goggleDy - height / 2
        MascotDraw.block(&context, grid.rect(4, eyeTop, 3, height, dy: dy), .black)
        MascotDraw.block(&context, grid.rect(9, eyeTop, 3, height, dy: dy), .black)

        // 扫描条：护目镜上的一条亮带，横向走过整条带子
        if let scanX {
            MascotDraw.block(
                &context, grid.rect(scanX, Self.strapRow, 1, 3, dy: dy + goggleDy), Self.scan)
        }

        // 双腿：顶边挂在外框下缘、底边钉在地面，因此身体起伏时腿自己伸缩；
        // 抬脚用「高度减少」表达，而不是整体上移（上移会让脚离地）。
        let legTop = Self.frameBottom + dy
        for (column, lift) in [(CGFloat(5), leftLift), (CGFloat(9), rightLift)] {
            let legHeight = max(0.5, Self.ground - legTop - lift)
            MascotDraw.block(&context, grid.rect(column, legTop, 2, legHeight), Self.frame)
        }

        // 外框最后画，压在面屏与双腿之上，边缘因此始终干净
        drawFrame(&context, grid, dy: dy)
    }

    /// 外框：四条边各一块宽，四角各切一格成「圆角」，上边在中线两侧各留一道开口。
    private func drawFrame(_ context: inout GraphicsContext, _ grid: MascotGrid, dy: CGFloat) {
        // 上边：圆角切掉左右各一格，并在第 6、9 列留两道开口
        MascotDraw.block(&context, grid.rect(3, Self.frameTop, 3, 1, dy: dy), Self.frame)
        MascotDraw.block(&context, grid.rect(7, Self.frameTop, 2, 1, dy: dy), Self.frame)
        MascotDraw.block(&context, grid.rect(10, Self.frameTop, 3, 1, dy: dy), Self.frame)
        // 下边
        MascotDraw.block(
            &context, grid.rect(3, Self.frameBottom, 10, 1, dy: dy), Self.frame)
        // 左右两边：圆角使它们从第 3 行起、到第 8 行前止
        MascotDraw.block(&context, grid.rect(Self.frameLeft, 3, 1, 5, dy: dy), Self.frame)
        MascotDraw.block(&context, grid.rect(Self.frameRight, 3, 1, 5, dy: dy), Self.frame)
    }

    /// 把位移量化到 `step` 块的台阶——亚像素的平滑位移会让像素块糊边。
    private static func stepped(_ value: CGFloat, step: CGFloat = 0.25) -> CGFloat {
        (value / step).rounded() * step
    }
}