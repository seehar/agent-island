//
//  TraeMascot.swift
//  AgentIsland
//
//  Trae 的像素角色（Trae IDE 与 Trae CLI 共用这一枚）。官方标记是「圆角终端屏 + 框内两枚小件」，
//  这里把那两枚小件当成眼睛，画成一只站着的终端屏机器人：
//    · 空闲：屏幕上下呼吸、眨眼，偶尔两眼睛左右扫一格 / 屏幕右下的输出条伸缩一下；
//    · 处理中：屏幕左右轻摇，两眼睛按 0.25s 的节拍反复扫视（像在看代码），输出条随打字
//      节拍在 1…5 块之间跳；
//    · 待审批：屏幕向外鼓一格（第 1…9 行、第 1…14 列）并瞪大眼睛——「跳起来」由
//      `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：屏幕 2…13 列 × 2…8 行（鼓起来时 1…14 列 × 1…9 行），
//  两条细腿从屏幕下缘踩到第 11 行的接地线上。
//

import SwiftUI

struct TraeMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// Trae 的品牌薄荷绿：屏幕边框压暗一档，内屏直接挖空（舞台底色本来就是黑的），
    /// 输出条与眼睛都用品牌色——黑底上它们就是这枚角色最亮的部分。
    private static let mint = Color(mascotHex: 0x34F48C)
    private static let rim = Color(mascotHex: 0x1FB86A)
    private static let seed = MascotMotion.stableSeed("trae")

    /// 屏幕外框（网格坐标，单位是像素块）。
    private struct Panel {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// 常态屏幕：12 块宽 × 7 块高，占第 2…8 行、第 2…13 列。
    private static let normalPanel = Panel(x: 2, y: 2, width: 12, height: 7)
    /// 待审批时向外鼓一格：占第 1…9 行、第 1…14 列。
    private static let alertPanel = Panel(x: 1, y: 1, width: 14, height: 9)

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

    /// 空闲：呼吸 + 眨眼 + 偶发小动作（两眼睛扫视 / 输出条伸缩，轮换）。
    /// `t == 0` 是静止相：屏幕回到中位、眼睛睁满、输出条 3 块。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let dy = Self.quantize(-0.5 * MascotMotion.breathe(t))

        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        var eyeShift: CGFloat = 0
        var barWidth: CGFloat = 3
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0:
                // 两眼睛同步左右扫一格
                eyeShift = Self.quantize(quirk * MascotMotion.swing(t, period: 0.6))
            default:
                // 输出条长短变一下
                barWidth = 3 + Self.quantize(2 * quirk)
            }
        }

        MascotDraw.groundLine(&context, grid, row: 11, width: 10, lift: -dy)
        drawPanel(&context, grid, Self.normalPanel, dx: 0, dy: dy)
        drawEyes(
            &context, grid, Self.normalPanel, dx: eyeShift, dy: dy,
            open: MascotMotion.blink(t, seed: Self.seed), scale: 1)
        drawBar(&context, grid, Self.normalPanel, dx: 0, dy: dy, width: barWidth)
        drawLegs(&context, grid, Self.normalPanel, dx: 0, dy: dy)
    }

    /// 处理中：屏幕左右轻摇（±0.5 块，周期 0.5s），两眼睛按 0.25s 的节拍扫视（像在看代码），
    /// 输出条随打字节拍在 1…5 块之间跳。`t == 0` 眼睛居中、输出条最短，是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let sway = Self.quantize(0.5 * MascotMotion.swing(t, period: 0.5))
        // 扫视相位：居中 → 左 → 居中 → 右，所以 t == 0 落在中间
        let scan: [CGFloat] = [0, -1, 0, 1]
        let eyeShift = scan[MascotMotion.beat(t, beat: 0.25) % scan.count]

        let typing = MascotMotion.typingBeat(t, cadence: 0.2, seed: Self.seed)
        let barWidth: CGFloat = typing.active ? CGFloat(2 + typing.slot % 4) : 1

        MascotDraw.groundLine(&context, grid, row: 11, width: 10)
        drawPanel(&context, grid, Self.normalPanel, dx: sway, dy: 0)
        drawEyes(&context, grid, Self.normalPanel, dx: sway + eyeShift, dy: 0, open: 1, scale: 1)
        drawBar(&context, grid, Self.normalPanel, dx: sway, dy: 0, width: barWidth)
        drawLegs(&context, grid, Self.normalPanel, dx: sway, dy: 0)
    }

    /// 待审批：屏幕向外鼓一格并瞪大眼睛（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: 11, width: 12)
        drawPanel(&context, grid, Self.alertPanel, dx: 0, dy: 0)
        drawEyes(&context, grid, Self.alertPanel, dx: 0, dy: 0, open: 1, scale: 1.5)
        drawBar(&context, grid, Self.alertPanel, dx: 0, dy: 0, width: 3)
        drawLegs(&context, grid, Self.alertPanel, dx: 0, dy: 0)
    }

    // MARK: - 画法

    /// 屏幕外框 + 挖空的内屏：四条边各让出两端的角块，拼出来就是圆角矩形。
    private func drawPanel(
        _ context: inout GraphicsContext, _ grid: MascotGrid, _ panel: Panel,
        dx: CGFloat, dy: CGFloat
    ) {
        // 上下两条边（左右各缩进一块）
        MascotDraw.block(
            &context, grid.rect(panel.x + 1, panel.y, panel.width - 2, 1, dx: dx, dy: dy), Self.rim)
        MascotDraw.block(
            &context,
            grid.rect(panel.x + 1, panel.y + panel.height - 1, panel.width - 2, 1, dx: dx, dy: dy),
            Self.rim)
        // 左右两条边（上下各缩进一块）
        MascotDraw.block(
            &context, grid.rect(panel.x, panel.y + 1, 1, panel.height - 2, dx: dx, dy: dy), Self.rim)
        MascotDraw.block(
            &context,
            grid.rect(panel.x + panel.width - 1, panel.y + 1, 1, panel.height - 2, dx: dx, dy: dy),
            Self.rim)
        // 内屏挖空：舞台是黑的，这块黑直接当屏幕底色
        MascotDraw.block(
            &context,
            grid.rect(panel.x + 1, panel.y + 1, panel.width - 2, panel.height - 2, dx: dx, dy: dy),
            .black)
    }

    /// 框内两枚小件——这枚角色的眼睛。
    ///
    /// - Parameters:
    ///   - open: 睁眼程度（0 = 闭、1 = 睁满），眨眼用它
    ///   - scale: 眼睛的放大倍率，待审批瞪眼时 >1
    private func drawEyes(
        _ context: inout GraphicsContext, _ grid: MascotGrid, _ panel: Panel,
        dx: CGFloat, dy: CGFloat, open: CGFloat, scale: CGFloat
    ) {
        let eyeWidth = Self.quantize(2 * scale)
        let eyeHeight = Self.quantize(2 * scale) * open
        let top = panel.y + 2
        let leftX = panel.x + 2
        let rightX = panel.x + panel.width - 2 - eyeWidth
        MascotDraw.block(
            &context, grid.rect(leftX, top, eyeWidth, max(0, eyeHeight), dx: dx, dy: dy), Self.mint)
        MascotDraw.block(
            &context, grid.rect(rightX, top, eyeWidth, max(0, eyeHeight), dx: dx, dy: dy), Self.mint)
    }

    /// 屏幕右下角的输出条：宽度随场景在 1…5 块之间变，像终端在往外吐字。
    private func drawBar(
        _ context: inout GraphicsContext, _ grid: MascotGrid, _ panel: Panel,
        dx: CGFloat, dy: CGFloat, width: CGFloat
    ) {
        MascotDraw.block(
            &context,
            grid.rect(panel.x + 2, panel.y + panel.height - 2, width, 1, dx: dx, dy: dy),
            Self.mint)
    }

    /// 两条细腿：顶端跟着屏幕走，脚底钉在第 11 行的接地线上（屏幕升高时腿被拉长）。
    private func drawLegs(
        _ context: inout GraphicsContext, _ grid: MascotGrid, _ panel: Panel,
        dx: CGFloat, dy: CGFloat
    ) {
        let top = panel.y + panel.height + dy
        let height = max(0.5, 11 - top)
        for column in [panel.x + 3, panel.x + panel.width - 4] {
            MascotDraw.block(&context, grid.rect(column, top, 1, height, dx: dx), Self.rim)
        }
    }

    /// 把位移量化到四分之一块：亚像素的平滑位移会让方块糊边。
    private static func quantize(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}