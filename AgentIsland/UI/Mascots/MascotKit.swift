//
//  MascotKit.swift
//  AgentIsland
//
//  像素角色的公共绘制工具：网格坐标系、方块、接地阴影、取色。
//
//  角色的**画法**（有哪些部件、什么颜色、怎么动）写在各自文件里，这里只放 18 枚都会用到的
//  那几件工具——每个文件各写一套坐标换算的话，同一 size 下各角色的大小会各不相同。
//
//  网格口径（这是整套角色看起来「像一套」的关键）：所有角色都在**同一张 16×12 的网格**上画，
//  一块像素的边长恒为 `size / 16`。角色自己决定用掉网格的哪几行哪几列（主体高 9～11 行、
//  宽按形象 8～14 列），但**不改变块的大小**：宽角色与窄角色的像素一样粗，高度也接近，
//  差别只体现在身宽上。上下各留出余量给起跳与抬手。
//

import SwiftUI

/// 角色的绘制坐标系：把 16×12 的「角色网格」（左上为原点、y 向下、单位是像素块）
/// 映射到画布，按 `min(宽比, 高比)` 等比缩放并居中。
struct MascotGrid {
    /// 网格的列数（宽）。
    static let columns: CGFloat = 16
    /// 网格的行数（高）。
    static let rows: CGFloat = 12

    /// 一个像素块在画布上的边长。
    let scale: CGFloat
    /// 网格左上角在画布上的位置。
    let origin: CGPoint

    init(_ canvas: CGSize) {
        scale = min(canvas.width / Self.columns, canvas.height / Self.rows)
        origin = CGPoint(
            x: (canvas.width - Self.columns * scale) / 2,
            y: (canvas.height - Self.rows * scale) / 2)
    }

    /// 网格矩形 → 画布矩形。`dx` / `dy` 是**像素块为单位**的局部位移
    /// （角色的局部动作——抬手、抬脚、眨眼时的纵向压缩都靠它，而不是改坐标常量）。
    func rect(
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
        dx: CGFloat = 0, dy: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: origin.x + (x + dx) * scale,
            y: origin.y + (y + dy) * scale,
            width: width * scale,
            height: height * scale)
    }

    /// 整行：`rect` 的特例（行高恒为一块）。眼睛、嘴巴、条纹这类一行高的部件用它。
    func row(_ index: CGFloat, _ x: CGFloat, _ width: CGFloat, dy: CGFloat = 0) -> CGRect {
        rect(x, index, width, 1, dy: dy)
    }

    /// 水平居中：给一段宽 `width` 的部件返回它的起始列。
    func centeredX(_ width: CGFloat) -> CGFloat { (Self.columns - width) / 2 }

    /// 网格中线（列坐标）。
    static var centerColumn: CGFloat { columns / 2 }
}

/// 角色共用的绘制动作。
enum MascotDraw {
    /// 一块像素方块。
    static func block(_ context: inout GraphicsContext, _ rect: CGRect, _ color: Color) {
        context.fill(Path(rect), with: .color(color))
    }

    /// 角色脚下的接地线：一条很淡的横条，跳跃时收窄变淡，跳跃因此读得出「离地」。
    ///
    /// 用**淡白**而不是黑阴影：刘海与设置页的舞台底色本身就是黑的，黑色阴影在上面
    /// 等于没画。
    /// - Parameters:
    ///   - row: 接地线所在行（一般是最底一行）
    ///   - width: 接地线宽度（像素块）
    ///   - lift: 离地高度（像素块），>0 时收窄变淡
    static func groundLine(
        _ context: inout GraphicsContext, _ grid: MascotGrid,
        row: CGFloat, width: CGFloat, lift: CGFloat = 0
    ) {
        let shrink = max(0.4, 1 - lift * 0.08)
        let width = width * shrink
        let rect = grid.rect(grid.centeredX(width), row, width, 0.5)
        context.fill(Path(rect), with: .color(.white.opacity(0.14 * shrink)))
    }
}

extension Color {
    /// 十六进制取色（`0xRRGGBB`）。角色配色表的条目多，写十六进制比写三个浮点好核对。
    /// 这只是**作者入口**：Agent 的品牌色仍以 `AgentPalette` 为准，角色配色里至少要有一处
    /// 与 `AgentKind.brandColor` 同色系，刘海上的角色才认得出是哪个 Agent。
    init(mascotHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
