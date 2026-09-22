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
    private func renderedWidth(_ text: String) -> CGFloat {
        let view = Text(text)
            .font(
                .system(
                    size: NotchClosedMetrics.fontSize,
                    weight: NotchClosedMetrics.fontWeight,
                    design: NotchClosedMetrics.fontDesign)
            )
            .monospacedDigit()
            .fixedSize()
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    @Test("视图字体与宽度实测同源：渲染宽度与算出来的宽度一致")
    func fontMatchesRenderedText() {
        for text in ["1/3", "11/22", "11+11/22"] {
            // 排版宽度按整点取整，留 1pt 容差
            #expect(abs(renderedWidth(text) - NotchClosedMetrics.textWidth(text)) <= 1)
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
}
