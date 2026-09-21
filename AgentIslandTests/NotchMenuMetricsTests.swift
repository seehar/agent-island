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
    /// 独立按常量重算内容高度：页眉 + 分段控件 + 各分组（标题 + 行或固定高块 + 页脚）
    /// + 组间距。
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
            height += block.fixedHeight ?? block.rows.reduce(0, +)
            if block.hasFootnote {
                height += NotchMenuMetrics.footnoteHeight
            }
            if index < blocks.count - 1 {
                height += NotchMenuMetrics.groupSpacing
            }
        }
        return height
    }

    @Test("统计分组是固定高的一整块，不按设置行算")
    func statisticsSectionIsFixedHeightBlock() {
        let blocks = NotchMenuMetrics.blocks(for: .statistics)
        #expect(blocks.count == 1)
        #expect(blocks.first?.hasHeader == false)
        #expect(blocks.first?.rows.isEmpty == true)
        #expect(blocks.first?.fixedHeight == UsageStatsMetrics.sectionHeight)
    }

    @Test("统计分组在最高固定开销下也不越过夹取上限")
    func statisticsSectionFitsPanelCap() {
        // 固定开销含胶囊高度（自定义最高 64 → 开销 76）。统计分组是整页内容，
        // 越上限就只能靠页内滚动，这里钉住「默认与最高开销都在上限内」。
        let low = NotchMenuMetrics.panelHeight(for: .statistics, expandedPickerHeight: 0, chromeHeight: 42)
        let high = NotchMenuMetrics.panelHeight(for: .statistics, expandedPickerHeight: 0, chromeHeight: 76)
        #expect(low < NotchMenuMetrics.maxPanelHeight)
        #expect(high <= NotchMenuMetrics.maxPanelHeight)
    }

    @Test("每个分组的高度都等于行表重算的结果")
    func contentHeightMatchesBlockTable() {
        for section in NotchMenuSection.allCases {
            #expect(
                NotchMenuMetrics.contentHeight(for: section) == derivedContentHeight(section),
                "\(section.rawValue) 的解析式高度与行表不一致")
        }
    }

    @Test("智能体分组：每个 Agent 一行带脚注，闸门策略与 Claude 目录各一张卡")
    func agentsSectionSplitsGateIntoSeparateCard() {
        let blocks = NotchMenuMetrics.blocks(for: .agents)
        #expect(blocks.count == 3)

        // 监控的智能体：每个受支持的 Agent 一行（标题 + 集成状态）+ 一行脚注
        #expect(
            blocks[0].rows
                == Array(repeating: NotchMenuMetrics.twoLineRowHeight, count: AgentKind.allCases.count))
        #expect(blocks[0].hasFootnote == true)

        // 审批闸门：问什么 / 应用未运行时 / 待批时自动展开（三个全局档位）
        #expect(blocks[1].rows == Array(repeating: NotchMenuMetrics.rowHeight, count: 3))

        // Claude Code：配置目录
        #expect(blocks[2].rows == [NotchMenuMetrics.rowHeight])
    }

    @Test("行为分组：胶囊 3 行、会话 4 行、通知 2 行（音效与覆盖范围同组）")
    func behaviorSectionRowsMatchRegroupedPages() {
        let blocks = NotchMenuMetrics.blocks(for: .behavior)
        // 音效从通用页搬进来、面板尺寸搬出去：通知组因此是两行，胶囊组是三行。
        #expect(blocks.map(\.rows.count) == [3, 4, 2])
        #expect(blocks.allSatisfy { $0.rows.allSatisfy { $0 == NotchMenuMetrics.rowHeight } })
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

    @Test("每页「内容 + 该页最高的单个展开 + 固定开销」都不越过夹取上限")
    func everySectionFitsCapWithTallestSingleExpansion() {
        // 每页最高的**单个**展开。改任何一页的行数、某个选择器的档位数（或可见选项数）
        // 都要跟着改这张表——被夹取意味着最后一个档位落到可视区外（页内滚动条是隐藏的）。
        let tallestExpansion: [NotchMenuSection: CGFloat] = [
            // 胶囊高度：3 个来源 + 1 行微调
            .general: NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 4),
            // 音效（`SoundSelector.maxVisibleOptions`）与 4 档枚举同高
            .behavior: NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 4),
            // 闸门问什么 / 应用未运行时 / 待批时自动展开都是 3 档
            .agents: NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 3),
            .statistics: 0,
            .about: 0,
        ]

        for section in NotchMenuSection.allCases {
            let expanded = tallestExpansion[section] ?? 0
            // 44 = 外部屏的固定开销；刘海屏是 50，两种都要装得下。
            for chrome in [CGFloat(44), CGFloat(50)] {
                let height = NotchMenuMetrics.panelHeight(
                    for: section, expandedPickerHeight: expanded, chromeHeight: chrome)
                #expect(
                    height == chrome + NotchMenuMetrics.contentHeight(for: section) + expanded,
                    "\(section.rawValue) 的最高单个展开被夹取（固定开销 \(chrome)）")
                #expect(height <= NotchMenuMetrics.maxPanelHeight)
            }
        }
    }

    @Test("音效选择器展开后仍装得进行为页的预算")
    func soundPickerFitsBehaviorBudget() {
        // 音效行在行为页的「通知」组里：它的可见档位数就是那一页最高的单个展开。
        let expanded = NotchMenuMetrics.pickerOptionsHeight(
            visibleOptions: SoundSelector.maxVisibleOptions)
        let height = NotchMenuMetrics.panelHeight(
            for: .behavior, expandedPickerHeight: expanded, chromeHeight: 44)
        #expect(height == 44 + NotchMenuMetrics.contentHeight(for: .behavior) + expanded)
        #expect(height <= NotchMenuMetrics.maxPanelHeight)
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
