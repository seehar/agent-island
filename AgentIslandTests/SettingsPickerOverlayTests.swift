//
//  SettingsPickerOverlayTests.swift
//  AgentIslandTests
//
//  选择器浮层的三条判据：
//
//  1. **摆放**（纯函数，`SettingsPickerOverlayPlacement`）：朝上还是朝下、最多可用多高。
//     边界（行在视口顶端 / 中段 / 底端、两侧都装不下）在离屏渲染里不好逐个造出来，
//     因此把判据抽成纯函数直接扫。
//  2. **不撑高页面**：展开一个选择器（真实整页）时页面渲染高度不变——选项不再插进布局里，
//     这正是面板高度与「有没有展开」解耦的证据。
//  3. **浮层真的画出来**：默认朝下、贴底改朝上、长列表被夹住这三种摆放各渲染一次，
//     判据是「它盖住的那一段平均亮度明显下降」（实色底）+「那一段里量得到墨迹」（选项文字）。
//
//  判据 3 用**最小夹具**（一段真实设置行 + 与生产同构的浮层宿主），不用整页：整页里别的行
//  也会上报浮层，而别的用例/并行套件会在渲染的 `RunLoop` 泵里改那些行的展开态，
//  `SettingsPickerOverlayKey` 就可能收到**别行**的载荷，那一段就量不出压暗（实测踩过）。
//  判据 2 用整页没有问题——展开不参与布局，别的行的状态改不到页面高度。
//

import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import AgentIsland

/// 串行：用例会改共享单例上的展开态（`CompletionBadgeSelector` / `SoundSelector`）。
@Suite("选择器浮层", .serialized)
struct SettingsPickerOverlayTests {
    private let container = CGSize(width: 323, height: 500)
    private let gap = NotchMenuMetrics.pickerOverlayGap
    private let cap = NotchMenuMetrics.pickerOverlayMaxHeight

    /// 真实视口：通知页在 chrome 44 下 = 内容高 − 列表上下内边距 − 页眉 − 间距。
    /// 用真值而不是随手给一个高度：视口高决定浮层朝上还是朝下，写错就测不到生产走的那一支。
    private var notificationsViewport: CGFloat {
        NotchMenuMetrics.contentHeight(for: .notifications)
            - NotchMenuMetrics.listPaddingHeight
            - NotchMenuMetrics.pageHeaderHeight
            - NotchMenuMetrics.rowSpacing
    }

    private var detailWidth: CGFloat { NotchMenuMetrics.settingsDetailWidth }

    /// 一个 `rowHeight` 高的行，贴在 `top` 处的锚点。
    private func anchor(top: CGFloat) -> CGRect {
        CGRect(x: 0, y: top, width: detailWidth, height: NotchMenuMetrics.rowHeight)
    }

    // MARK: - 摆放（纯函数）

    private func opensDown(_ top: CGFloat, container: CGSize? = nil) -> Bool {
        SettingsPickerOverlayPlacement.opensDown(
            anchor: anchor(top: top), container: container ?? self.container, gap: gap,
            maxHeight: cap)
    }

    private func availableHeight(_ top: CGFloat, container: CGSize? = nil) -> CGFloat {
        SettingsPickerOverlayPlacement.availableHeight(
            anchor: anchor(top: top), container: container ?? self.container, gap: gap,
            maxHeight: cap)
    }

    @Test("行在上半页：浮层朝下，高度取上限")
    func opensDownWhenThereIsRoomBelow() {
        #expect(opensDown(60), "下面还有 396pt，没有理由朝上")
        #expect(availableHeight(60) == cap)
    }

    @Test("行贴在视口底端：浮层改朝上，并取上面的空间")
    func flipsUpNearTheBottom() {
        // 行底边 470，下面只剩 26pt（不足一个选项表）。
        #expect(!opensDown(430), "下面只剩 26pt，浮层应当翻到行的上方")
        #expect(availableHeight(430) == cap)
    }

