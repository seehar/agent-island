//
//  SettingsPickerOverlay.swift
//  AgentIsland
//
//  展开的选择器列表：画成浮在内容之上的一张卡片，**不参与布局**。
//
//  为什么不就地展开（改造前的形态）：面板高度是按「内容 + 该页最高的单个展开」的解析式
//  算的（见 `NotchMenuMetrics.panelHeight`），而设置面的上限只有 640——就地展开会把通用页
//  （480 + 138 = 618，chrome 取最小的 36 就已经是 654）与智能体页（530 + 106 = 636）顶过
//  上限，最后一个档位落到隐藏滚动条的视口之外（用户只看到箭头翻转）。浮层不改变任何一页
//  的高度：面板高度因此与「有没有展开选择器」无关，也不必再按「该页最高的单个展开」核对。
//
//  摆放：贴着它所属的那一行（`payload.anchor`）。优先朝下（列表从行下边长出来，视线不回跳），
//  下面装不下而上面更宽时朝上；两侧都放不下时按可用空间夹住、列表在卡内滚动。
//
//  行的矩形由 `SettingsPickerRow` 通过 preference 上报（`background` 里的 `GeometryReader`，
//  不参与行高），因此浮层能跳出**卡片**的圆角裁切——这也是它必须挂在页面级、
//  而不能由行自己 `.overlay` 的原因（行在 `SettingsCard` 里，会在卡的边界被裁掉）。
//

import SwiftUI

/// `SettingsPickerRow` 展开时上报的载荷：行在宿主坐标空间里的矩形 + 选项列表本身。
struct SettingsPickerOverlayPayload {
    /// 行矩形（宿主坐标空间 = `NotchMenuMetrics.pickerOverlaySpace`）。
    let anchor: CGRect
    /// 行的标识（取标题）：只用来判断「还是同一行、同一个位置」。
    let identity: String
    /// 选项列表：由行自己构建（文案与选中态都在行那边），宿主只负责摆放。
    let content: AnyView
}

extension SettingsPickerOverlayPayload: Equatable {
    /// 相等 = 同一行、同一个矩形。
    ///
    /// **不比较内容**：`AnyView` 每次 body 求值都是新实例，比内容会让宿主每帧重画；
    /// 而内容的有效性由行的状态保证（行状态一变，整条链本来就会重算）。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.anchor == rhs.anchor && lhs.identity == rhs.identity
    }
}

/// 展开态的上报通道。同一时刻只有一个选择器展开（`PickerExpansion` 互斥），
/// 因此取「最后一个非空值」即可——不需要按行收集成表。
struct SettingsPickerOverlayKey: PreferenceKey {
    static let defaultValue: SettingsPickerOverlayPayload? = nil

    static func reduce(
        value: inout SettingsPickerOverlayPayload?,
        nextValue: () -> SettingsPickerOverlayPayload?
    ) {
        value = nextValue() ?? value
    }
}

extension View {
    /// 页面级浮层宿主：贴在滚动视口上，把展开的选项列表画在内容之上。
    ///
    /// 应用在设置页的 `ScrollView` 上（`NotchMenuView.detailColumn`）：坐标空间与浮层都落在
    /// 视口这一层，因此 `payload.anchor` 是「行在视口里的位置」，朝上/朝下与夹取都能直接算。
    func settingsPickerOverlay() -> some View {
        modifier(SettingsPickerOverlayHost())
    }
}

private struct SettingsPickerOverlayHost: ViewModifier {
    func body(content: Content) -> some View {
        content
            // 名字必须与 `SettingsPickerRow` 的 `.named(…)` 同一个（`NotchMenuMetrics` 里的常量）。
            .coordinateSpace(name: NotchMenuMetrics.pickerOverlaySpace)
            .overlayPreferenceValue(SettingsPickerOverlayKey.self) { payload in
                GeometryReader { proxy in
                    if let payload {
                        SettingsPickerOverlayCard(payload: payload, container: proxy.size)
                    }
                }
            }
    }
}

