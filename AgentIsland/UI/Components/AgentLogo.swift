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
//

import Combine
import SwiftUI

struct AgentLogo: View {
    let agent: AgentKind

    /// 标记高度。宽度按各自的宽高比推导（Claude 螃蟹为高度的 66/52）。
    var size: CGFloat = 14

    /// 覆盖标记配色；nil 表示用该 Agent 的品牌色（见 AgentPalette）。
    var color: Color? = nil

    /// 仅 Claude 螃蟹支持：处理中时摆动腿部。
    var animateLegs: Bool = false

    var body: some View {
        switch agent {
        case .claudeCode:
            ClaudeCrabIcon(size: size, color: tint, animateLegs: animateLegs)
        case .ohMyPi:
            PixelMark(shape: .ohMyPi, size: size, color: tint)
        case .pi:
            PixelMark(shape: .pi, size: size, color: tint)
        case .opencode:
            PixelMark(shape: .opencode, size: size, color: tint)
        }
    }

    /// 实际配色：调用方未覆盖时用该 Agent 的品牌色。
    private var tint: Color { color ?? agent.brandColor }
}

// MARK: - Claude Code 像素螃蟹

/// Claude Code 的像素螃蟹标记。腿部可摆动，表示正在处理。
private struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false

    @State private var legPhase: Int = 0

    // Timer for leg animation
    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(
        size: CGFloat = 16,
        color: Color? = nil,
        animateLegs: Bool = false
    ) {
        self.size = size
        self.color = color ?? AgentKind.claudeCode.brandColor
        self.animateLegs = animateLegs
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0  // Original viewBox height is 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            // Left antenna
            let leftAntenna = Path { p in
                p.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(
                CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            // Right antenna
            let rightAntenna = Path { p in
                p.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(
                CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            // Animated legs - alternating up/down pattern for walking effect
            // Legs stay attached to body (y=39), only height changes
            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13

            // Height offsets: positive = longer leg (down), negative = shorter leg (up)
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],  // Phase 0: alternating
                [0, 0, 0, 0],  // Phase 1: neutral
                [-3, 3, -3, 3],  // Phase 2: alternating (opposite)
                [0, 0, 0, 0],  // Phase 3: neutral
            ]

            let currentHeightOffsets =
                animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { p in
                    p.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(
                    CGAffineTransform(scaleX: scale, y: scale).translatedBy(
                        x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            // Main body
            let body = Path { p in
                p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(
                CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            // Left eye
            let leftEye = Path { p in
                p.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(
                CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            // Right eye
            let rightEye = Path { p in
                p.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(
                CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
}

// MARK: - 单色矢量标记

/// 用矩形组描述的官方标记。绘制时按矩形的包围盒等比缩放并居中，因此不同
/// viewBox 的标记在同一 `size` 下视觉高度一致。
private struct PixelMark: View {
    let shape: MarkShape
    let size: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, canvasSize in
            let bounds = shape.bounds
            let scale = min(canvasSize.width / bounds.width, canvasSize.height / bounds.height)
            let originX = (canvasSize.width - bounds.width * scale) / 2
            let originY = (canvasSize.height - bounds.height * scale) / 2

            for part in shape.parts {
                let rect = CGRect(
                    x: originX + (part.rect.minX - bounds.minX) * scale,
                    y: originY + (part.rect.minY - bounds.minY) * scale,
                    width: part.rect.width * scale,
                    height: part.rect.height * scale
                )
                context.fill(Path(rect), with: .color(color.opacity(part.opacity)))
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
    struct Part {
        let rect: CGRect
        var opacity: Double = 1
    }

    let parts: [Part]

    var bounds: CGRect {
        parts.dropFirst().reduce(parts[0].rect) { $0.union($1.rect) }
    }
}

extension MarkShape {
    /// Oh My Pi：omp.sh 站点标识的 π 字形。
    /// 源：https://omp.sh/favicon.svg（viewBox 0 0 64 64）
    static let ohMyPi = MarkShape(parts: [
        Part(rect: CGRect(x: 14, y: 16, width: 36, height: 8)),  // 顶横
        Part(rect: CGRect(x: 32, y: 24, width: 8, height: 32)),  // 右竖，到底
        Part(rect: CGRect(x: 18, y: 24, width: 8, height: 22)),  // 左竖，略短
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
    /// 这里用半透明还原同样的明度层次。
    /// 源：https://opencode.ai/favicon.svg（viewBox 0 0 512 512）
    static let opencode = MarkShape(parts: [
        // 外框四边（原图为描边矩形挖空内孔）
        Part(rect: CGRect(x: 128, y: 96, width: 256, height: 64)),
        Part(rect: CGRect(x: 128, y: 352, width: 256, height: 64)),
        Part(rect: CGRect(x: 128, y: 160, width: 64, height: 192)),
        Part(rect: CGRect(x: 320, y: 160, width: 64, height: 192)),
        // 内孔下半的填充块
        Part(rect: CGRect(x: 192, y: 224, width: 128, height: 128), opacity: 0.55),
    ])
}
