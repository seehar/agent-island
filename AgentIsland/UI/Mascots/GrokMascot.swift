//
//  GrokMascot.swift
//  AgentIsland
//
//  Grok（xAI）的像素角色：一枚「斜环机器人」。官方标记就是两道斜杠围出来的**断环**，
//  这里把环切成 8 个 2×2 块的扇段摆成一圈（八边形，每段离环心一样远），并**始终少画
//  对角上的两段**——缺了两段的环读起来正好是「两道斜杠围成一圈」；环洞里放一块暗色
//  面板当脸，脸上两只 1×1 的黑眼睛——舞台底色是黑的，眼睛只有落在灰面板上才看得见。
//    · 空闲：整环随呼吸上下浮半格、眨眼，偶尔两个缺口一起顺时针挪一格 / 两只眼睛一起横扫半格；
//    · 处理中：两个缺口绕环滚转（缺口本身就是这枚角色的招牌动作），整环按节拍颠一下，
//      提亮的那一段跟着缺口走，方向因此读得出来；
//    · 待审批：画得出的扇段各自向外推一格（环张开）、两个缺口各加宽一格、眼睛瞪大——
//      「跳起来」与光晕由 `AgentMascot` 的统一层施加。
//
//  为什么不用整枚旋转来表达「转」：环是逐块拼的，方块一转就落在半格上互相咬边，
//  27pt 下（一块 ≈ 1.7pt）会糊成一团灰、读不出环。所以滚动改成**缺口绕环走一格**：
//  块永远对齐网格，小尺寸下缺口的位置才看得清。
//
//  网格占用（16×12）：环占第 2…10 行、第 4…12 列（八边形，每段 2×2 块），环心面板
//  第 6…9 列 × 第 5…6 行，两眼在第 5 行的第 6 / 9 列；接地线在第 11 行。
//
//  槽位表是**算出来的，不是描出来的**：八个 2×2 扇段的左上角必须落在同一个格点八边形上
//  （以 (8,6) 为心，正东南西北各 3 块、四个斜角各 2 块），相邻两段才是「边贴着边」。
//  手写坐标差半格就会把环拆成四块散墨（W→SW 空一行、SW→S 空两列），小尺寸下读不出环。
//

import SwiftUI