/// 浮层的摆放判据：朝上还是朝下、最多可用多高。
///
/// 抽成**纯函数**（而不是留在卡片里的私有计算属性）：它是「贴着行摆放」的全部依据，
/// 而边界（行在视口顶端 / 中段 / 底端、两侧都装不下）在离屏渲染里不好逐个造出来，
/// 纯函数可以直接扫一遍（见 `SettingsPickerOverlayPlacementTests`）。
nonisolated enum SettingsPickerOverlayPlacement {
    /// 行下方还剩多少空间（滚动视口内）。
    static func spaceBelow(anchor: CGRect, container: CGSize, gap: CGFloat) -> CGFloat {
        max(0, container.height - anchor.maxY - gap)
    }

    /// 行上方还剩多少空间。
    static func spaceAbove(anchor: CGRect, container: CGSize, gap: CGFloat) -> CGFloat {
        max(0, anchor.minY - gap)
    }

    /// 朝下还是朝上：优先朝下（列表从行下边长出来，视线不回跳）；下面装不下、
    /// 而上面更宽时朝上。
    static func opensDown(
        anchor: CGRect, container: CGSize, gap: CGFloat, maxHeight: CGFloat
    ) -> Bool {
        spaceBelow(anchor: anchor, container: container, gap: gap)
            >= min(maxHeight, spaceAbove(anchor: anchor, container: container, gap: gap))
    }

    /// 浮层的高度上限：朝哪一边就取那边剩下的空间，再夹到 `maxHeight`。
    static func availableHeight(
        anchor: CGRect, container: CGSize, gap: CGFloat, maxHeight: CGFloat
    ) -> CGFloat {
        let raw =
            opensDown(anchor: anchor, container: container, gap: gap, maxHeight: maxHeight)
            ? spaceBelow(anchor: anchor, container: container, gap: gap)
            : spaceAbove(anchor: anchor, container: container, gap: gap)
        return min(maxHeight, raw)
    }
}

/// 浮层卡片：贴着一行摆放的选项列表。
struct SettingsPickerOverlayCard: View {
    let payload: SettingsPickerOverlayPayload
    /// 宿主（滚动视口）的尺寸：摆放与夹取都按它算。
    let container: CGSize

    private var gap: CGFloat { NotchMenuMetrics.pickerOverlayGap }

    private var opensDown: Bool {
        SettingsPickerOverlayPlacement.opensDown(
            anchor: payload.anchor, container: container, gap: gap,
            maxHeight: NotchMenuMetrics.pickerOverlayMaxHeight)
    }

    private var availableHeight: CGFloat {
        SettingsPickerOverlayPlacement.availableHeight(
            anchor: payload.anchor, container: container, gap: gap,
            maxHeight: NotchMenuMetrics.pickerOverlayMaxHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if opensDown {
                // 固定高的空档把卡片顶到行的下边；卡片自身高度按内容取（上面那条上限
                // 只封顶、不拉高），因此不需要先量一次卡片高度。
                Spacer().frame(height: gap + payload.anchor.maxY)
                card
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                card
                // 朝上时反过来：底边钉在行的上边。
                Spacer()
                    .frame(height: gap + container.height - payload.anchor.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 左缘与**标题列**对齐（`optionIndent` + 选项行自己的内边距 = `separatorInset`），
        // 右缘留出与卡片同样的呼吸位：浮层因此读成「这一行的列表」，而不是一块盖住整页的板。
        .padding(.leading, NotchMenuMetrics.optionIndent)
        .padding(.trailing, NotchMenuMetrics.pickerOverlayHorizontalInset)
    }

    private var card: some View {
        // **装得下就按内容出图，装不下才卡内滚动**，用 `ViewThatFits` 而不是「先量高再
        // `.frame(height:)`」：`ScrollView` 自己会吃掉给它的全部高度（只给 `maxHeight` 会让
        // 4 个档位的列表下面挂着一大块空白），量高那一版还多一个毛病——首帧量不到高度时
        // 卡片只有 1pt，要等下一次布局才长到正常。
        ViewThatFits(in: .vertical) {
            cardBody
            // 列表可能比可用空间高（用户自带很多音效时）：这一支显式夹住高度、在卡内自己滚
            // （窄容器一律隐藏指示器：macOS 的 `.automatic` 是常驻轨道）。
            ScrollView(.vertical, showsIndicators: false) {
                cardBody
            }
            .frame(height: availableHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
                .fill(AppPalette.overlayFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
                .strokeBorder(AppPalette.separator, lineWidth: 0.5)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
        )
        .transition(
            .opacity.combined(with: .scale(scale: 0.97, anchor: opensDown ? .top : .bottom)))
    }

    /// 卡里的内容本身：选项列表 + 上下留白。
    private var cardBody: some View {
        VStack(spacing: 0) {
            payload.content
        }
        .padding(.top, NotchMenuMetrics.optionListTopPadding)
        .padding(.bottom, NotchMenuMetrics.optionListBottomPadding)
    }
}
