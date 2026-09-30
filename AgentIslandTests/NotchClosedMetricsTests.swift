//
//  NotchClosedMetricsTests.swift
//  AgentIslandTests
//
//  关闭态计数徽标的度量与档位：视图字体与宽度实测必须同源（否则耳宽算窄、计数又会滑进
//  相机挖孔）、「耳宽 ≥ 文字宽 + 余量」这条避开挖孔的不变量、以及超上限时的降级顺序。
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@MainActor
@Suite("关闭态计数徽标")
struct NotchClosedMetricsTests {
    /// 用与视图 `sessionCountBadge` 同一串字体修饰符渲染一次，取真实排版宽度。
    /// `scale` 是用户的内容字号档位（视图按它乘字号，见 `NotchView.headerTextScale`）。
    private func renderedWidth(_ text: String, scale: CGFloat = 1) -> CGFloat {
        let view = Text(text)
            .font(
                .system(
                    size: NotchClosedMetrics.fontSize * scale,
                    weight: NotchClosedMetrics.fontWeight,
                    design: NotchClosedMetrics.fontDesign)
            )
            .monospacedDigit()
            .fixedSize()
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    @Test("视图字体与宽度实测同源：渲染宽度与算出来的宽度一致（各字号档位都对）")
    func fontMatchesRenderedText() {
        for scale in [1.0, 1.3] as [CGFloat] {
            for text in ["1/3", "11/22", "11+11/22"] {
                // 排版宽度按整点取整，留 1pt 容差
                #expect(
                    abs(
                        renderedWidth(text, scale: scale)
                            - NotchClosedMetrics.textWidth(text, scale: scale)) <= 1)
            }
        }
    }

    @Test("参考宽度表：字体或字号漂移会在这里现形")
    func referenceWidths() {
        #expect(abs(NotchClosedMetrics.textWidth("1/3") - 19.5) <= 0.5)
        #expect(abs(NotchClosedMetrics.textWidth("11/22") - 34.5) <= 0.5)
        #expect(abs(NotchClosedMetrics.textWidth("11+11/22") - 57.1) <= 0.5)
    }

