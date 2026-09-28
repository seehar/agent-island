//
//  HermesMascot.swift
//  AgentIsland
//
//  Hermes（Nous Research）的像素角色：兜帽里只露出一对金色发光眼的小人。
//  兜帽是上宽下窄的退台轮廓（上段 10 块宽，第 8 行收口到 8 块宽），把整张脸压进暗面里，
//  脸上只剩两道金条在发光；兜帽两侧各垂一条金色鬓发（1×3），风一吹就拂起来。
//    · 空闲：呼吸起伏，眨眼时金条收窄成一条缝，偶尔歪一下头 / 甩一下鬓发；
//    · 处理中：头左右轻摇，两道眼光按节拍外扩（2…3 块），鬓发随之拂动；
//    · 待审批：兜帽向上拉高一格、眼光拉宽到 3 块（跟着整体上提一行）——「跳起来」与
//      光晕由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：兜帽第 1…9 行（10 块宽 → 8 块宽）、面部暗面 5…11 列 × 第 5…8 行、
//  两眼在第 6 行、鬓发占第 3…5 行的 2 / 13 列；接地线在第 11 行。
//

import SwiftUI

struct HermesMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 品牌金：用来画「会发光的眼」与鬓发。刘海与设置页的舞台底色是黑的，
    /// 金色因此是整枚角色唯一的亮度来源——这就是它的辨识点。
    private static let gold = Color(mascotHex: 0xFFD700)
    /// 兜帽主体。深色压在黑底上仍看得出轮廓，又暗得不会与金眼抢。
    private static let hood = Color(mascotHex: 0x3A3A46)
    private static let seed = MascotMotion.stableSeed("hermes")

    /// 兜帽的两段退台：每段「起始列 + 起始行 + 宽 + 高」。
    /// 上段 10 块宽（第 2…8 行），下面收口成 8 块宽（第 9…10 行）——底边压在第 10 行，
    /// 正好坐在第 11 行的接地线上（与其余角色同一条口径）。
    /// 列都落在整块上，兜帽的边因此不会被半格的抗锯齿糊掉。
    private static let hoodTiers: [(column: CGFloat, row: CGFloat, width: CGFloat, height: CGFloat)] =
        [
            (3, 2, 10, 7),
            (4, 9, 8, 2),
        ]

    /// 面部暗面（兜帽开口）：6×4 块，第 6…9 行。黑底上它读作「兜帽里什么也没有」。
    private static let faceRect: (column: CGFloat, row: CGFloat, width: CGFloat, height: CGFloat) = (
        5, 6, 6, 4
    )

    /// 两道金眼的内缘列：中间永远留 2 块缝，眼睛向外侧扩张——所以「两只眼」
    /// 在拉宽时也不会粘成一条光带。
    private static let leftEyeInnerEdge: CGFloat = 7
    private static let rightEyeInnerEdge: CGFloat = 9
    /// 两眼所在行（高度 1 块，纵向绕这一行的中线收放）。
    private static let eyeRow: CGFloat = 7

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

    /// 空闲：呼吸 + 眨眼 + 偶发小动作（歪头 / 甩鬓发）。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let dy = Self.step(-0.5 * breath)

        // 小动作三选一：左歪头 / 右歪头 / 甩一下鬓发
        var dx: CGFloat = 0
        var tuft: CGFloat = 0
        let quirk = MascotMotion.quirk(t, seed: Self.seed)
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0: dx = Self.step(-0.5 * quirk)
            case 1: dx = Self.step(0.5 * quirk)
            default: tuft = quirk
            }
        }

        // 眨眼：1 = 睁满，收到底也留 0.5 块的一条缝（金条不整条消失）
        let eyeHeight = max(0.5, (MascotMotion.blink(t, seed: Self.seed) * 2).rounded() / 2)

        MascotDraw.groundLine(&context, grid, row: 11, width: 8, lift: -dy)
        drawHead(
            &context, grid,
            dx: dx, dy: dy, eyeWidth: 2, eyeHeight: eyeHeight, tuftSway: tuft)
    }

    /// 处理中：头左右轻摇 + 眼光按节拍外扩。`t == 0` 头正、眼光满宽（3 块）。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        // 摇头：0.8s 一个来回，`t == 0` 正好在正中
        let dx = Self.step(0.5 * MascotMotion.swing(t, period: 0.8))

        // `pulse` 在每拍前 12% 冲到峰值，把相位提前「一个峰值时间」，代表帧（t == 0）
        // 因此正好落在满宽上；其余时间眼光在 2 块与 3 块之间一亮一收。
        let pulse = MascotMotion.pulse(t + 0.12 * 0.7, period: 0.7)
        let eyeWidth = (2 + pulse).rounded()

        // 鬓发比头摇得快一点，读起来像被带起来的风吹着
        let tuft = 0.5 * MascotMotion.swing(t, period: 0.4)

        MascotDraw.groundLine(&context, grid, row: 11, width: 8)
        drawHead(
            &context, grid,
            dx: dx, dy: 0, eyeWidth: eyeWidth, eyeHeight: 1, tuftSway: tuft)
    }

    /// 待审批：眼光拉宽到 3 块、两侧鬓发外张（像被惊到竖起来）。
    /// 弹跳、缩放与光晕由 `AgentMascot` 的统一层施加——这里**不做整体位移**：
    /// 整只角色上移会让它浮在自己的接地线上方，而接地线是「站在地上」的依据。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        MascotDraw.groundLine(&context, grid, row: 11, width: 8)
        drawHead(
            &context, grid,
            dx: 0, dy: 0, eyeWidth: 3, eyeHeight: 1.2, tuftSway: 0.5)
    }

    // MARK: - 画法

    /// 位移量化：像素块是这枚角色唯一的最小单位，亚像素的平滑位移会把方块边糊成
    /// 半透明的杂边。整颗头的呼吸 / 摇头 / 歪头因此都落到 0.25 块的台阶上。
    private static func step(_ blocks: CGFloat) -> CGFloat {
        (blocks * 4).rounded() / 4
    }

    /// 画出整颗头：兜帽 + 面部暗面 + 两道眼光 + 两侧鬓发。所有部件共用 `dx` / `dy`，
    /// 所以头永远是一个整体（歪头、摇头、拉高都不会散架）。
    ///
    /// - Parameters:
    ///   - dx: 整颗头的横向位移（像素块；歪头 / 摇头用）
    ///   - dy: 整颗头的纵向位移（像素块，负值向上）
    ///   - eyeWidth: 每道眼光的宽度（像素块，2…3）
    ///   - eyeHeight: 眼光的高度（像素块，眨眼时收窄）
    ///   - tuftSway: 鬓发的拂动量（像素块；左侧向上、右侧向下反向摆动）
    private func drawHead(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        dx: CGFloat, dy: CGFloat,
        eyeWidth: CGFloat, eyeHeight: CGFloat, tuftSway: CGFloat
    ) {
        // 兜帽：两段退台拼出上宽下窄的轮廓
        for tier in Self.hoodTiers {
            MascotDraw.block(
                &context,
                grid.rect(tier.column, tier.row, tier.width, tier.height, dx: dx, dy: dy),
                Self.hood)
        }

        // 面部：兜帽下缘挖出的暗面。舞台底色本就是黑的，这块黑于是读作「兜帽的开口」，
        // 脸上便只剩两道金眼的形状。
        MascotDraw.block(
            &context,
            grid.rect(
                Self.faceRect.column, Self.faceRect.row, Self.faceRect.width,
                Self.faceRect.height, dx: dx, dy: dy),
            .black)

        // 鬓发：兜帽两侧垂下的 1×3 发绺，一上一下反向拂动（小件，位移量化到 0.25 块）
        let tuft = (tuftSway * 4).rounded() / 4
        MascotDraw.block(&context, grid.rect(2, 4, 1, 3, dx: dx, dy: dy - tuft), Self.gold)
        MascotDraw.block(&context, grid.rect(13, 4, 1, 3, dx: dx, dy: dy + tuft), Self.gold)

        // 两眼：内缘不动、向外侧长；纵向绕第 6 行的中线收放（眨眼时变成一条缝）。
        let eyeY = Self.eyeRow + 0.5 - eyeHeight / 2
        MascotDraw.block(
            &context,
            grid.rect(
                Self.leftEyeInnerEdge - eyeWidth, eyeY, eyeWidth, eyeHeight, dx: dx, dy: dy),
            Self.gold)
        MascotDraw.block(
            &context,
            grid.rect(
                Self.rightEyeInnerEdge, eyeY, eyeWidth, eyeHeight, dx: dx, dy: dy),
            Self.gold)
    }
}