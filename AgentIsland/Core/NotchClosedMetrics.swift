//
//  NotchClosedMetrics.swift
//  AgentIsland
//
//  关闭态胶囊的度量：右侧计数徽标的档位与耳宽，以及**画出来的胶囊尺寸**。
//
//  关闭态胶囊在屏幕上居中、左右耳等宽，计数文字槽在右耳里居中，因此（相对屏幕中线）：
//
//      文字左缘 = (耳宽 + spacer − 尾距 − 文字宽) / 2
//
//  要让计数避开相机挖孔，只需要「耳宽 ≥ 文字宽 + 余量」，**与右耳之外的任何宽度无关**：
//  加宽右耳只会让胶囊两侧各向外长一半、文字中心几乎不动，反而把文字推回挖孔里
//  （离屏实测：右槽 30 → 58 时文字左缘从 847 退到 831，而挖孔右缘是 848.5）。
//
//  余量 = 6pt 几何下限 + 2pt 视觉余量。几何下限的来源：spacer 宽取「胶囊标称宽 − 6」
//  （顶部圆角，见 NotchView.headerRow），物理挖孔取「胶囊标称宽 − 4」（Ext+NSScreen 的
//  +4 对齐项），spacer 因此比挖孔窄 2pt；文字槽右缘再让出 4pt 尾距，合起来 6pt。
//
//  实测校准（1512×982 内置屏、耳宽 30、文字槽 30、11pt 字号）：`1/3`(19.5pt) 刚好压线过
//  挖孔 1.5pt，`11/22`(34.5pt) 已经滑进挖孔 —— 这就是「计数显示不全」的根因。
//
//  `capsuleSize` 是「画出来的那块」的**唯一**出处：视图按它定死卡片的尺寸，
//  `NotchViewModel` 按它判悬停/点击/转投。过去这三处各算一套（画 286、判据 224），
//  角色与计数徽标正好跨在边的两侧——耳朵的外半截悬停没反应、点击穿到菜单栏。
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// 关闭态计数徽标与胶囊的度量与档位（纯函数，可单测）。
nonisolated enum NotchClosedMetrics {
    // MARK: - 字体

    /// 徽标字号：取字号阶梯的「副标题/脚注」档（11pt），**刻意不跟菜单栏的 13pt 常规体对齐**。
    ///
    /// 理由：这一枚是在 30pt 宽的耳位里、贴着相机挖孔边缘的一小段数字，宽度直接决定耳宽，
    /// 而耳宽又决定计数会不会滑进挖孔（见文件头的实测校准）。换成菜单栏那档（13pt 常规体）
    /// 会把参考宽度表与整条「耳宽 ≥ 文字宽 + 余量」的不变量一起推翻，而菜单栏文字本来也
    /// 不比它更容易读——它只是同一条顶边上的邻居，不是同一套排版。
    static let fontSize: CGFloat = AppTypeScale.footnote
    static let fontWeight: Font.Weight = .semibold
    static let fontDesign: Font.Design = .rounded

    /// 宽度实测用的 AppKit 字体，与上面三个常量等价（顺序与视图一致：
    /// 先取等宽数字的系统字体，再换成 `.rounded` 设计）。
    private static func measurementFont(scale: CGFloat) -> NSFont {
        let size = fontSize * scale
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    // MARK: - 宽度

    /// 计数文字与相机挖孔之间保留的余量：几何下限 6pt + 视觉余量 2pt（推导见文件头）。
    static let countClearance: CGFloat = 8

    /// 耳宽上限。本机内置屏（spacer 183、左右内边距各 14、尾距 4）下胶囊最宽
    /// 2 × 68 + 215 = 351pt，两侧各多盖住辅助区约 81pt（左侧是 App 菜单）。
    /// 再宽就不划算：超出上限改为降级文案，最后才交给 `minimumScaleFactor` 缩字。
    static let maximumEarWidth: CGFloat = 68

    /// 文案在徽标字体下的排版宽度。实测而不是估算：数字虽然等宽，`+` 与 `/` 的推进量不同，
    /// 估出来的宽度会让耳宽系统性偏窄或偏宽。
    ///
    /// `scale` 是用户的**内容字号**档位：关闭态胶囊原先忽略它（只有内容面注入了
    /// `\.appTextScale`），于是用户把内容字号调大后，计数照旧按 11pt 排版，而它周围
    /// 一切都放大了。字号与耳宽必须同源缩放，否则字先被撑破、耳宽还按旧字号算。
    static func textWidth(_ text: String, scale: CGFloat = 1) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: measurementFont(scale: scale)]).width
    }

    // MARK: - 胶囊的排版常量

    /// 关闭态胶囊的排版常量：与 `NotchView.headerRow` 的算式**同源**（视图排版与下面的
    /// 宽度公式必须是同一个数，否则「画出来的胶囊」与命中带又会分家）。
    /// 这些值刻意不借用圆角（顶部圆角曾是 6、左右内边距曾是 14）：改圆角不该把胶囊的
    /// 布局一起挪走。
    enum Capsule {
        /// 活动态中间文字槽相对标称胶囊宽度的内缩（顶部圆角那一段）。
        static let centerInset: CGFloat = 6
        /// 无活动态中间文字槽相对标称胶囊宽度的内缩（`NotchView` 的空胶囊分支）。
        static let idleCenterInset: CGFloat = 20
        /// 计数徽标与胶囊右缘之间的尾距。
        static let badgeTrailing: CGFloat = 4
        /// 胶囊两侧的内边距。
        static let sidePadding: CGFloat = 14
        /// 头部条带的固定高度：胶囊高度不足 24 时也画 24（关闭态胶囊的最小高度）。
        static let minimumHeight: CGFloat = 24
        /// `badgeOnly` 档：徽标到胶囊右缘的边距。那一侧已经贴着菜单栏上的状态图标，
        /// 边距比通用侧边距小一点是一点。
        static let badgeSidePadding: CGFloat = 8
        /// 徽标槽的上限：超宽的计数按档位降级（`11+11/22` → `11+11` → `11/22` → `11`），
        /// 实在装不下才交给 `minimumScaleFactor` 缩字。
        static let maximumBadgeSlot: CGFloat = 60
        /// 徽标槽的下限：一位数也要留出一点呼吸位。
        static let minimumBadgeSlot: CGFloat = 20
        /// 左侧审批指示（琥珀色）占掉的宽度：图标 14 + 与角色之间的间距 4。
        static let permissionIndicator: CGFloat = 18
        /// 提示弹跳时临时加宽的宽度（`isBouncing`）。
        static let bounce: CGFloat = 16
    }

    // MARK: - 档位

    /// 文案档位：从信息最全到最省位，宽度超上限时按这个顺序降级。
    enum LabelLevel: CaseIterable, Equatable, Sendable {
        /// `活跃+子/总数`
        case full
        /// `活跃+子`：先丢总数（「有多少在跑」比「纳管多少个」更值得占位）
        case withoutTotal
        /// `活跃/总数`：再丢子 Agent 数
        case withoutSubagents
        /// 只剩活跃会话数
        case activeOnly
    }

    /// 计数徽标要显示的内容：`nil` 表示该段不显示。
    struct Label: Equatable, Sendable {
        let level: LabelLevel
        let activeSessions: Int
        let subagents: Int?
        let totalSessions: Int?

        /// 可见文案，如 `11+11/22`。
        var text: String {
            var text = "\(activeSessions)"
            if let subagents { text += "+\(subagents)" }
            if let totalSessions { text += "/\(totalSessions)" }
            return text
        }
    }

    /// 按当前计数挑档位：先给最全的一档，只有宽度超过上限才降级
    /// （展开态头部面板够宽，传 `.infinity` 就能始终拿到最全的一档）。
    static func label(
        activeSessions: Int,
        subagents: Int,
        totalSessions: Int,
        limit: CGFloat = maximumEarWidth,
        scale: CGFloat = 1
    ) -> Label {
        let subagentCount = max(0, subagents)
        for level in LabelLevel.allCases {
            let candidate = Label(
                level: level,
                activeSessions: activeSessions,
                subagents: level == .activeOnly || level == .withoutSubagents
                    ? nil : (subagentCount > 0 ? subagentCount : nil),
                totalSessions: level == .activeOnly || level == .withoutTotal ? nil : totalSessions)
            if textWidth(candidate.text, scale: scale) + countClearance <= limit {
                return candidate
            }
        }
        // 最省位的一档仍然超上限：交给 minimumScaleFactor 缩字。
        return Label(
            level: .activeOnly, activeSessions: activeSessions, subagents: nil, totalSessions: nil)
    }

    /// 耳宽：文字宽 + 余量，夹在 `minimum`（胶囊高度推出的最小耳宽）与上限之间。
    /// 左右耳同宽使用——只加宽右耳解不了问题（见文件头）。
    static func earWidth(for label: Label, minimum: CGFloat, scale: CGFloat = 1) -> CGFloat {
        min(maximumEarWidth, max(minimum, textWidth(label.text, scale: scale) + countClearance))
    }

    /// 由胶囊高度推出的最小耳宽（32pt 高的刘海 → 30），跟着「胶囊高度」设置走。
    static func minimumEarWidth(notchHeight: CGFloat) -> CGFloat {
        max(0, notchHeight - 12) + 10
    }

    // MARK: - 胶囊尺寸

    /// 关闭态胶囊**画出来的**尺寸。
    ///
    /// 宽度 = 左耳 + 中间文字槽 + 右耳 + 计数尾距 + 两侧内边距；左耳在有待批指示时多占
    /// 一个指示宽度（右耳不加宽——只加宽右耳会把计数推回挖孔里，见文件头）。
    /// 高度取「头部条带的固定高度」，胶囊高度更小时也不会被压扁。
    ///
    /// 没有活动时视图不画耳朵（文字槽取 `idleCenterInset`），因此那种形态按 `showsEars: false`
    /// 单列：命中带必须与**当前画出来的那一块**一致，不能拿活动态的宽胶囊去覆盖空胶囊
    /// （那会在菜单栏上多出一条无罪受判的悬停带）。
    ///
    /// - Parameters:
    ///   - notchSize: 标称胶囊尺寸（`NotchViewModel.deviceNotchRect`）。
    ///   - earWidth: `earWidth(for:minimum:scale:)` 给出的耳宽。
    ///   - showsEars: 视图当前是否画了左右耳（关闭态有活动）。
    ///   - showsPermissionIndicator: 左侧是否画了琥珀色审批指示。
    ///   - isBouncing: 是否处于提示弹跳（短促加宽）。
    static func capsuleSize(
        notchSize: CGSize,
        earWidth: CGFloat,
        showsEars: Bool,
        showsPermissionIndicator: Bool = false,
        isBouncing: Bool = false
    ) -> CGSize {
        let height = max(Capsule.minimumHeight, notchSize.height)
        guard showsEars else {
            let centerWidth = max(0, notchSize.width - Capsule.idleCenterInset)
            return CGSize(width: centerWidth + 2 * Capsule.sidePadding, height: height)
        }

        let leftEar = earWidth + (showsPermissionIndicator ? Capsule.permissionIndicator : 0)
        let width =
            leftEar + max(0, notchSize.width - Capsule.centerInset) + earWidth
            + Capsule.badgeTrailing + 2 * Capsule.sidePadding
            + (isBouncing ? Capsule.bounce : 0)
        return CGSize(width: width, height: height)
    }

    // MARK: - 按档位排版

    /// 关闭态一次算清的结果：画出来的那一块（同时也是命中判据）+ 该画哪几段 + 各段宽度。
    ///
    /// 视图过去是「先按计数算耳宽、再算胶囊尺寸、再按段排版」三处各算一次，
    /// 哪一处漏掉「有待批 / 正在弹跳」都会让画出来的与判据的错开一截。
    /// 现在合成一个返回值，三处读同一个 `plan`。
    struct ClosedCapsulePlan: Equatable, Sendable {
        /// 画出来的那一块（== 命中判据，见 `NotchViewModel.updateClosedCapsuleSize`）。
        var size: CGSize
        /// 关闭态要画的计数档位；`nil` = 这一档不画计数。
        var label: Label?
        /// 中间透明占位段的宽度（角色与徽标靠它把挖孔那一段撑开）。
        var spacerWidth: CGFloat
        /// 徽标槽宽（`0` = 不画）。
        var badgeSlot: CGFloat
        /// 左右耳宽（只有 `wideCapsule` 用得上，其余档为 0）。
        var earWidth: CGFloat
        /// 是否画左侧角色 / 右侧徽标。
        var showsMascot: Bool
        var showsBadge: Bool
        /// 胶囊左右内边距（画在卡片内部，由 `NotchView` 的 padding 消费）。
        var leadingPadding: CGFloat
        var trailingPadding: CGFloat
    }

    /// 按档位算清关闭态的全部度量。
    ///
    /// - Parameters:
    ///   - layout: 「关闭态胶囊的占位」档位（决定占多少菜单栏）。
    ///   - notchSize: 标称胶囊尺寸（`NotchViewModel.deviceNotchRect`）。
    ///   - activeSessions: 活跃会话数。
    ///   - subagents: 活跃子 Agent 数（`nil` = 该段不显示）。
    ///   - totalSessions: 纳管会话总数（`nil` = 该段不显示）。
    ///   - showsActivity: 当前是否有活动（处理中 / 待批 / 等待输入）。
    ///   - showsPermissionIndicator: 左侧是否画琥珀色审批指示（只有 `wideCapsule` 有左侧）。
    ///   - isBouncing: 是否处于提示弹跳（短促加宽）。
    ///   - scale: 用户的「内容字号」档位（字号与占位宽度必须同源缩放）。
    static func plan(
        layout: ClosedCapsuleLayout,
        notchSize: CGSize,
        activeSessions: Int,
        subagents: Int?,
        totalSessions: Int?,
        showsActivity: Bool,
        showsPermissionIndicator: Bool = false,
        isBouncing: Bool = false,
        scale: CGFloat = 1
    ) -> ClosedCapsulePlan {
        let height = max(Capsule.minimumHeight, notchSize.height)
        let bounce = isBouncing ? Capsule.bounce : 0

        // 只画挖孔剪影：缺口外什么都不落，宽度就是缺口宽度。
        guard layout != .notchOnly else {
            return ClosedCapsulePlan(
                size: CGSize(width: notchSize.width, height: height),
                label: nil,
                spacerWidth: notchSize.width,
                badgeSlot: 0,
                earWidth: 0,
                showsMascot: false,
                showsBadge: false,
                leadingPadding: 0,
                trailingPadding: 0)
        }

        let badgeLabel = label(
            activeSessions: activeSessions,
            subagents: subagents ?? 0,
            totalSessions: totalSessions ?? 0,
            limit: layout.badgeSlotLimit,
            scale: scale)
        let slot = badgeSlot(for: badgeLabel, limit: layout.badgeSlotLimit, scale: scale)

        // 徽标独占右侧：左缘与缺口左缘对齐，中间的占位段就是缺口那一段。
        if layout == .badgeOnly {
            guard showsActivity else {
                return ClosedCapsulePlan(
                    size: CGSize(width: notchSize.width, height: height),
                    label: nil,
                    spacerWidth: notchSize.width,
                    badgeSlot: 0,
                    earWidth: 0,
                    showsMascot: false,
                    showsBadge: true,
                    leadingPadding: layout.leadingPadding,
                    trailingPadding: layout.trailingPadding)
            }
            return ClosedCapsulePlan(
                size: CGSize(
                    width:
                        notchSize.width + slot + Capsule.badgeTrailing + layout.trailingPadding
                        + bounce,
                    height: height),
                label: badgeLabel,
                spacerWidth: notchSize.width + bounce,
                badgeSlot: slot,
                earWidth: 0,
                showsMascot: false,
                showsBadge: true,
                leadingPadding: layout.leadingPadding,
                trailingPadding: layout.trailingPadding)
        }

        // wideCapsule：角色与计数分居缺口两侧，沿用原来的算式。
        let ear = earWidth(
            for: badgeLabel, minimum: minimumEarWidth(notchHeight: notchSize.height), scale: scale)
        return ClosedCapsulePlan(
            size: capsuleSize(
                notchSize: notchSize,
                earWidth: ear,
                showsEars: showsActivity,
                showsPermissionIndicator: showsPermissionIndicator,
                isBouncing: isBouncing),
            label: showsActivity ? badgeLabel : nil,
            spacerWidth:
                showsActivity
                ? notchSize.width - Capsule.centerInset + bounce
                : notchSize.width - Capsule.idleCenterInset,
            badgeSlot: showsActivity ? ear : 0,
            earWidth: ear,
            showsMascot: showsActivity,
            showsBadge: showsActivity,
            leadingPadding: layout.leadingPadding,
            trailingPadding: layout.trailingPadding)
    }

    /// 徽标槽宽：文字宽 + 余量，夹在下限与档位上限之间（与 `earWidth` 同一套算式）。
    static func badgeSlot(
        for label: Label, limit: CGFloat, scale: CGFloat = 1
    ) -> CGFloat {
        min(
            limit,
            max(
                Capsule.minimumBadgeSlot, textWidth(label.text, scale: scale) + countClearance))
    }
}