    @Test("耳宽不变量：不少于文字宽 + 余量，且夹在最小耳宽与上限之间")
    func earWidthInvariants() {
        let labels = [(1, 0, 3), (11, 0, 22), (11, 11, 22), (23, 45, 678)].map {
            NotchClosedMetrics.label(activeSessions: $0.0, subagents: $0.1, totalSessions: $0.2)
        }

        for label in labels {
            let ear = NotchClosedMetrics.earWidth(for: label, minimum: 30)
            #expect(
                ear >= NotchClosedMetrics.textWidth(label.text) + NotchClosedMetrics.countClearance)
            #expect(ear >= 30)
            #expect(ear <= NotchClosedMetrics.maximumEarWidth)
        }
    }

    @Test("短计数不改版面：1/3 仍取最小耳宽")
    func shortCountKeepsMinimumEar() {
        let label = NotchClosedMetrics.label(activeSessions: 1, subagents: 0, totalSessions: 3)
        #expect(label.level == .full)
        #expect(label.text == "1/3")
        #expect(NotchClosedMetrics.earWidth(for: label, minimum: 30) == 30)
    }

    @Test("没有 subAgent 时不画 +0（沿用既有文案）")
    func noSubagentSegmentWhenIdle() {
        let label = NotchClosedMetrics.label(activeSessions: 5, subagents: 0, totalSessions: 9)
        #expect(label.subagents == nil)
        #expect(label.totalSessions == 9)
        #expect(label.text == "5/9")
    }

    @Test("计数变宽 → 耳宽抬上去，宽计数能被完整放下")
    func earGrowsWithCount() {
        let small = NotchClosedMetrics.label(activeSessions: 1, subagents: 0, totalSessions: 3)
        let wide = NotchClosedMetrics.label(activeSessions: 11, subagents: 11, totalSessions: 22)

        #expect(wide.text == "11+11/22")
        let wideEar = NotchClosedMetrics.earWidth(for: wide, minimum: 30)
        #expect(wideEar > NotchClosedMetrics.earWidth(for: small, minimum: 30))
        #expect(wideEar >= NotchClosedMetrics.textWidth("11+11/22"))
    }

    @Test("超上限按顺序降级：先丢总数，再丢 subAgent 数")
    func levelLadderDropsSegmentsInOrder() {
        // 完整档 87.1 + 8 > 上限 68；丢总数后 999+999 只需 52.5 → 选 withoutTotal
        let huge = NotchClosedMetrics.label(
            activeSessions: 999, subagents: 999, totalSessions: 9999)
        #expect(huge.level == .withoutTotal)
        #expect(huge.text == "999+999")

        // 没有 subAgent 可丢时，从 9999/9999（64.6 + 8 > 68）退到只剩活跃数
        let hugeIdle = NotchClosedMetrics.label(
            activeSessions: 9999, subagents: 0, totalSessions: 9999)
        #expect(hugeIdle.level == .withoutTotal)
        #expect(hugeIdle.text == "9999")
    }

    @Test("展开态头部不受耳宽上限约束，永远拿最全的一档")
    func unlimitedLimitKeepsFullLabel() {
        let label = NotchClosedMetrics.label(
            activeSessions: 999, subagents: 999, totalSessions: 9999, limit: .infinity)
        #expect(label.level == .full)
        #expect(label.text == "999+999/9999")
    }

    @Test("字号档位抬上去：先降级保住耳宽上限，而不是把耳宽顶出挖孔")
    func scaleDegradesLabelToProtectTheEarCap() {
        // 真实契约是「先按当前字号挑档位，再量耳宽」：耳宽上限贴着相机挖孔，是不随字号
        // 放大的绝对几何约束。字号变大时唯一的合法腾位手段是**降级计数段**——耳宽因此
        // 不一定变大变小，但每一档都必须装得下自己的文字，且永不越上限。
        let standardLabel = NotchClosedMetrics.label(
            activeSessions: 11, subagents: 11, totalSessions: 22, scale: 1)
        let largeLabel = NotchClosedMetrics.label(
            activeSessions: 11, subagents: 11, totalSessions: 22, scale: 1.3)
        let standard = NotchClosedMetrics.earWidth(for: standardLabel, minimum: 30, scale: 1)
        let large = NotchClosedMetrics.earWidth(for: largeLabel, minimum: 30, scale: 1.3)

        // 1× 下最全的一档放得下，所以拿到完整写法。
        #expect(standardLabel.level == .full)

        // 1.3× 下同一份计数放不下了，降级必须真的发生——否则上限会被顶破、计数滑进挖孔。
        #expect(largeLabel.level != .full, "字号放大后必须降级，不能硬撑")
        #expect(
            largeLabel.text.count <= standardLabel.text.count,
            "降级只能往短走，不能反向取更长的写法")
        // 不管降了几级：每档的耳宽都装得下自己的文字，且不越上限。
        for (label, scale, ear) in [
            (standardLabel, CGFloat(1), standard), (largeLabel, CGFloat(1.3), large),
        ] {
            #expect(ear >= NotchClosedMetrics.textWidth(label.text, scale: scale))
            #expect(ear <= NotchClosedMetrics.maximumEarWidth)
        }
        // 降级本身已经证明字号档位参与了度量：`label` 只在**按当前 scale 量出的宽度**
        // 顶破上限时才降级，1× 不降、1.3× 降，正是这一条判据在起作用。
    }

    @Test("胶囊尺寸 = 左右耳 + 文字槽 + 尾距 + 两侧内边距（画出来的那一块）")
    func capsuleSizeIsTheSumOfItsParts() {
        let notch = CGSize(width: 200, height: 32)
        let ear: CGFloat = 30
        let size = NotchClosedMetrics.capsuleSize(notchSize: notch, earWidth: ear, showsEars: true)
        let expected =
            2 * ear + (notch.width - NotchClosedMetrics.Capsule.centerInset)
            + NotchClosedMetrics.Capsule.badgeTrailing + 2 * NotchClosedMetrics.Capsule.sidePadding

        #expect(size.width == expected)
        #expect(size.height == max(NotchClosedMetrics.Capsule.minimumHeight, notch.height))
        // 胶囊必须盖住物理挖孔（否则计数会落在挖孔边缘上）。
        #expect(size.width > notch.width)

        // 有待批指示：左耳多占一个指示宽度（右耳不加宽——加宽右耳会把计数推回挖孔里）。
        let withIndicator = NotchClosedMetrics.capsuleSize(
            notchSize: notch, earWidth: ear, showsEars: true, showsPermissionIndicator: true)
        #expect(withIndicator.width == size.width + NotchClosedMetrics.Capsule.permissionIndicator)
        #expect(withIndicator.height == size.height)

        // 弹跳那一档也会被画出来，因此也要算进尺寸（判据跟着它走才不会与画面分家）。
        let bouncing = NotchClosedMetrics.capsuleSize(
            notchSize: notch, earWidth: ear, showsEars: true, isBouncing: true)
        #expect(bouncing.width == size.width + NotchClosedMetrics.Capsule.bounce)

        // 没有活动时不画耳朵：胶囊按「空胶囊」那一档（命中带不能拿宽胶囊去覆盖它）。
        let idle = NotchClosedMetrics.capsuleSize(
            notchSize: notch, earWidth: ear, showsEars: false)
        #expect(
            idle.width
                == max(0, notch.width - NotchClosedMetrics.Capsule.idleCenterInset)
                + 2 * NotchClosedMetrics.Capsule.sidePadding)
        #expect(idle.width < size.width)
        #expect(idle.height == size.height)
    }
}
