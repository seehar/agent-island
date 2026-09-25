//
//  AgentLogo.swift
//  AgentIsland
//
//  Agent 品牌标记的唯一出处：刘海头部、会话行角标与设置面板的 Agent 行都从这里
//  取标记，新增 Agent 时只需在此补一份形状。
//  除 Claude Code 沿用本应用既有的像素螃蟹外，其余标记按各 Agent 官方站点的
//  矢量形状用单色矩形重绘——刘海处只有 14pt，矢量比位图清晰，也不必随包携带
//  图片资源。每份形状的坐标即官方 SVG 的原始坐标，便于日后对照更新。
//  配色取自 AgentPalette：各 Agent 画自己的品牌色，不再统一套用 Claude 橙。
//  动效取自 AgentMotion：运动是时间的纯函数，活动状态由调用方传入。
//

import SwiftUI

struct AgentLogo: View {
    let agent: AgentKind

    /// 标记高度。宽度按各自的宽高比推导（Claude 螃蟹为高度的 66/52）。
    var size: CGFloat = 14

    /// 覆盖标记配色；nil 表示用该 Agent 的品牌色（见 AgentPalette）。
    var color: Color? = nil

    /// 当前活动状态，由调用方按会话阶段传入。
    /// nil 表示这枚标记只画一帧：角标、设置行这类密集场合不需要各自的时钟。
    var activity: AgentLogoActivity? = nil

    var body: some View {
        AgentLogoFrames(agent: agent, size: size, color: tint, activity: activity)
    }

    /// 实际配色：调用方未覆盖时用该 Agent 的品牌色。
    private var tint: Color { color ?? agent.brandColor }
}

// MARK: - 逐帧渲染

/// 只负责「按 AgentMotion 给出的这一帧把标记画出来」，时间来源交给外面：
/// 有活动状态的场合用 TimelineView 推进，其余（探针定帧、角标、设置行）只画一帧。
private struct AgentLogoFrames: View {
    let agent: AgentKind
    let size: CGFloat
    let color: Color
    let activity: AgentLogoActivity?

    @Environment(\.agentLogoStaticTime) private var staticTime

    var body: some View {
        if let t = frozenTime {
            frame(at: t, activity: activity ?? .idle)
        } else if let activity {
            TimelineView(.periodic(from: AgentMotion.epoch, by: activity.frameInterval)) {
                context in
                frame(at: context.date.timeIntervalSince(AgentMotion.epoch), activity: activity)
            }
        }
    }

    /// 需要定格的时间点：探针指定的时刻优先，其次是「这枚标记不需要动」的场合。
    private var frozenTime: Double? {
        if let staticTime { return staticTime }
        return activity == nil ? 0 : nil
    }

    private func frame(at t: Double, activity: AgentLogoActivity) -> some View {
        let motion = AgentMotion.motion(for: agent, activity: activity, at: t, size: size)
        return Glyph(agent: agent, size: size, color: color, motion: motion)
            .offset(y: motion.dy)
    }
}

// MARK: - 标记形状

/// 一枚标记的静态画法。所有运动都以 `motion` 的形式传进来，这里不做任何计时。
struct Glyph: View {
    let agent: AgentKind
    let size: CGFloat
    let color: Color
    var motion = AgentLogoMotion()

