//
//  DeepSeekHarnessMascot.swift
//  AgentIsland
//
//  DeepSeek Harness 的像素机箱。官方标记是一个圆角方框（框内带一个抽屉式的内框），
//  这里把它做成一台会呼吸、会干活、会瞪人的小机箱：
//    · 空闲：整箱呼吸起伏、眨眼，滑块在开口里慢慢上下游走，偶尔灯条闪一下；
//    · 处理中：滑块在开口里从顶到底再回来（滑到底时整箱被带得轻颠一下），灯条按打字
//      节拍闪；
//    · 待审批：整箱向上拉高 1 块、眼睛瞪大、滑块顶到开口最上方——「跳起来」由
//      `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：机箱第 4…11 列（8 块宽）× 第 1…10 行（10 块高），底边钉在第 11 行
//  （接地线所在行）；顶边的灯条占 4 块、框内下半的开口 6×4、开口里的滑块 3×2。
//

import SwiftUI

struct DeepSeekHarnessMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// DeepSeek 的官方蓝做机箱主体，边框压暗一档做体积感，滑块与灯条闪亮时共用亮档。
    /// 舞台底色是黑的，所以眼睛直接挖成黑块，不需要第四种颜色。
    private static let panel = Color(mascotHex: 0x4D6BFE)
    private static let border = Color(mascotHex: 0x2F49C9)
    private static let lit = Color(mascotHex: 0x8CA0FF)
    private static let seed = MascotMotion.stableSeed("dsh")

    // MARK: - 版式常量（单位：像素块）

    /// 机箱外框：第 4…11 列（8 块宽），底边钉在第 10 行（接地在第 11 行）。
    private static let boxLeft: CGFloat = 4
    private static let boxWidth: CGFloat = 8
    private static let bottomRow: CGFloat = 10
    /// 圆角靠「顶 / 底两行左右各缩 1 块」实现。
    private static let cornerInset: CGFloat = 1
    /// 常态顶边行 / 待审批拉高后的顶边行（向上拉高 1 块）。
    private static let topY: CGFloat = 1
    private static let topYRaised: CGFloat = 0

    /// 框内下半的开口（6×4）：第 5…8 行、第 5…10 列。
    private static let openingX: CGFloat = 5
    private static let openingY: CGFloat = 5
    private static let openingWidth: CGFloat = 6
    private static let openingHeight: CGFloat = 4

    /// 滑块（3×2）：顶边在第 5…7 行之间滑动（开口上沿 → 开口下沿）。
    private static let sliderX: CGFloat = 6.5
    private static let sliderWidth: CGFloat = 3
    private static let sliderHeight: CGFloat = 2
    private static let sliderTopY: CGFloat = 5
    private static let sliderTravel: CGFloat = 2

    /// 眼睛：横向中线在第 6.5 / 9.5 列，纵向中线在第 3.5 行。
    private static let eyeLeftX: CGFloat = 6.5
    private static let eyeRightX: CGFloat = 9.5
    private static let eyeCenterY: CGFloat = 3.5

    /// 顶边灯条：4 块宽，水平居中。
    private static let lightBarWidth: CGFloat = 4

    /// 小件位移量化：对齐到 0.25 块的台阶，避免亚像素把方块糊边。
    private static func snapped(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }

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

    /// 空闲：呼吸 + 眨眼 + 滑块上下游走 + 偶发小动作（灯条闪一下）。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        var bodyDy = -0.5 * breath

        // 滑块绕着开口正中上下走 ±0.5 块
        var sliderTop = Self.snapped(
            Self.sliderTopY + Self.sliderTravel * 0.5 + MascotMotion.swing(t, period: 2.6) * 0.5)

        // 小动作：灯条闪一下，花样按周期轮换（只闪 / 带滑块上弹 / 带机箱点头）
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 1:
                sliderTop = Self.snapped(sliderTop - 0.5 * quirk)
            case 2:
                bodyDy += 0.25 * quirk
            default:
                break
            }
        }

        drawChassis(
            &context, grid,
            topY: Self.topY, bodyDy: bodyDy, sliderTop: sliderTop,
            lightBarLit: quirk > 0.35,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed), eyeScale: 1)
    }

    /// 处理中：滑块在开口里来回搬东西，滑到底时整箱轻颠、灯条按打字节拍闪。
    /// `t == 0` 时滑块落在开口正中，是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 一个 1.2s 的往返：正中 → 顶 → 底 → 正中
        let cycle: CGFloat = 1.2
        let pct = (t / cycle).truncatingRemainder(dividingBy: 1)
        let travel = MascotMotion.lerp(
            [
                (at: 0, value: 0.5), (at: 0.25, value: 0),
                (at: 0.75, value: 1), (at: 1, value: 0.5),
            ], at: pct)
        let sliderTop = Self.snapped(Self.sliderTopY + Self.sliderTravel * travel)

        // 滑块滑到底（travel 接近 1）时把机箱带得轻颠一下
        let landing = max(0, 1 - abs(travel - 1) * 6)

        // 灯条随打字节拍闪
        let typing = MascotMotion.typingBeat(t, cadence: 0.18, seed: Self.seed)

        drawChassis(
            &context, grid,
            topY: Self.topY, bodyDy: -0.35 * landing, sliderTop: sliderTop,
            lightBarLit: typing.active, eyeOpen: 1, eyeScale: 1)
    }

    /// 待审批：整箱向上拉高 1 块、眼睛瞪大、滑块顶到开口最上方（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        drawChassis(
            &context, grid,
            topY: Self.topYRaised, bodyDy: 0, sliderTop: Self.sliderTopY,
            lightBarLit: false, eyeOpen: 1, eyeScale: 1.5)
    }

    // MARK: - 画法

    /// 画出整台机箱。
    ///
    /// - Parameters:
    ///   - topY: 机箱顶边所在行（常态 1、待审批 0 —— 向上拉高 1 块）
    ///   - bodyDy: 整箱的纵向位移（像素块，负值向上）
    ///   - sliderTop: 滑块顶边所在行（开口上沿 5 → 下沿 7）
    ///   - lightBarLit: 顶边灯条是否点亮（品牌色 → 亮档）
    ///   - eyeOpen: 睁眼程度（1 = 睁满、0 = 闭合）
    ///   - eyeScale: 眼睛大小（1 = 常态、>1 = 瞪大）
    private func drawChassis(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        topY: CGFloat, bodyDy: CGFloat, sliderTop: CGFloat,
        lightBarLit: Bool, eyeOpen: CGFloat, eyeScale: CGFloat
    ) {
        let bottom = Self.bottomRow
        let left = Self.boxLeft
        let width = Self.boxWidth
        let inset = Self.cornerInset

        MascotDraw.groundLine(&context, grid, row: 11, width: width, lift: -bodyDy)

        // 主体填色：顶 / 底两行比中间窄 1 块，四角因此空出来，读作圆角
        for row in stride(from: topY, through: bottom, by: 1) {
            let corner = row == topY || row == bottom
            MascotDraw.block(
                &context,
                grid.rect(
                    left + (corner ? inset : 0), row,
                    width - (corner ? inset * 2 : 0), 1, dy: bodyDy),
                Self.panel)
        }

        // 边框：顶 / 底各 1 块厚，左右两条从顶边下一行铺到底边上一行
        MascotDraw.block(
            &context, grid.row(topY, left + inset, width - inset * 2, dy: bodyDy), Self.border)
        MascotDraw.block(
            &context, grid.row(bottom, left + inset, width - inset * 2, dy: bodyDy), Self.border)
        MascotDraw.block(
            &context, grid.rect(left, topY + 1, 1, bottom - topY - 1, dy: bodyDy), Self.border)
        MascotDraw.block(
            &context, grid.rect(left + width - 1, topY + 1, 1, bottom - topY - 1, dy: bodyDy),
            Self.border)

        // 框内下半的开口：挖黑（舞台底色本来就是黑），滑块就在这条槽里走
        MascotDraw.block(
            &context,
            grid.rect(
                Self.openingX, Self.openingY, Self.openingWidth, Self.openingHeight, dy: bodyDy),
            .black)

        // 滑块
        MascotDraw.block(
            &context,
            grid.rect(Self.sliderX, sliderTop, Self.sliderWidth, Self.sliderHeight, dy: bodyDy),
            Self.lit)

        // 顶边灯条：常态品牌色，闪亮时换亮档
        MascotDraw.block(
            &context,
            grid.row(topY, left + (width - Self.lightBarWidth) / 2, Self.lightBarWidth, dy: bodyDy),
            lightBarLit ? Self.lit : Self.panel)

        // 眼睛：挖空的黑块；眨眼时纵向收窄、瞪大时整块放大，都保持纵向中线
        let eyeWidth = eyeScale
        let eyeHeight = max(0.2, eyeScale * eyeOpen)
        for center in [Self.eyeLeftX, Self.eyeRightX] {
            MascotDraw.block(
                &context,
                grid.rect(
                    center - eyeWidth / 2, Self.eyeCenterY - eyeHeight / 2, eyeWidth, eyeHeight,
                    dy: bodyDy),
                .black)
        }
    }
}