struct GrokMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 环身：Grok / xAI 的标识是黑白斜杠，取中性灰（与 `AgentPalette` 里它的品牌档同色系）。
    private static let ring = Color(mascotHex: 0xA6A6A6)
    /// 缺口顺时针方向紧邻那一段的提亮档：环上因此有一个「亮着的方向」，缺口滚转时看得出往哪走。
    private static let ringLit = Color(mascotHex: 0xD2D2D8)
    /// 环心面板：比环身暗一档；黑底上眼睛只有落在它上面才看得见。
    private static let panel = Color(mascotHex: 0x53535B)

    private static let seed = MascotMotion.stableSeed("grok")

    /// 8 个扇段的槽位：从「东」开始顺时针，每段是 2×2 块，记的是它的左上角（列, 行）。
    /// 八段落在同一个格点八边形上（心在 (8,6)，正东/正西/正南/正北各退 3 块、四个斜角各退 2 块），
    /// 因此相邻两段都「边贴着边」，环是连的；槽位 3（西北）与 7（东南）是一对**对角基准缺口**，
    /// 这一对缺口把环切成两道斜杠。
    /// `outward` 是待审批「环张开」时这一段往外推的方向（网格轴向上的一格，块因此仍对齐网格）。
    private static let slots: [
        (column: CGFloat, row: CGFloat, outward: (x: CGFloat, y: CGFloat))
    ] = [
        (10, 5, (1, 0)),  // 0 东
        (9, 3, (1, -1)),  // 1 东北
        (7, 2, (0, -1)),  // 2 北
        (5, 3, (-1, -1)),  // 3 西北（基准缺口）
        (4, 5, (-1, 0)),  // 4 西
        (5, 7, (-1, 1)),  // 5 西南
        (7, 8, (0, 1)),  // 6 南
        (9, 7, (1, 1)),  // 7 东南（基准缺口）
    ]
    /// 两个缺口的基准槽位：对角（西北与东南），环因此读出两道斜杠。
    private static let baseGaps: [Int] = [3, 7]

    /// 环心面板（脸）：4×2 块，正好占满环洞里最宽的那一条带（列 6…9、行 5…6）——
    /// 上下的两条洞臂（西北与东南那两格的延长线）因此还露在脸上方与下方，环心仍是个洞。
    private static let panelRect: (column: CGFloat, row: CGFloat, width: CGFloat, height: CGFloat) =
        (6, 5, 4, 2)
    /// 两眼所在的网格行；两眼的**外缘**分别钉在面板的左右边缘上（列 6 与列 10）。
    private static let eyeRow: CGFloat = 5
    private static let eyeLeft: CGFloat = 6
    private static let eyeRight: CGFloat = 10

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

    /// 空闲：呼吸浮半格 + 眨眼 + 偶发小动作（两个缺口一起挪一格 / 眼睛横扫半格）。
    /// `t == 0` 恰好呼到底：不位移、不眨眼、缺口在基准位，是这套场景的代表帧。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let dy = Self.snap(-0.5 * MascotMotion.breathe(t))

        var gaps = Self.baseGaps
        var eyeShift: CGFloat = 0
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 2, seed: Self.seed) {
            case 0:
                // 两个缺口一起顺时针挪一格：只开 0.15 秒的短窗，挪一下就回来
                if MascotMotion.quirk(t, duration: 0.15, seed: Self.seed) > 0 {
                    gaps = gaps.map { ($0 + 1) % 8 }
                }
            default:
                // 两只眼睛一起横扫半格：往哪边扫按小动作的槽位轮换，同一槽位永远扫同一边
                let side: CGFloat = MascotMotion.beat(t, beat: 7) % 2 == 0 ? 1 : -1
                eyeShift = Self.snap(0.5 * quirk) * side
            }
        }

        MascotDraw.groundLine(&context, grid, row: 11, width: 9, lift: max(0, -dy))
        drawRing(
            &context, grid,
            dy: dy, gaps: gaps, widenGaps: false, explode: false,
            eyeWidth: 1, eyeHeight: max(0.25, MascotMotion.blink(t, seed: Self.seed)),
            eyeShift: eyeShift)
    }

    /// 处理中：两个缺口绕环滚转，0.3 秒走一格。
    /// `t == 0` 缺口正在基准位、整环也不颠，是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let shift = MascotMotion.beat(t, beat: 0.3) % 8
        let dy = Self.snap(-0.5 * MascotMotion.hop(t, beat: 0.3))

        MascotDraw.groundLine(&context, grid, row: 11, width: 9, lift: max(0, -dy))
        drawRing(
            &context, grid,
            dy: dy, gaps: Self.baseGaps.map { ($0 + shift) % 8 },
            widenGaps: false, explode: false,
            eyeWidth: 1, eyeHeight: max(0.25, MascotMotion.blink(t, seed: Self.seed)),
            eyeShift: 0)
    }

    /// 待审批：扇段各自向外推一格、两个缺口各加宽一格（一共少画四段）、瞪眼。
    /// 这一套姿态本来就是静止的（跳跃与光晕由统一层施加），`t == 0` 即代表帧。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: 11, width: 9)
        drawRing(
            &context, grid,
            dy: 0, gaps: Self.baseGaps, widenGaps: true, explode: true,
            eyeWidth: 1.5, eyeHeight: 1.5, eyeShift: 0)
    }

    // MARK: - 画法

    /// 画出整枚斜环：环身（八个扇段里缺两个或四个）→ 环心面板 → 眼睛。
    ///
    /// 后画的压在先画的上面，因此面板与眼睛永远是最上面那两层，缺口怎么转都盖不住脸。
    ///
    /// - Parameters:
    ///   - dy: 整环的纵向位移（像素块，负值向上）
    ///   - gaps: 两个缺口所在的槽位（0…7，基准是 3 与 7）
    ///   - widenGaps: 缺口是否各加宽一格（待审批张开时用）
    ///   - explode: 扇段是否各自向外推一格（环张开）
    ///   - eyeWidth: 眼睛边长（块）；外缘钉在面板两角，因此是向内长
    ///   - eyeHeight: 眼睛高度（块；眨眼收窄、瞪眼拉满，纵向恒居中）
    ///   - eyeShift: 两眼共同的水平位移（块）
    private func drawRing(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dy: CGFloat, gaps: [Int], widenGaps: Bool, explode: Bool,
        eyeWidth: CGFloat, eyeHeight: CGFloat, eyeShift: CGFloat
    ) {
        // 缺哪些槽位：基准是两个对角缺口，张开时每个缺口再顺时针吃掉一格
        var missing: Set<Int> = []
        for gap in gaps {
            missing.insert(gap)
            if widenGaps { missing.insert((gap + 1) % 8) }
        }

        // 每个缺口顺时针紧邻的那一个「画得出」的扇段提亮——缺口滚转时亮档跟着走，环因此有方向
        var lit: Set<Int> = []
        for gap in gaps {
            // 张开时顺时针第一格也被缺口吃掉了，亮档顺延到下一个；缺口至多吃掉 4 格，循环必然收敛
            var index = (gap + 1) % 8
            while missing.contains(index) { index = (index + 1) % 8 }
            lit.insert(index)
        }

        for (index, slot) in Self.slots.enumerated() where !missing.contains(index) {
            let push = explode ? slot.outward : (x: CGFloat(0), y: CGFloat(0))
            MascotDraw.block(
                &context,
                grid.rect(slot.column, slot.row, 2, 2, dx: push.x, dy: dy + push.y),
                lit.contains(index) ? Self.ringLit : Self.ring)
        }

        // 环心面板：环洞里的一张脸，眼睛靠它才落得住
        MascotDraw.block(
            &context,
            grid.rect(
                Self.panelRect.column, Self.panelRect.row,
                Self.panelRect.width, Self.panelRect.height, dy: dy),
            Self.panel)

        // 眼睛：外缘钉在面板两角、宽度向内长，瞪眼时因此不会溢到面板外的黑底上（溢出去等于没画）
        let eyeTop = Self.eyeRow + 0.5 - eyeHeight / 2
        MascotDraw.block(
            &context,
            grid.rect(Self.eyeLeft + eyeShift, eyeTop, eyeWidth, eyeHeight, dy: dy),
            .black)
        MascotDraw.block(
            &context,
            grid.rect(Self.eyeRight - eyeWidth + eyeShift, eyeTop, eyeWidth, eyeHeight, dy: dy),
            .black)
    }

    /// 把位移量化到 0.25 块的台阶：环是逐块拼的，亚像素的平滑位移会让方块边界糊掉。
    private static func snap(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
}