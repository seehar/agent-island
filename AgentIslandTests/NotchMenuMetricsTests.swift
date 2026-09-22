//
//  NotchMenuMetricsTests.swift
//  AgentIslandTests
//
//  设置面板高度由常量解析式算出，而面板实际排版由 blocks(for:) 的行表决定。
//  两者一旦漂移，面板就会裁掉页面底部或留出空白；这里把等价关系钉死。
//

import AppKit
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

        // 监控的智能体：每个受支持的 Agent 一行（标题 + 集成状态）+ 一行脚注，
        // 但卡片高度按 `visibleAgentRows` 封顶——受支持的 Agent 有十几个，
        // 让卡片随接入面无限长高会把这一页撑出面板上限。
        let expectedAgentRows = min(AgentKind.allCases.count, NotchMenuMetrics.visibleAgentRows)
        #expect(
            blocks[0].rows
                == Array(repeating: NotchMenuMetrics.twoLineRowHeight, count: expectedAgentRows))
        #expect(blocks[0].hasFootnote == true)

        // 审批闸门：问什么 / 应用未运行时 / 待批时自动展开（三个全局档位）
        #expect(blocks[1].rows == Array(repeating: NotchMenuMetrics.rowHeight, count: 3))

        // Claude Code：配置目录
        #expect(blocks[2].rows == [NotchMenuMetrics.rowHeight])
    }

    @Test("受支持的 Agent 多于卡片可见行数时，卡片高度不再随 Agent 数量变化")
    func agentsCardHeightIsCappedByVisibleRows() {
        // 这条钉住「接入新 Agent 不会偷偷把智能体页撑长」：只要受支持的 Agent 数量
        // 超过 `visibleAgentRows`，行数就固定成 `visibleAgentRows`，多出来的在卡内滚动。
        #expect(AgentKind.allCases.count >= NotchMenuMetrics.visibleAgentRows)
        let rows = NotchMenuMetrics.blocks(for: .agents)[0].rows
        #expect(rows.count == NotchMenuMetrics.visibleAgentRows)
        // 与接入面变大之前同高（4 × 48 = 192）：那一页的夹取组合因此保持原样。
        #expect(rows.reduce(0, +) == 192)
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

    /// 面板固定开销的可达集合（`chromeHeight = max(24, 胶囊高度) + 12`）：
    /// 外接屏自动档（菜单栏 24/25）→ 36/37、内置刘海 32 → 44、
    /// `notch` 档在没有内置刘海的屏上 38 → 50、胶囊高度自定义最高 64 → 76。
    private static let reachableChrome: [CGFloat] = [36, 37, 44, 50, 76]

    /// 已知被夹取（超出上限、改由页内滚动接管）的组合。**新增组合必须显式登记在这里**，
    /// 否则测试失败——那正是「又加了一行/一档，最后一个档位落到可视区外」的信号。
    private static let clampedPairs: Set<String> = ["behavior@76", "agents@76"]

    @MainActor
    @Test("每页「内容 + 该页最高的单个展开 + 固定开销」都不越过夹取上限")
    func everySectionFitsCapWithTallestSingleExpansion() {
        // 每页最高的**单个**展开全部从真实来源推导（枚举的 allCases、选择器自己的
        // `visibleOptions`），不写死数字：枚举加一档、屏幕数变多都会在这里体现出来。
        let tallestExpansion: [NotchMenuSection: CGFloat] = [
            .general: NotchMenuMetrics.pickerOptionsHeight(
                visibleOptions: max(
                    AppLanguage.allCases.count,
                    NSScreen.screens.count + 1,  // 自动 + 每块屏幕
                    NotchHeightSelector.visibleOptions,
                    NotchWidthSelector.visibleOptions,
                    TextSizeOption.allCases.count,
                    PanelSize.allCases.count)),
            .behavior: NotchMenuMetrics.pickerOptionsHeight(
                visibleOptions: max(
                    SoundSelector.maxVisibleOptions,
                    HoverExpand.allCases.count,
                    IdleNotchVisibility.allCases.count,
                    CompletionBadge.allCases.count,
                    SessionRetention.allCases.count,
                    SessionRowDensity.allCases.count,
                    SessionRowClickAction.allCases.count,
                    RefreshCadence.allCases.count,
                    NotificationScope.allCases.count)),
            .agents: NotchMenuMetrics.pickerOptionsHeight(
                visibleOptions: max(
                    ClaudeDirSelector.visibleOptions,
                    ApprovalAskScope.allCases.count,
                    ApprovalDegradation.allCases.count,
                    ApprovalAutoExpand.allCases.count)),
            // 统计页与关于页都没有「撑高面板的展开项」：统计页的范围选择器是页眉控件，
            // 展开块占的是页内滚动视口（见 UsageStatsLayoutTests.rangePickerLeavesUsableViewport）。
            .statistics: 0,
            .about: 0,
        ]

        for section in NotchMenuSection.allCases {
            let expanded = tallestExpansion[section] ?? 0
            let content = NotchMenuMetrics.contentHeight(for: section)

            for chrome in Self.reachableChrome {
                let key = "\(section.rawValue)@\(Int(chrome))"
                let height = NotchMenuMetrics.panelHeight(
                    for: section, expandedPickerHeight: expanded, chromeHeight: chrome)

                if Self.clampedPairs.contains(key) {
                    #expect(
                        height == NotchMenuMetrics.maxPanelHeight,
                        "\(key) 应当被夹到上限（内容 \(content) + 展开 \(expanded) + 开销 \(chrome)）")
                } else {
                    #expect(
                        height == chrome + content + expanded,
                        "\(key) 的最高单个展开被夹取：内容 \(content) + 展开 \(expanded) + 开销 \(chrome)")
                    #expect(height <= NotchMenuMetrics.maxPanelHeight)
                }
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