    var body: some View {
        switch agent {
        case .claudeCode:
            ClaudeCrabGlyph(size: size, color: color, walkPhase: motion.walkPhase)
        case .ohMyPi:
            PixelMark(shape: .ohMyPi, size: size, color: color, legLift: motion.legLift)
        case .pi:
            PixelMark(shape: .pi, size: size, color: color)
        case .opencode:
            PixelMark(shape: .opencode, size: size, color: color, innerOpacity: motion.innerOpacity)
        // 其余 Agent 的标记是官方资产的矢量几何（矩形组或 SVG path），
        // 由 `AgentMarks.swift` 提供、`AgentMarkView` 渲染；这些标记没有可独立
        // 运动的部件，动效只作用在整枚标记的位移上（见 AgentMotion）。
        case .codex:
            AgentMarkView(geometry: .codex, color: color, size: size)
        case .gemini:
            AgentMarkView(geometry: .gemini, color: color, size: size)
        case .cursor:
            AgentMarkView(geometry: .cursor, color: color, size: size)
        case .copilot:
            AgentMarkView(geometry: .copilot, color: color, size: size)
        case .qoder:
            AgentMarkView(geometry: .qoder, color: color, size: size)
        case .factory:
            AgentMarkView(geometry: .factory, color: color, size: size)
        case .codeBuddy:
            AgentMarkView(geometry: .codeBuddy, color: color, size: size)
        case .kimi:
            AgentMarkView(geometry: .kimi, color: color, size: size)
        case .cline:
            AgentMarkView(geometry: .cline, color: color, size: size)
        case .grok:
            AgentMarkView(geometry: .grok, color: color, size: size)
        case .trae:
            AgentMarkView(geometry: .trae, color: color, size: size)
        case .traeCli:
            AgentMarkView(geometry: .traeCli, color: color, size: size)
        case .deepSeekHarness:
            AgentMarkView(geometry: .deepSeekHarness, color: color, size: size)
        case .hermes:
            AgentMarkView(geometry: .hermes, color: color, size: size)
        }
    }
}

// MARK: - Claude Code 像素螃蟹

/// Claude Code 的像素螃蟹标记。四条腿按 `walkPhase` 交替长短，读起来就是「在走」。
private struct ClaudeCrabGlyph: View {
    let size: CGFloat
    let color: Color
    /// 走路相位；nil 表示腿脚不动
    var walkPhase: Int?

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0  // Original viewBox height is 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            /// 官方 SVG 坐标 → 画布坐标
            func place(_ rect: CGRect) -> Path {
                Path { p in p.addRect(rect) }
                    .applying(
                        CGAffineTransform(scaleX: scale, y: scale).translatedBy(
                            x: xOffset / scale, y: 0))
            }

            // 触须
            context.fill(place(CGRect(x: 0, y: 13, width: 6, height: 13)), with: .color(color))
            context.fill(place(CGRect(x: 60, y: 13, width: 6, height: 13)), with: .color(color))

            // 四条腿：高度随相位变化，但始终挂在身体底边（y=39）上
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],  // 相位 0：左前/右后落地
                [0, 0, 0, 0],  // 相位 1：过渡
                [-3, 3, -3, 3],  // 相位 2：交替到另一侧
                [0, 0, 0, 0],  // 相位 3：过渡
            ]
            let offsets =
                walkPhase.map { legHeightOffsets[$0 % legHeightOffsets.count] }
                ?? [CGFloat](repeating: 0, count: 4)
            for (index, xPos) in [CGFloat(6), 18, 42, 54].enumerated() {
                let legHeight = 13 + offsets[index]
                context.fill(
                    place(CGRect(x: xPos, y: 39, width: 6, height: legHeight)), with: .color(color))
            }

            // 身体
            context.fill(place(CGRect(x: 6, y: 0, width: 54, height: 39)), with: .color(color))

            // 眼睛（挖空，露出底色）
            context.fill(place(CGRect(x: 12, y: 13, width: 6, height: 6.5)), with: .color(.black))
            context.fill(place(CGRect(x: 48, y: 13, width: 6, height: 6.5)), with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
    }
}

// MARK: - 单色矢量标记

/// 用矩形组描述的官方标记。绘制时按矩形的包围盒等比缩放并居中，因此不同
/// viewBox 的标记在同一 `size` 下视觉高度一致。
/// `legLift` 与 `innerOpacity` 都是给具体标记用的局部动画参数。
private struct PixelMark: View {
    let shape: MarkShape
    let size: CGFloat
    let color: Color
    var legLift: (CGFloat, CGFloat) = (0, 0)
    var innerOpacity: Double = 1

