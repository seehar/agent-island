//
//  CodexMascot.swift
//  AgentIsland
//
//  Codex 的像素云：官方图标就是「云 + 终端提示符」，这里把提示符做成它的脸。
//    · 空闲：云轻轻飘浮，提示符的光标慢慢闪，偶尔落一滴「雨」；
//    · 处理中：光标按打字节拍闪、雨点连续下落（像云端在算东西），顶部两块随节拍
//      交替亮一下；
//    · 待审批：云鼓起来、提示符换成感叹号——「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：云占 2…8 行、最宽 12 块；雨点落在 9…11 行；接地线在第 11 行。
//

import SwiftUI

struct CodexMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 云用官方图标的冷白，提示符用 Codex 的品牌蓝紫（`AgentPalette` 的 brandColor），
    /// 下缘压暗一档当体积感。舞台底色是黑的，冷白因此在刘海里极醒目。
    private static let cloud = Color(mascotHex: 0xE8E9EE)
    /// 顶部两块的提亮档：处理中随节拍在它与 `cloud` 之间跳。
    private static let cloudLit = Color(mascotHex: 0xFFFFFF)
    private static let cloudShade = Color(mascotHex: 0xA9ADBA)
    private static let prompt = Color(mascotHex: 0x7C9CFC)

    private static let seed = MascotMotion.stableSeed("codex")

    /// 云的像素轮廓：每行「所在行 + 起始列 + 宽度」。
    private static let cloudRows: [(row: CGFloat, column: CGFloat, width: CGFloat)] = [
        (2, 4, 4), (2, 8, 4),  // 顶部两块
        (3, 3, 10),
        (4, 2, 12), (5, 2, 12), (6, 2, 12),
        (7, 3, 10),
        (8, 4, 8),
    ]

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

    /// 空闲：飘浮 + 光标慢闪 + 偶发一滴雨。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let dy = -0.6 * breath
        // 光标以 0.9s 为周期，亮三分之二的时间——比等亮等灭更像在等人输入
        let cursorOn = (t / 0.9).truncatingRemainder(dividingBy: 1) < 0.66

        MascotDraw.groundLine(&context, grid, row: 11, width: 8, lift: -dy)
        drawCloud(&context, grid, dy: dy, puff: 0, shimmer: false)
        drawPrompt(&context, grid, dy: dy, cursorOn: cursorOn)

        // 小动作：偶尔落一滴雨
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            drawDrop(&context, grid, column: 5, progress: quirk)
        }
    }

    /// 处理中：雨点连续下落、光标按打字节拍闪、云随节拍轻颠。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let hop = MascotMotion.hop(t, beat: 0.6)
        let dy = -0.7 * hop
        let typing = MascotMotion.typingBeat(t, cadence: 0.18, seed: Self.seed)

        MascotDraw.groundLine(&context, grid, row: 11, width: 8, lift: -dy)
        drawCloud(&context, grid, dy: dy, puff: 0, shimmer: typing.slot % 2 == 0)
        drawPrompt(&context, grid, dy: dy, cursorOn: typing.active)

        // 三滴雨按固定相位差循环：像云在连续输出
        for (index, column) in [CGFloat(4), 7, 10].enumerated() {
            let progress = (t * 1.6 + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            drawDrop(&context, grid, column: column, progress: progress)
        }
    }

    /// 待审批：云鼓起来，脸换成感叹号（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: 11, width: 9)
        drawCloud(&context, grid, dy: 0, puff: 1, shimmer: false)

        // 感叹号：竖条（4…5 行）+ 点（第 7 行）
        MascotDraw.block(&context, grid.rect(7, 4, 2, 2), Self.prompt)
        MascotDraw.block(&context, grid.rect(7, 7, 2, 1), Self.prompt)
    }

    // MARK: - 画法

    /// 云本体。`puff > 0` 时顶部两块上抬一格、两侧各鼓出一格（受惊的样子）。
    private func drawCloud(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, puff: CGFloat, shimmer: Bool
    ) {
        for (index, row) in Self.cloudRows.enumerated() {
            let isTop = index < 2
            let lift = isTop ? dy - puff : dy
            let widen: CGFloat = puff > 0 && row.row >= 3 && row.row <= 6 ? 1 : 0
            let width = row.width + widen * 2
            // 顶部两块在处理中随节拍提亮，读起来像云在「运算」
            let color = shimmer && isTop ? Self.cloudLit : Self.cloud
            MascotDraw.block(
                &context,
                grid.rect(row.column - widen, row.row, width, 1, dy: lift),
                color)
        }
        // 下缘压暗一档做体积感
        MascotDraw.block(&context, grid.rect(4, 8, 8, 1, dy: dy), Self.cloudShade)
    }

    /// 提示符 `>_`：一个两格高的尖括号 + 一截光标。
    private func drawPrompt(
        _ context: inout GraphicsContext, _ grid: MascotGrid, dy: CGFloat, cursorOn: Bool
    ) {
        MascotDraw.block(&context, grid.rect(4, 4, 1, 1, dy: dy), Self.prompt)
        MascotDraw.block(&context, grid.rect(5, 5, 1, 1, dy: dy), Self.prompt)
        MascotDraw.block(&context, grid.rect(4, 6, 1, 1, dy: dy), Self.prompt)
        if cursorOn {
            MascotDraw.block(&context, grid.rect(7, 6, 3, 1, dy: dy), Self.prompt)
        }
    }

    /// 一滴雨：从第 9 行落到第 11 行，`progress` 0…1 是这一段行程的进度。
    private func drawDrop(
        _ context: inout GraphicsContext, _ grid: MascotGrid, column: CGFloat, progress: CGFloat
    ) {
        let row = 9 + progress * 2
        // 落地前淡出，避免雨点在接地线上突然消失
        let opacity = min(1, (1 - progress) * 2.4)
        MascotDraw.block(
            &context, grid.rect(column, row, 1, 1), Self.cloudShade.opacity(opacity))
    }
}
