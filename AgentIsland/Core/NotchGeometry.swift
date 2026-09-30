//
//  NotchGeometry.swift
//  AgentIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
///
/// **一个状态只有一套矩形**：卡片的尺寸由状态给出（展开态是 `NotchViewModel.openedSize`，
/// 关闭态胶囊由视图按计数文案算好后发布），这里负责把它摆到屏幕中线并贴顶边。视图画的是
/// 同一块（`NotchView` 的 `NotchCard` 把「画出来的那一块」定死成这个尺寸）、宿主视图的
/// 命中判定用它、鼠标监听的行为判据（点卡片外收起、卡片内不吞）也用它——三处曾经各算一套
/// （画的是 `notchSize`，命中是 `size.width + 52`，行为判据是 `size.width - 6` /
/// `size.height - 30`），于是卡片边上有一条「看得见、点上去没反应」的带子，底部 30pt
/// 还会既收起面板又把点击转投给下层应用。
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    // MARK: - 摆位

    /// 卡片在**屏幕坐标系**里的矩形：水平居中贴屏幕顶边。展开态与关闭态共用同一个构造
    /// （差别只有尺寸本身），因此两个状态的行为判据不会各写一套摆位。
    private func topCenteredScreenRect(_ size: CGSize) -> CGRect {
        CGRect(
            x: screenRect.midX - size.width / 2,
            y: screenRect.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 同一个矩形在**面板窗口坐标系**里的值（宿主视图的命中判定用它）：原点在窗口左下、
    /// y 向上，而窗口与屏幕的左缘 / 顶边对齐（`NotchWindowController` 的 windowFrame），
    /// 因此水平方向是「屏幕宽的一半再减去半宽」，垂直方向从窗口顶边往下量。
    private func topCenteredWindowRect(_ size: CGSize) -> CGRect {
        CGRect(
            x: (screenRect.width - size.width) / 2,
            y: windowHeight - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - 设备刘海

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    // MARK: - 卡片矩形

    /// 展开态卡片矩形（屏幕系）。`size` 取 `NotchViewModel.openedSize`。
    func openedScreenRect(for size: CGSize) -> CGRect {
        topCenteredScreenRect(size)
    }

    /// 展开态卡片矩形（窗口系）。宿主视图的 `hitTest` 用它——与 `openedScreenRect`
    /// 是同一个矩形，换算只是坐标系不同。
    func openedWindowRect(for size: CGSize) -> CGRect {
        topCenteredWindowRect(size)
    }

    /// 关闭态胶囊矩形（屏幕系）。
    ///
    /// `size` 由视图发布（`NotchClosedMetrics.capsuleSize`）：胶囊宽度跟着计数文案走
    /// （左右耳 + 计数尾距 + 两侧内边距），只有视图知道当前画的是多宽。过去这里用的是
    /// 「物理刘海矩形外扩 10/5」，比画出来的胶囊窄一头——角色（左耳）与计数徽标（右耳）
    /// 正好跨在那条边线上，悬停/点击耳朵的外半截没有任何反应，点击还会穿到菜单栏。
    func closedCapsuleScreenRect(for size: CGSize) -> CGRect {
        topCenteredScreenRect(size)
    }

    /// 关闭态胶囊矩形（窗口系）。
    func closedCapsuleWindowRect(for size: CGSize) -> CGRect {
        topCenteredWindowRect(size)
    }

    // MARK: - 命中判定

    /// 点是否落在关闭态胶囊上（悬停展开、点击展开、点击转投共用的判据）。
    func isPointInClosedCapsule(_ point: CGPoint, size: CGSize) -> Bool {
        closedCapsuleScreenRect(for: size).contains(point)
    }

    /// 点是否落在展开态卡片里（悬停、点击归属与点击转投共用的判据）。
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// 点是否落在展开态卡片之外（用于收起）。
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
}