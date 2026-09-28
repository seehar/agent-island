//
//  ClaudeMascot.swift
//  AgentIsland
//
//  Claude Code 的像素蟹。本应用原有的身份标记就是这只螃蟹（前一代是矩形拼合的静态字形），
//  这里把它升级成会呼吸、会走、会举钳的角色：
//    · 空闲：呼吸起伏、眨眼，偶尔挥一下钳 / 挪半步 / 抖触须；
//    · 处理中：四腿交替走步（脚底钉在地上、身体起伏时腿跟着伸缩），触须随步子反向摆；
//    · 待审批：把双钳举过身体、眼睛睁大——「跳起来」由 `AgentMascot` 的统一层施加。
//
//  网格占用（16×12）：触须第 1 行、身体 3…12 列 × 2…7 行、双钳 0…2 / 13…15 列、
//  四条腿 4/6/9/11 列（底边钉在第 11 行）。
//

import SwiftUI

struct ClaudeMascot: View {
    let status: AgentMascotStatus
    /// 角色自己的时间轴（秒）。纯函数：同一 `t` 永远画出同一帧。
    let t: CGFloat
    var size: CGFloat = 27

    /// 蟹壳取 Claude 品牌橙（`AgentPalette` 的 brandColor），腿与钳压暗一档。
    /// 眼睛是挖空——舞台底色本来就是黑的，所以直接用黑块，不需要第四种颜色。
    private static let shell = Color(mascotHex: 0xD97757)
    private static let limb = Color(mascotHex: 0xA8532F)
    private static let seed = MascotMotion.stableSeed("claude")

    /// 身体与腿的纵向基准（网格行）：身体顶边、身体底边、接地行。
    private static let bodyTop: CGFloat = 2
    private static let bodyBottom: CGFloat = 8
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

    /// 空闲：呼吸 + 眨眼 + 偶发小动作。
    private func drawIdle(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let breath = MascotMotion.breathe(t)
        let quirk = MascotMotion.quirk(t, seed: Self.seed)

        var bodyDy = -0.5 * breath
        var clawDy: CGFloat = 0
        var antennaSway: CGFloat = 0
        if quirk > 0 {
            switch MascotMotion.quirkVariant(t, count: 3, seed: Self.seed) {
            case 0:
                // 挥一下钳
                clawDy = -quirk
            case 1:
                // 轻轻挪半步
                bodyDy -= quirk
            default:
                // 抖触须
                antennaSway = quirk
            }
        }

        drawCrab(
            &context, grid,
            bodyDy: bodyDy,
            clawDy: clawDy,
            antennaSway: antennaSway,
            eyeOpen: MascotMotion.blink(t, seed: Self.seed),
            legOffsets: [0, 0, 0, 0])
    }

    /// 处理中：四腿交替走步。`t == 0` 落在过渡相（四脚落地），是这套动作的代表帧。
    private func drawWorking(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        let phases: [[CGFloat]] = [
            [0, 0, 0, 0],  // 过渡：四脚落地
            [1, 0, 1, 0],  // 左前 / 右后抬脚
            [0, 0, 0, 0],
            [0, 1, 0, 1],  // 交替到另一侧
        ]
        let phase = MascotMotion.beat(t, beat: 0.15) % phases.count
        let hop = MascotMotion.hop(t, beat: 0.6)

        drawCrab(
            &context, grid,
            bodyDy: -0.6 * hop,
            clawDy: 0,
            antennaSway: MascotMotion.swing(t, period: 0.6),
            eyeOpen: MascotMotion.blink(t, seed: Self.seed),
            legOffsets: phases[phase])
    }

    /// 待审批：举钳 + 瞪眼（跳跃与光晕由统一层施加）。
    private func drawAlert(_ context: inout GraphicsContext, _ grid: MascotGrid) {
        drawCrab(
            &context, grid,
            bodyDy: 0,
            clawDy: -2,
            antennaSway: -0.5,
            eyeOpen: 1.35,
            legOffsets: [0, 0, 0, 0])
    }

    // MARK: - 画法

    /// 画出整只蟹。
    ///
    /// - Parameters:
    ///   - bodyDy: 身体的整体纵向位移（像素块，负值向上）
    ///   - clawDy: 双钳相对身体的额外位移（举钳用）
    ///   - antennaSway: 触须的反向摆动（正值 = 左侧抬起、右侧落下）
    ///   - eyeOpen: 睁眼程度（1 = 睁满、0 = 闭合）
    ///   - legOffsets: 四条腿各自的抬脚量（像素块），腿的底边因此离开地面
    private func drawCrab(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        bodyDy: CGFloat, clawDy: CGFloat, antennaSway: CGFloat,
        eyeOpen: CGFloat, legOffsets: [CGFloat]
    ) {
        // 触须：身体顶上的两根细须（各 1 块宽、2 块高），随摆动反向起伏
        MascotDraw.block(
            &context, grid.rect(5, 0, 1, 2, dy: bodyDy - antennaSway * 0.5), Self.limb)
        MascotDraw.block(
            &context, grid.rect(10, 0, 1, 2, dy: bodyDy + antennaSway * 0.5), Self.limb)

        // 双钳：身体两侧各一只（3 块宽、3 块高）
        MascotDraw.block(&context, grid.rect(0, 3, 3, 3, dy: bodyDy + clawDy), Self.limb)
        MascotDraw.block(&context, grid.rect(13, 3, 3, 3, dy: bodyDy + clawDy), Self.limb)

        // 四条腿：顶边挂在身体底边上、底边钉在地面，因此身体起伏时腿自己伸缩；
        // 抬脚用「高度减少」表达，而不是整体上移（上移会让脚离地）。
        let legTop = Self.bodyBottom + bodyDy
        for (index, column) in [CGFloat(4), 6, 9, 11].enumerated() {
            let height = max(0.5, Self.ground - legTop - legOffsets[index])
            MascotDraw.block(&context, grid.rect(column, legTop, 1, height), Self.limb)
        }

        // 身体
        MascotDraw.block(
            &context, grid.rect(3, Self.bodyTop, 10, Self.bodyBottom - Self.bodyTop, dy: bodyDy),
            Self.shell)

        // 眼睛：挖空（黑块），眨眼时纵向收窄并保持垂直居中
        let eyeHeight = max(0.35, 2 * eyeOpen)
        let eyeTop = 3.5 - eyeHeight / 2
        MascotDraw.block(&context, grid.rect(5, eyeTop, 2, eyeHeight, dy: bodyDy), .black)
        MascotDraw.block(&context, grid.rect(9, eyeTop, 2, eyeHeight, dy: bodyDy), .black)
    }
}