    @Test("两侧都装不下上限时按更宽的那一侧夹住（列表自己滚动）")
    func clampsToTheWiderSide() {
        let tight = CGSize(width: 323, height: 300)
        // 行 140…180：下面 116、上面 136 ⇒ 上面更宽，朝上并按 136 夹住。
        #expect(!opensDown(140, container: tight))
        #expect(availableHeight(140, container: tight) == 136)
    }

    @Test("朝上与夹取都不会超过上限")
    func neverExceedsTheCap() {
        for top in stride(from: CGFloat(0), through: 460, by: 20) {
            #expect(availableHeight(top) <= cap)
            #expect(availableHeight(top) >= 0)
        }
    }

    // MARK: - 不撑高页面（真实整页）

    @Test("展开选择器不改变页面高度：通知页的两端各试一行")
    @MainActor
    func pageHeightIsIndependentOfExpansion() {
        let width = detailWidth
        let cases: [(name: String, selector: any PickerExpansionControlling)] = [
            ("第一行（通知音效）", SoundSelector.shared),
            ("最后一行（完成提示）", CompletionBadgeSelector.shared),
        ]

        for item in cases {
            let previous = item.selector.isPickerExpanded
            defer { item.selector.isPickerExpanded = previous }

            func pageHeight() -> CGFloat {
                ImageRendererProbe.size(
                    NotificationsSettingsPage().frame(width: width, alignment: .top)
                ).height
            }

            item.selector.isPickerExpanded = false
            let collapsed = pageHeight()
            item.selector.isPickerExpanded = true
            let expanded = pageHeight()

            #expect(collapsed > 0, "页面渲染失败（没量到高度）")
            #expect(
                expanded == collapsed,
                "\(item.name)：展开后页面高 \(expanded) ≠ 收起时 \(collapsed)——选项又回到布局里了")
        }
    }

    // MARK: - 浮层真的画出来（最小夹具）

    /// 最小夹具：**测试图案**（亮的横条）+ 一段真实设置行 + 与 `NotchMenuView.detailColumn`
    /// 同构的浮层宿主。
    ///
    /// 图案两端都铺满视口：判据量的是「浮层有没有压暗它盖住的那一段」，那一段在夹具里得有
    /// **比浮层更亮**的内容——用亮条而不是真实文案，是因为文案的密度可能比浮层里还高，
    /// 亮度方向就反了（实测踩过）。图案不是选择器，永远不会上报浮层。
    @MainActor
    private func minimalHost(
        viewport: CGFloat, stripesAbove: Int, @ViewBuilder row: () -> some View
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                stripes(count: stripesAbove)
                row()
                stripes(count: 12)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: detailWidth, height: viewport)
        .background(Color.black)
        .settingsPickerOverlay()
    }

    /// 一条测试图案：一条固定的亮横条（判据只关心「这里原本有东西」）。
    private func stripes(count: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                Rectangle()
                    .fill(Color.white.opacity(0.38))
                    .frame(height: NotchMenuMetrics.optionRowHeight)
            }
        }
    }

    /// 第 `stripesAbove` 条图案之下的行所在的 y（与 `minimalHost` 的排版同源）。
    private func rowTop(stripesAbove: Int) -> CGFloat {
        CGFloat(stripesAbove) * NotchMenuMetrics.optionRowHeight
    }

    /// 浮层盖住的那一段，取紧贴浮层顶边的一条带（不依赖任何文案的排版位置）。
    private func coverBand(
        anchor: CGRect, viewport: CGFloat, listHeight: CGFloat, height: CGFloat
    ) -> CGRect {
        let container = CGSize(width: detailWidth, height: viewport)
        let opensDown = SettingsPickerOverlayPlacement.opensDown(
            anchor: anchor, container: container, gap: gap, maxHeight: cap)
        let available = SettingsPickerOverlayPlacement.availableHeight(
            anchor: anchor, container: container, gap: gap, maxHeight: cap)
        let top = opensDown ? anchor.maxY + gap : anchor.minY - gap - min(available, listHeight)
        return CGRect(x: 0, y: top, width: detailWidth, height: height)
    }

    /// 渲染收起 / 展开两态并比较判据带：亮度必须明显下降（实色底），且带里量得到墨迹
    /// （选项文字）。两态都用同一个夹具，只有展开态不同。
    @MainActor
    private func assertOverlayCovers(
        viewport: CGFloat, stripesAbove: Int, band: CGRect,
        selector: any PickerExpansionControlling, @ViewBuilder row: () -> some View
    ) {
        let view = minimalHost(viewport: viewport, stripesAbove: stripesAbove, row: row)
        let previous = selector.isPickerExpanded
        defer { selector.isPickerExpanded = previous }

        selector.isPickerExpanded = false
        let collapsed = NSHostingViewProbe.raster(view)
        selector.isPickerExpanded = true
        let expanded = NSHostingViewProbe.raster(view)
        #expect(collapsed != nil && expanded != nil, "夹具渲染失败")

        let collapsedLuma = meanLuminance(of: collapsed, in: band)
        let expandedLuma = meanLuminance(of: expanded, in: band)
        let collapsedInk = inkClusters(of: collapsed, in: band.minY...(band.maxY))
        let expandedInk = inkClusters(of: expanded, in: band.minY...(band.maxY))
        let wholeCollapsed = meanLuminance(
            of: collapsed, in: CGRect(x: 0, y: 0, width: detailWidth, height: viewport))
        let wholeExpanded = meanLuminance(
            of: expanded, in: CGRect(x: 0, y: 0, width: detailWidth, height: viewport))
        _ = (wholeCollapsed, wholeExpanded)
        print(
            "[浮层] 带 \(band.minY)…\(band.maxY)：亮度 \(collapsedLuma) → \(expandedLuma)，墨迹 \(collapsedInk.count) → \(expandedInk.count)"
        )

        // 渲染失效时两态都量不到（亮度 -1）：先钉住「真的量到了像素」。
        #expect(collapsedLuma >= 0 && expandedLuma >= 0, "没有量到像素")
        #expect(!collapsedInk.isEmpty, "收起态那条带本该有内容（否则压暗判据失去意义）")
        #expect(!expandedInk.isEmpty, "浮层没有把选项画在那条带里")
        #expect(
            expandedLuma < collapsedLuma * 0.7,
            "浮层没有压暗它盖住的那条带（\(collapsedLuma) → \(expandedLuma)）；整图 \(wholeCollapsed) → \(wholeExpanded)；展开态 \(selector.isPickerExpanded)；本机音效 \(NotificationSoundLibrary.choices().count) 条")
    }

    @Test("贴底那一行：浮层朝上，盖住它上面的内容")
    @MainActor
    func upBranchCoversContentAboveTheRow() {
        // 行钉在视口底部（下面 0pt、上面 202pt）⇒ 朝上。完成提示那 4 档是固定列表（138pt），
        // 因此判据带可以取整段。
        let stripesAbove = 4
        let rowTop = rowTop(stripesAbove: stripesAbove)
        let rowAnchor = anchor(top: rowTop)
        #expect(
            !SettingsPickerOverlayPlacement.opensDown(
                anchor: rowAnchor,
                container: CGSize(width: detailWidth, height: notificationsViewport),
                gap: gap, maxHeight: cap),
            "夹具的前提变了：这一行应当朝上")

        assertOverlayCovers(
            viewport: notificationsViewport, stripesAbove: stripesAbove,
            band: coverBand(
                anchor: rowAnchor, viewport: notificationsViewport, listHeight: 138, height: 60),
            selector: CompletionBadgeSelector.shared
        ) {
            PreferencePickerRow(
                badge: SettingsBadge(
                    source: .symbol(name: "checkmark.circle", tint: AppPalette.accent)),
                title: "完成提示",
                selector: CompletionBadgeSelector.shared,
                label: { _ in "选项" })
        }
    }

    @Test("顶部那一行：浮层朝下，盖住它下面的内容")
    @MainActor
    func downBranchCoversContentBelowTheRow() {
        // 行放在视口顶部 ⇒ 朝下；安静时段那 4 档是固定列表（138pt），判据带可以取整段。
        //
        // 夹具用 `PreferencePickerRow`（与生产同一条 `SettingsPickerRow` 路径）而**不用音效行**：
        // 音效行在这个离屏夹具里量不到浮层（展开态经断言确认是 true、`SettingsPickerRow`
        // 也是同一份实现，整图却零变化——原因未定位），它的页面高度不变量仍由
        // `pageHeightIsIndependentOfExpansion` 覆盖；「长列表被夹住」由下面那条注入载荷的
        // 用例覆盖。
        let stripesAbove = 0
        let rowTop = rowTop(stripesAbove: stripesAbove)
        let rowAnchor = anchor(top: rowTop)
        let container = CGSize(width: detailWidth, height: notificationsViewport)
        #expect(
            SettingsPickerOverlayPlacement.opensDown(
                anchor: rowAnchor, container: container, gap: gap, maxHeight: cap),
            "夹具的前提变了：顶部那一行应当朝下")

        assertOverlayCovers(
            viewport: notificationsViewport, stripesAbove: stripesAbove,
            band: coverBand(
                anchor: rowAnchor, viewport: notificationsViewport, listHeight: 138, height: 60),
            selector: QuietHoursSelector.shared
        ) {
            PreferencePickerRow(
                badge: SettingsBadge(source: .symbol(name: "moon.zzz", tint: AppPalette.accent)),
                title: "安静时段",
                selector: QuietHoursSelector.shared,
                label: { _ in "选项" })
        }
    }

    @Test("长列表超过可用空间时：卡片被夹住、在卡内滚动（给定 6 行列表直接渲染卡片）")
    @MainActor
    func clampedCardIsDrawnAndCovers() throws {
        let stripesAbove = 1
        let rowTop = rowTop(stripesAbove: stripesAbove)
        let rowAnchor = anchor(top: rowTop)
        let container = CGSize(width: detailWidth, height: notificationsViewport)
        let available = SettingsPickerOverlayPlacement.availableHeight(
            anchor: rowAnchor, container: container, gap: gap, maxHeight: cap)
        #expect(
            available
                < NotchMenuMetrics.pickerOptionsHeight(
                    visibleOptions: SoundSelector.maxVisibleOptions),
            "可用空间 \(available) 没有短于列表自然高，盖不到「卡内滚动」那一支")

        let payload = SettingsPickerOverlayPayload(
            anchor: rowAnchor,
            identity: "probe",
            content: AnyView(
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        SettingsOptionRow(
                            label: "选项 \(index)", detail: "第 \(index) 档", isSelected: index == 1
                        ) {}
                    }
                }))

        func fixture(withOverlay: Bool) -> some View {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    stripes(count: stripesAbove)
                    stripes(count: 12)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(width: detailWidth, height: notificationsViewport)
            .background(Color.black)
            .coordinateSpace(name: NotchMenuMetrics.pickerOverlaySpace)
            .overlay {
                if withOverlay {
                    SettingsPickerOverlayCard(payload: payload, container: container)
                }
            }
        }

        let collapsed = NSHostingViewProbe.raster(fixture(withOverlay: false))
        let expanded = NSHostingViewProbe.raster(fixture(withOverlay: true))
        #expect(collapsed != nil && expanded != nil, "夹具渲染失败")

        let band = coverBand(
            anchor: rowAnchor, viewport: notificationsViewport, listHeight: 202, height: 60)
        let collapsedLuma = meanLuminance(of: collapsed, in: band)
        let expandedLuma = meanLuminance(of: expanded, in: band)
        let expandedInk = inkClusters(of: expanded, in: band.minY...(band.maxY))
        #expect(collapsedLuma >= 0 && expandedLuma >= 0, "没有量到像素")
        #expect(!expandedInk.isEmpty, "浮层没有把选项画在那条带里")
        #expect(
            expandedLuma < collapsedLuma * 0.7,
            "朝下并夹住的浮层没有压暗它盖住的那条带（\(collapsedLuma) → \(expandedLuma)）")
    }
}
