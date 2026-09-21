//
//  NotchMenuMetricsTests.swift
//  AgentIslandTests
//
//  设置面板高度由常量解析式算出，而面板实际排版由 blocks(for:) 的行表决定。
//  两者一旦漂移，面板就会裁掉页面底部或留出空白；这里把等价关系钉死。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("设置面板高度公式")
struct NotchMenuMetricsTests {
    /// 独立按常量重算内容高度：页眉 + 分段控件 + 各分组（标题 + 行 + 页脚）+ 组间距。
    private func derivedContentHeight(_ section: NotchMenuSection) -> CGFloat {
        var height =
            NotchMenuMetrics.listPaddingHeight + NotchMenuMetrics.pageHeaderHeight
            + NotchMenuMetrics.rowSpacing + NotchMenuMetrics.tabBarHeight
            + NotchMenuMetrics.rowSpacing + NotchMenuMetrics.contentTopGap

        let blocks = NotchMenuMetrics.blocks(for: section)
        for (index, block) in blocks.enumerated() {
            if block.hasHeader {
                height += NotchMenuMetrics.sectionHeaderHeight + NotchMenuMetrics.sectionHeaderGap
            }
            height += block.rows.reduce(0, +)
            if block.hasFootnote {
                height += NotchMenuMetrics.footnoteHeight
            }
            if index < blocks.count - 1 {
                height += NotchMenuMetrics.groupSpacing
            }
        }
        return height
    }

    @Test("三个分组的高度都等于行表重算的结果")
    func contentHeightMatchesBlockTable() {
        for section in NotchMenuSection.allCases {
            #expect(
                NotchMenuMetrics.contentHeight(for: section) == derivedContentHeight(section),
                "\(section.rawValue) 的解析式高度与行表不一致")
        }
    }

    @Test("智能体分组为每个受支持的 Agent 各留一行，末尾接审批降级档选择器")
    func agentsSectionCoversEveryAgent() {
        let blocks = NotchMenuMetrics.blocks(for: .agents)
        // 四个 Agent 各一行（两行行高），末尾是降级档选择器（单行选择行）。
        let expectedRows =
            Array(repeating: NotchMenuMetrics.twoLineRowHeight, count: AgentKind.allCases.count)
            + [NotchMenuMetrics.rowHeight]
        #expect(blocks.first?.rows == expectedRows)
        #expect(blocks.first?.hasFootnote == true)
    }

    @Test("没到上限时面板高度就是固定开销加内容加展开量")
    func panelHeightBelowCapIsAdditive() {
        let expected =
            44 + NotchMenuMetrics.contentHeight(for: .general)
            + NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 3)
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 3),
                chromeHeight: 44) == expected)
    }

    @Test("超过上限时面板高度被夹住，正好等于上限时不被削")
    func panelHeightIsClampedAtCap() {
        let cap = NotchMenuMetrics.maxPanelHeight
        let content = NotchMenuMetrics.contentHeight(for: .general)

        #expect(NotchMenuMetrics.panelHeight(for: .general, expandedPickerHeight: cap, chromeHeight: 400) == cap)
        #expect(NotchMenuMetrics.panelHeight(for: .general, expandedPickerHeight: 1000, chromeHeight: 400) == cap)
        // 恰好等于上限：仍是这个值（没有被多减）
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: cap - 44 - content, chromeHeight: 44) == cap)
    }

    @Test("上限容得下通用页最高的单个展开（音效的 6 行选项）")
    func capFitsTallestSingleExpansion() {
        let expanded = NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 6)
        let height = NotchMenuMetrics.panelHeight(for: .general, expandedPickerHeight: expanded, chromeHeight: 44)
        #expect(height == 44 + NotchMenuMetrics.contentHeight(for: .general) + expanded)
        #expect(height < NotchMenuMetrics.maxPanelHeight)
    }

    @Test("选项块高度随选项数线性增长，空列表只留内边距")
    func pickerOptionsHeightScalesLinearly() {
        #expect(NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 0) == NotchMenuMetrics.optionListPadding)
        #expect(
            NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 2)
                - NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 1) == NotchMenuMetrics.optionRowHeight)
        #expect(
            NotchMenuMetrics.optionListTopPadding + NotchMenuMetrics.optionListBottomPadding
                == NotchMenuMetrics.optionListPadding)
    }

    @Test("分隔线缩进与选项缩进都由行几何推出")
    func indentsAreDerivedFromRowGeometry() {
        #expect(
            NotchMenuMetrics.separatorInset
                == NotchMenuMetrics.rowHorizontalPadding + NotchMenuMetrics.badgeSize
                    + NotchMenuMetrics.badgeGap)
        #expect(
            NotchMenuMetrics.optionIndent
                == NotchMenuMetrics.separatorInset - NotchMenuMetrics.optionHorizontalPadding)
        #expect(NotchMenuMetrics.optionIndent > 0)
    }
}