    var body: some View {
        Canvas { context, canvasSize in
            let bounds = shape.bounds
            let scale = min(canvasSize.width / bounds.width, canvasSize.height / bounds.height)
            let originX = (canvasSize.width - bounds.width * scale) / 2
            let originY = (canvasSize.height - bounds.height * scale) / 2

            for part in shape.parts {
                var rect = part.rect
                // 可抬起的部分：高度缩到原来的 55%，底边保持不动
                if part.lift == .leg {
                    let lift = (part.rect.midX < bounds.midX) ? legLift.0 : legLift.1
                    rect.size.height -= lift / scale
                }
                let frame = CGRect(
                    x: originX + (rect.minX - bounds.minX) * scale,
                    y: originY + (rect.minY - bounds.minY) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
                let opacity = part.opacity * (part.isInnerWell ? innerOpacity : 1)
                context.fill(Path(frame), with: .color(color.opacity(opacity)))
            }
        }
        .frame(width: width, height: size)
    }

    private var width: CGFloat {
        let bounds = shape.bounds
        return size * bounds.width / bounds.height
    }
}

/// 标记的几何描述：`parts` 使用官方 SVG 的原始坐标，`bounds` 为各矩形的并集，
/// 用于抵消不同标记在 viewBox 内的留白差异。
private struct MarkShape {
    /// 该角色块在动效里的身分
    enum Role {
        /// 静止不动
        case solid
        /// 可抬起（π 的下半段）
        case leg
    }

    struct Part {
        let rect: CGRect
        var opacity: Double = 1
        var lift: Role = .solid
        /// OpenCode 的内孔：处理中时明暗脉冲
        var isInnerWell: Bool = false
    }

    let parts: [Part]

    var bounds: CGRect {
        parts.dropFirst().reduce(parts[0].rect) { $0.union($1.rect) }
    }
}

extension MarkShape {
    /// Oh My Pi：omp.sh 站点标识的 π 字形。
    /// 源：https://omp.sh/favicon.svg（viewBox 0 0 64 64）
    /// 两条竖笔是「腿」，处理中时交替抬起。
    static let ohMyPi = MarkShape(parts: [
        Part(rect: CGRect(x: 14, y: 16, width: 36, height: 8)),  // 顶横
        Part(rect: CGRect(x: 32, y: 24, width: 8, height: 32), lift: .leg),  // 右竖，到底
        Part(rect: CGRect(x: 18, y: 24, width: 8, height: 22), lift: .leg),  // 左竖，略短
    ])

    /// Pi：pi.dev 站点标识的像素字形。
    /// 源：https://pi.dev/favicon.svg（viewBox 0 0 560 560）
    static let pi = MarkShape(parts: [
        Part(rect: CGRect(x: 0, y: 0, width: 420, height: 140)),
        Part(rect: CGRect(x: 280, y: 140, width: 140, height: 140)),
        Part(rect: CGRect(x: 420, y: 280, width: 140, height: 280)),
        Part(rect: CGRect(x: 0, y: 140, width: 140, height: 420)),
        Part(rect: CGRect(x: 140, y: 280, width: 140, height: 140)),
    ])

    /// OpenCode：官方图标的外框加内嵌色块。内嵌色块在原图中是暗色填充，
    /// 这里用半透明还原同样的明度层次；处理中时它的不透明度会脉冲，像机器在闪眼。
    /// 源：https://opencode.ai/favicon.svg（viewBox 0 0 512 512）
    static let opencode = MarkShape(parts: [
        // 外框四边（原图为描边矩形挖空内孔）
        Part(rect: CGRect(x: 128, y: 96, width: 256, height: 64)),
        Part(rect: CGRect(x: 128, y: 352, width: 256, height: 64)),
        Part(rect: CGRect(x: 128, y: 160, width: 64, height: 192)),
        Part(rect: CGRect(x: 320, y: 160, width: 64, height: 192)),
        // 内孔下半的填充块
        Part(
            rect: CGRect(x: 192, y: 224, width: 128, height: 128), opacity: 0.55, isInnerWell: true),
    ])
}
