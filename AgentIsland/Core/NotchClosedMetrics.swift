//
//  NotchClosedMetrics.swift
//  AgentIsland
//
//  关闭态胶囊右侧计数徽标的档位与耳宽。
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

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// 关闭态计数徽标的度量与档位（纯函数，可单测）。
nonisolated enum NotchClosedMetrics {
    // MARK: - 字体

    /// 徽标字号 / 字重 / 字体设计：视图的 `.font(...)` 与这里的宽度实测同源。
    /// SwiftUI 的 `Font.Weight` 不暴露数值，两处只能各写 `.semibold`；等价性由
    /// `NotchClosedMetricsTests` 用「真实 SwiftUI 排版宽度」对照钉住，改一处不改另一处会失败。
    static let fontSize: CGFloat = 11
    static let fontWeight: Font.Weight = .semibold
    static let fontDesign: Font.Design = .rounded

    /// 宽度实测用的 AppKit 字体，与上面三个常量等价（顺序与视图一致：
    /// 先取等宽数字的系统字体，再换成 `.rounded` 设计）。
    private static let measurementFont: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }()

    // MARK: - 宽度

    /// 计数文字与相机挖孔之间保留的余量：几何下限 6pt + 视觉余量 2pt（推导见文件头）。
    static let countClearance: CGFloat = 8

    /// 耳宽上限。本机内置屏（spacer 183、左右内边距各 14、尾距 4）下胶囊最宽
    /// 2 × 68 + 215 = 351pt，两侧各多盖住辅助区约 81pt（左侧是 App 菜单）。
    /// 再宽就不划算：超出上限改为降级文案，最后才交给 `minimumScaleFactor` 缩字。
    static let maximumEarWidth: CGFloat = 68

    /// 文案在徽标字体下的排版宽度。实测而不是估算：数字虽然等宽，`+` 与 `/` 的推进量不同，
    /// 估出来的宽度会让耳宽系统性偏窄或偏宽。
    static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: measurementFont]).width
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
        limit: CGFloat = maximumEarWidth
    ) -> Label {
        let subagentCount = max(0, subagents)
        for level in LabelLevel.allCases {
            let candidate = Label(
                level: level,
                activeSessions: activeSessions,
                subagents: level == .activeOnly || level == .withoutSubagents
                    ? nil : (subagentCount > 0 ? subagentCount : nil),
                totalSessions: level == .activeOnly || level == .withoutTotal ? nil : totalSessions)
            if textWidth(candidate.text) + countClearance <= limit { return candidate }
        }
        // 最省位的一档仍然超上限：交给 minimumScaleFactor 缩字。
        return Label(
            level: .activeOnly, activeSessions: activeSessions, subagents: nil, totalSessions: nil)
    }

    /// 耳宽：文字宽 + 余量，夹在 `minimum`（胶囊高度推出的最小耳宽）与上限之间。
    /// 左右耳同宽使用——只加宽右耳解不了问题（见文件头）。
    static func earWidth(for label: Label, minimum: CGFloat) -> CGFloat {
        min(maximumEarWidth, max(minimum, textWidth(label.text) + countClearance))
    }
}
