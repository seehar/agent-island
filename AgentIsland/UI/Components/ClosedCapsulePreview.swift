//
//  ClosedCapsulePreview.swift
//  AgentIsland
//
//  关闭态胶囊（「灵动岛」）的实时预览：把胶囊剪影按可调范围归一的比例画成一行。
//  面板打开时关闭态胶囊被展开卡片整块盖住，因此调整胶囊宽度**没有任何别的可见反馈**
//  ——这一行就是它的反馈：数值一动，剪影跟着动（配合微调行的输入框与 ± 按钮）。
//

import SwiftUI

/// 关闭态胶囊的剪影预览。
///
/// 比例按**可调范围**归一（两个方向各自的上限正好占满预览盒），而不是按当前值取景或
/// 1:1：
/// - 按当前值取景 / 等比缩放会在两端饱和——胶囊宽度 520 与 480 画出来一样宽，
///   「越调越大」的感知恰好在最需要它的那一段丢掉；
/// - 1:1 放不下（宽度上限 520pt、高度上限 64pt 都超过一行选项的盒子）。
///
/// 于是预览盒代表整个可调区间：盒内每一点都对应一个合法取值，两个方向都单调。
struct ClosedCapsulePreview: View {
    /// 当前生效的胶囊宽度与高度（各自已由选择器夹紧）。
    let width: CGFloat
    let height: CGFloat

    /// 剪影与预览盒之间留的边距，免得贴边。
    private static let inset: CGFloat = 6

    /// 预览行的高：**两行**选项高。一行太扁——比例按可调范围归一之后，常见档（胶囊
    /// 32pt）只画得出 10pt 高，读起来像把尺子而不是胶囊。
    ///
    /// 这不额外花面板高度：宽度选择器展开后是 2 行选项 + 2 行预览 = 4 行（138pt），
    /// 与胶囊高度选择器那 4 行相同，通用页最高的单个展开因此没有变化
    /// （见 `NotchWidthSelector.visibleOptions`）。
    static var rowHeight: CGFloat { 2 * NotchMenuMetrics.optionRowHeight }

    var body: some View {
        GeometryReader { proxy in
            let box = CGSize(
                width: max(0, proxy.size.width - 2 * Self.inset),
                height: max(0, proxy.size.height - 2 * Self.inset))
            let size = Self.fittedSize(width: width, height: height, in: box)
            let shape = Self.shape(in: box)
            // 颜色不是照搬真机：胶囊是「材质 + 压暗罩」后的**近黑**块（见
            // `NotchPanelSurface`），而预览坐在卡片底（`cardFill` = 白 6% 叠黑）上，
            // 用同一层 6% 叠白等于什么都没画。因此填充取近黑、描边取三级文字色——
            // 形状靠描边读出来，观感仍是「一块贴在屏顶的胶囊」。
            // `stroke` 而不是 `strokeBorder`：`NotchShape` 只满足 `Shape`，`strokeBorder`
            // 要的是 `InsettableShape`（那里的报错会退化成「failed to produce diagnostic」，
            // 别照搬卡片那套）。
            shape
                .fill(Color.black)
                .overlay(shape.stroke(AppPalette.tertiaryText, lineWidth: 0.5))
                .frame(width: size.width, height: size.height)
                .frame(
                    width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, NotchMenuMetrics.optionHorizontalPadding)
        .animation(SettingsMotion.segment, value: width)
        .animation(SettingsMotion.segment, value: height)
        // 纯装饰：数值本身由微调行读给辅助技术，这里不重复一遍。
        .accessibilityHidden(true)
    }

    /// 归一比例：两个方向的**上限**都由它映射进预览盒。
    ///
    /// 两个上限来自选择器，而它们是主 actor 隔离的静态属性（选择器本身是 UI 层设置），
    /// 因此这组纯几何函数跟着留在主 actor 上。
    static func scale(in box: CGSize) -> CGFloat {
        min(
            box.width / NotchWidthSelector.maximumWidth,
            box.height / NotchHeightSelector.maximumHeight)
    }

    /// 剪影尺寸：拿 `scale(in:)` 乘出来的，因此任何合法取值都装得下，
    /// 且画出来的宽高都随入参单调增长（不会在某一端饱和）。
    static func fittedSize(
        width: CGFloat, height: CGFloat, in box: CGSize
    ) -> CGSize {
        let scale = scale(in: box)
        return CGSize(width: width * scale, height: height * scale)
    }

    /// 剪影的形状：与 `NotchView.currentNotchShape` 的关闭态档同一组圆角，**圆角也跟着
    /// 同一个比例缩**——不缩的话 6/14pt 的角配一块 62×10 的身子会画成一只「托盘」，
    /// 而不是缩小后的胶囊。
    static func shape(in box: CGSize) -> NotchShape {
        let scale = scale(in: box)
        return NotchShape(
            topCornerRadius: AppRadius.panelClosedTop * scale,
            bottomCornerRadius: AppRadius.panelClosedBottom * scale)
    }
}
