//
//  AgentLogo.swift
//  AgentIsland
//
//  Agent 的**静态身份标记**：会话行角标、设置面板的 Agent 行这类密集、小尺寸（10…12pt）
//  的场合用它。运行时那个会呼吸、会干活的**像素角色**在 `AgentMascot`
//  （`AgentIsland/UI/Mascots/`）——两者分工不同：这里要的是「一眼认出是哪个产品」，
//  所以沿用各家的品牌字形；那里要的是「它现在在干什么」，所以是手绘角色。
//
//  除 Claude Code 沿用本应用既有的像素螃蟹外，其余标记按各 Agent 官方站点的矢量形状用
//  单色矩形 / 官方 SVG 路径重绘——角标处只有 10pt，矢量比位图清晰，也不必随包携带图片资源。
//  每份形状的坐标即官方 SVG 的原始坐标，便于日后对照更新。
//  配色取 `AgentPalette.brandColor`。
//

import SwiftUI

struct AgentLogo: View {
    let agent: AgentKind

    /// 标记高度。宽度按各自的宽高比推导（Claude 螃蟹为高度的 66/52）。
    var size: CGFloat = 14

    /// 覆盖标记配色；nil 表示用该 Agent 的品牌色（见 AgentPalette）。
    var color: Color? = nil

    var body: some View {
        Glyph(agent: agent, size: size, color: color ?? agent.brandColor)
    }
}

// MARK: - 标记形状

/// 一枚标记的静态画法。形状本身不带动效，也不需要时钟。
struct Glyph: View {
    let agent: AgentKind
    let size: CGFloat
    let color: Color

    var body: some View {
        switch agent {
        case .claudeCode:
            ClaudeCrabGlyph(size: size, color: color)
        case .ohMyPi:
            PixelMark(shape: .ohMyPi, size: size, color: color)
        case .pi:
            PixelMark(shape: .pi, size: size, color: color)
        case .opencode:
            PixelMark(shape: .opencode, size: size, color: color)
        // 其余 Agent 的标记是官方资产的矢量几何（矩形组或 SVG path），
        // 由 `AgentMarks.swift` 提供、`AgentMarkView` 渲染。
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

/// Claude Code 的像素螃蟹标记（静态姿势：四脚落地、眼睛睁满）。
private struct ClaudeCrabGlyph: View {
    let size: CGFloat
    let color: Color

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

            // 四条腿：等长，挂在身体底边（y=39）上
            for xPos in [CGFloat(6), 18, 42, 54] {
                context.fill(
                    place(CGRect(x: xPos, y: 39, width: 6, height: 13)), with: .color(color))
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
                let rect = part.rect
                let frame = CGRect(
                    x: originX + (rect.minX - bounds.minX) * scale,
                    y: originY + (rect.minY - bounds.minY) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
                context.fill(Path(frame), with: .color(color.opacity(part.opacity)))
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
        /// 明度层次（如 OpenCode 的内嵌暗块）：用不透明度表达，不引入第二种颜色。
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
