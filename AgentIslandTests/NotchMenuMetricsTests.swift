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
    /// 独立按常量重算内容高度：页眉 + 各分组（标题 + 行或固定高块 + 页脚）+ 组间距。
    /// 分组切换已经是竖向侧栏，不占垂直固定开销。
    private func derivedContentHeight(_ section: NotchMenuSection) -> CGFloat {
        var height =
            NotchMenuMetrics.listPaddingHeight + NotchMenuMetrics.pageHeaderHeight
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

    @Test("标记动态分组是固定高的一整块（状态行 + 速度行 + 画廊），不按设置行算")
    func animationsSectionIsFixedHeightBlock() {
        let blocks = NotchMenuMetrics.blocks(for: .animations)
        #expect(blocks.count == 1)
        #expect(blocks.first?.hasHeader == false)
        #expect(blocks.first?.rows.isEmpty == true)
        #expect(blocks.first?.fixedHeight == NotchMenuMetrics.animationsSectionHeight)
        #expect(blocks.first?.hasFootnote == true)
        // 固定块 = 状态行 + 速度行 + 画廊（画廊行数按 Agent 数量与列数推出、窗口封顶）。
        #expect(
            NotchMenuMetrics.animationsSectionHeight
                == NotchMenuMetrics.rowHeight * 2 + NotchMenuMetrics.animationGalleryHeight)
        let total = AgentKind.allCases.count
        let columns = NotchMenuMetrics.animationGalleryColumns
        let rows = (total + columns - 1) / columns
        #expect(rows <= NotchMenuMetrics.animationGalleryMaxVisibleRows)
        #expect(
            NotchMenuMetrics.animationGalleryHeight
                == CGFloat(rows) * NotchMenuMetrics.animationGalleryTileHeight
                + CGFloat(rows - 1) * NotchMenuMetrics.animationGalleryRowSpacing
                + NotchMenuMetrics.rowVerticalPadding,
            "画廊窗口高还要算上网格下方那一条留白，否则刚好装下一屏时仍有一小段空内容可滚")
    }

    @Test("统计分组是固定高的一整块，不按设置行算")
    func statisticsSectionIsFixedHeightBlock() {
        let blocks = NotchMenuMetrics.blocks(for: .statistics)
        #expect(blocks.count == 1)
        #expect(blocks.first?.hasHeader == false)
        #expect(blocks.first?.rows.isEmpty == true)
        #expect(blocks.first?.fixedHeight == UsageStatsMetrics.sectionHeight)
    }

    @Test("读数面不套设置上限：整块内容一次看全，只受窗口高度约束")
    func dashboardsAreNotClampedByTheSettingsCap() {
        // 统计页在设置上限（640）下**每个** chrome 档都会被切掉一截（内容 635 + 开销 ≥ 671），
        // 而它现在不是设置导航里的一页（`NotchMenuSection.isDashboard`）：上限换成
        // `maxDashboardHeight`，整页一次看全——这正是把读数面移出设置导航的理由之一。
        for chrome in Self.reachableChrome {
            let height = NotchMenuMetrics.panelHeight(
                for: .statistics, expandedPickerHeight: 0, chromeHeight: chrome)
            #expect(height == chrome + NotchMenuMetrics.contentHeight(for: .statistics))
        }
        #expect(NotchMenuMetrics.heightCap(for: .statistics) == NotchMenuMetrics.maxDashboardHeight)
        #expect(NotchMenuMetrics.heightCap(for: .quota) == NotchMenuMetrics.maxDashboardHeight)
        // 设置面仍套 640：两档不能塌成一个数（否则「面板不随内容胀高」那条取舍就没了）。
        #expect(NotchMenuMetrics.heightCap(for: .general) == NotchMenuMetrics.maxPanelHeight)
        #expect(NotchMenuMetrics.heightCap(for: .agents) == NotchMenuMetrics.maxPanelHeight)
        // 而且读数面上限必须真的更宽，否则它又被切了。
        #expect(NotchMenuMetrics.maxDashboardHeight > NotchMenuMetrics.maxPanelHeight)

        // 上限要够用：统计页在可达的最大开销下、额度页在最坏运行时组合下都装得下。
        let widestChrome = Self.reachableChrome.max()!
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .statistics, expandedPickerHeight: 0, chromeHeight: widestChrome)
                <= NotchMenuMetrics.maxDashboardHeight)
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .quota, expandedPickerHeight: NewAPIAccountPageState.worstRuntimeHeight,
                chromeHeight: widestChrome)
                <= NotchMenuMetrics.maxDashboardHeight)
    }

    // MARK: - 侧栏

    @Test("侧栏放 4 个配置页 + 收尾的「关于」：读数面与两页子页都不占侧栏位")
    func sidebarSectionsPartitionConfigurationPages() {
        // 「关于」是这一列**最后一项**（不再单独成组、不再被弹性 `Spacer` 推到栏底），
        // 因此侧栏就是这一个数组，没有第二个分组。
        let sidebar = NotchMenuSection.sidebarSections
        #expect(Set(sidebar).count == sidebar.count, "同一个分组在侧栏里出现了两次")
        #expect(sidebar == [.general, .behavior, .notifications, .agents, .about])
        #expect(sidebar.last == .about, "「关于」必须是侧栏的最后一项")

        // 每个分组要么自己就是侧栏项，要么在 `railSelection` 里有一个归属（子页 → 父页）；
        // 没有归属的那种面**不显示侧栏**，必须是读数面。
        for section in NotchMenuSection.allCases {
            switch NotchMenuSection.railSelection(for: section) {
            case let rail?:
                #expect(
                    sidebar.contains(rail),
                    "\(section.rawValue) 点亮的 \(rail.rawValue) 不在侧栏里")
            case nil:
                #expect(
                    NotchMenuSection.isDashboard(section),
                    "\(section.rawValue) 既不在侧栏、也没有侧栏归属，又不算读数面")
            }
        }

        // 两页子页点亮**父页**（macOS 侧栏的惯例：推到子页时父项仍高亮）；
        // 读数面返回 nil（不显示侧栏）。
        #expect(NotchMenuSection.railSelection(for: .shortcuts) == .about)
        #expect(NotchMenuSection.railSelection(for: .animations) == .agents)
        #expect(NotchMenuSection.railSelection(for: .statistics) == nil)
        #expect(NotchMenuSection.railSelection(for: .quota) == nil)
        #expect(NotchMenuSection.railSelection(for: .general) == .general)
    }

    @Test("整条侧栏在最矮的设置面也放得下（不再需要滚动）")
    func sidebarFitsShortestSettingsPage() {
        // 侧栏不再套 `ScrollView`（见 `NotchMenuSidebar`）：4 个配置页 + 收尾的「关于」
        // 必须自己装得下，否则「关于」会被卡片圆角裁掉、用户回不去。判据取**最矮的设置面**
        // （读数面不显示侧栏）与最小可达开销，两档（带标签 / 图标）都核。
        let settingsFaces = NotchMenuSection.allCases.filter {
            NotchMenuSection.railSelection(for: $0) != nil
        }
        let shortest = settingsFaces.min {
            NotchMenuMetrics.contentHeight(for: $0) < NotchMenuMetrics.contentHeight(for: $1)
        }!
        let rowCount = NotchMenuSection.sidebarSections.count

        for showsLabels in [true, false] {
            // 整条栏的实际高度 = 条目表 + **条目之间**的间距（5 项 ⇒ 4 个间隙；没有分隔线、
            // 也没有弹性 `Spacer`）+ 栏自己的内边距，与 `NotchMenuSidebar` 的子视图数一致。
            let needed =
                CGFloat(rowCount)
                * (NotchMenuMetrics.sidebarItemHeight(showsLabels: showsLabels)
                    + NotchMenuMetrics.sidebarItemSpacing)
                - NotchMenuMetrics.sidebarItemSpacing
                + 2 * NotchMenuMetrics.sidebarVerticalPadding
            for chrome in [CGFloat(36), NotchMenuMetrics.maxPanelHeight] {
                let available =
                    NotchMenuMetrics.panelHeight(
                        for: shortest, expandedPickerHeight: 0, chromeHeight: chrome)
                    - NotchMenuMetrics.listPaddingHeight
                #expect(
                    needed <= available,
                    "侧栏（\(showsLabels ? "标签" : "图标")档）需要 \(needed)pt，但 \(shortest.rawValue) 页在 chrome=\(chrome) 时只有 \(available)pt"
                )
            }
        }
    }

    @Test("侧栏档位判据在每一档可达面板宽下都守住画廊硬下限")
    func sidebarLabelCriterionKeepsGalleryFloorAtEveryPanelWidth() {
        // `sidebarShowsLabels` 的唯一职责：**带标签时详情列仍 ≥ 画廊硬下限**。因此按可达的
        // 面板宽扫一遍（三种尺寸档 × 宽屏/窄屏，后者让 `min(screenRect.width * 0.4, …)` 生效），
        // 而不是把推导式抄一遍——抄定义是恒真断言，正是它漏掉过一次 24pt 的建模误差
        // （内容层还要减卡片侧内边距 `panelCardSideInset`，见 `contentAreaWidth`）。
        let screens: [(name: String, width: CGFloat)] = [
            ("wide screen", 1920), ("narrow screen", 1147),
        ]
        for screen in screens {
            for size in PanelSize.allCases {
                let panelWidth = min(
                    min(screen.width * 0.4, NotchMenuMetrics.panelWidthMax) * size.scale,
                    screen.width - 40)
                let contentWidth = NotchMenuMetrics.contentAreaWidth(inPanelWidth: panelWidth)
                let detail = NotchMenuMetrics.settingsDetailWidth(inContentWidth: contentWidth)
                #expect(
                    detail >= NotchMenuMetrics.minDetailWidth,
                    "\(screen.name) · \(size.rawValue)：详情列 \(detail)pt < 画廊硬下限 \(NotchMenuMetrics.minDetailWidth)pt"
                )
            }
        }

        // 实测的出厂几何钉在这儿：改 `panelWidthMax` / `panelCardSideInset` /
        // `panelContentPadding` / 画廊列数时都会失败，逼你按上面那条链重算。
        // 内容区 = 面板宽 480 − 卡片侧内边距 2×12 − 容器内边距 2×4 = 448；
        // 设置详情列 = 448 − 带标签侧栏 113 − 栏间距 12 = 323；画廊硬下限 = 6×44 + 5×8 = 304。
        #expect(NotchMenuMetrics.contentAreaWidth == 448)
        #expect(NotchMenuMetrics.settingsDetailWidth == 323)
        #expect(NotchMenuMetrics.minDetailWidth == 304)
    }

    @Test("侧栏宽度按最长页面名推出，且每个语言都排得下")
    func sidebarWidthFitsEveryLocalizedLabel() {
        // 带标签档存在的理由就是「不用逐个悬停去猜」：标签**必须**排得下。标签列宽是
        // 解析式（栏宽 − 图标左留白 − 图标 − 间距 − 尾距），这里用与渲染同一把尺子
        // 逐语言实测，并核对常量确实等于这条规则在真实 catalog 上的取值——翻译变长时
        // 会在这里失败，提示重算 `sidebarLabeledWidth`。
        let keys =
            NotchMenuSection.sidebarSections.map(Self.titleKey(for:))
        let font = NSFont.systemFont(ofSize: NotchMenuMetrics.sidebarLabelSize, weight: .medium)
        let labelColumn =
            NotchMenuMetrics.sidebarLabeledWidth - NotchMenuMetrics.sidebarIconLeading
            - NotchMenuMetrics.sidebarIconSize - NotchMenuMetrics.sidebarIconLabelGap
            - NotchMenuMetrics.sidebarLabelTrailing

        var longest: (label: String, width: CGFloat) = ("", 0)
        for code in AppLanguage.availableCodes {
            for key in keys {
                let text = LocalizationManager.t(key, languageCode: code)
                // 译文缺失时 `localizedString` 会把键原样返回：映射漂了或 catalog 缺键
                // 都会在这里暴露，而不是让下面的宽度判据量一个不存在的文案。
                if code != "en" {
                    #expect(text != key, "键「\(key)」在 \(code) 里没有译文")
                }
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                if width > longest.width { longest = (text, width) }
                #expect(
                    width <= labelColumn,
                    "\(code) 的「\(text)」排不下：需要 \(width)pt，标签列只有 \(labelColumn)pt")
            }
        }

        #expect(
            NotchMenuMetrics.sidebarLabeledWidth
                == NotchMenuMetrics.sidebarWidth(forLabelWidth: longest.width),
            "侧栏宽度 \(NotchMenuMetrics.sidebarLabeledWidth)pt 不是按最长标签「\(longest.label)」（\(longest.width)pt）推出的——改名 / 加分组 / 改字号后要重算 `sidebarLabeledWidth` 的入参"
        )
        // 带标签档必须真的比图标档宽，否则两档塌成一档、小屏判断失去意义。
        #expect(NotchMenuMetrics.sidebarLabeledWidth > NotchMenuMetrics.sidebarIconWidth)
    }

    @Test("侧栏条目几何：两档的行高都装得下图标")
    func sidebarItemGeometryFitsBothModes() {
        // 图标档：方形瓦片（`sidebarItemBox` = 栏宽）在行高里居中，上下留白要宽过条目间距，
        // 否则瓦片会贴到相邻条目上。
        let iconPad =
            (NotchMenuMetrics.sidebarItemHeight(showsLabels: false)
                - NotchMenuMetrics.sidebarItemBox) / 2
        #expect(iconPad >= NotchMenuMetrics.sidebarItemSpacing, "瓦片上下只留 \(iconPad)pt")
        #expect(NotchMenuMetrics.sidebarItemBox >= NotchMenuMetrics.sidebarIconSize, "瓦片比图标还小")
        #expect(
            NotchMenuMetrics.sidebarItemBox
                <= NotchMenuMetrics.sidebarItemHeight(showsLabels: false),
            "底色 \(NotchMenuMetrics.sidebarItemBox)pt 比行高还高")
        // 图标两侧要留得下呼吸位，否则会顶到栏边。
        #expect(
            NotchMenuMetrics.sidebarIconWidth - NotchMenuMetrics.sidebarIconSize >= 8,
            "\(NotchMenuMetrics.sidebarIconSize)pt 图标在 \(NotchMenuMetrics.sidebarIconWidth)pt 栏里太满")

        // 带标签档：行高要装得下图标 + 上下内缩，且不超过图标档（带标签的那一档更紧凑）。
        let labeledHeight = NotchMenuMetrics.sidebarItemHeight(showsLabels: true)
        #expect(
            labeledHeight
                >= NotchMenuMetrics.sidebarIconSize + 2 * NotchMenuMetrics.sidebarThumbInset)
        #expect(labeledHeight <= NotchMenuMetrics.sidebarItemHeight(showsLabels: false))
    }

    /// 侧栏标签的本地化键（= 英文源文案）。与 `NotchMenuSection.title(_:)` 是同一份映射，
    /// 但那一个只按当前语言解析，这里要逐语言实测。
    private static func titleKey(for section: NotchMenuSection) -> String {
        switch section {
        case .general: return "General"
        case .behavior: return "Behavior"
        case .notifications: return "Notifications"
        case .agents: return "Agents"
        case .about: return "About"
        case .statistics: return "Statistics"
        case .quota: return "Quota"
        case .shortcuts: return "Keyboard Shortcuts"
        case .animations: return "Animations"
        }
    }

    @Test("每个分组的高度都等于行表重算的结果")
    func contentHeightMatchesBlockTable() {
        for section in NotchMenuSection.allCases {
            #expect(
                NotchMenuMetrics.contentHeight(for: section) == derivedContentHeight(section),
                "\(section.rawValue) 的解析式高度与行表不一致")
        }
    }

    @Test("智能体分组：入口行 + 动作条 + 每个 Agent 一行 + 脚注，闸门策略单独一张卡")
    func agentsSectionHasActionRowAndAgentList() {
        let blocks = NotchMenuMetrics.blocks(for: .agents)
        #expect(blocks.count == 2)

        // 监控的智能体：**「标记动态」入口行**（轮播角色缩略图 + 标题 + 副标题）
        // + 动作条（全部启用并安装 / 全部关闭并卸载）+ 每个受支持的 Agent 一行
        // （标题 + 集成状态）+ 一行脚注；卡片高度按 `visibleAgentRows` 封顶——
        // 受支持的 Agent 有十几个，让卡片随接入面无限长高会把这一页撑出面板上限。
        // 入口行的 48pt 是从可见行数里挪的（5 → 4），见 `visibleAgentRows`。
        let expectedAgentRows = min(AgentKind.allCases.count, NotchMenuMetrics.visibleAgentRows)
        #expect(
            blocks[0].rows
                == [NotchMenuMetrics.twoLineRowHeight, NotchMenuMetrics.rowHeight]
                + Array(repeating: NotchMenuMetrics.twoLineRowHeight, count: expectedAgentRows))
        #expect(blocks[0].hasFootnote == true)

        // 审批闸门：问什么 / 应用未运行时 / 待批时自动展开（三个全局档位）
        #expect(blocks[1].rows == Array(repeating: NotchMenuMetrics.rowHeight, count: 3))
    }

    @Test("智能体卡片：渲染全部行，只有窗口封顶（漏掉这条就会让窗口外的 Agent 够不着）")
    func agentCardRendersEveryRowAndOnlyCapsTheWindow() {
        let total = AgentKind.allCases.count
        let layout = NotchMenuMetrics.agentCardLayout(total: total)
        // 渲染数必须等于全部 Agent：截断渲染会让第 N+1 个之后的行在面板里永远够不着。
        #expect(layout.renderedRows == total)
        // 窗口封顶，且真的比内容矮 ⇒ 卡内是可滚动的（这正是「够得着」的前提）。
        #expect(
            layout.windowHeight == CGFloat(NotchMenuMetrics.visibleAgentRows)
                * NotchMenuMetrics.twoLineRowHeight)
        #expect(layout.windowHeight < CGFloat(total) * NotchMenuMetrics.twoLineRowHeight)
        // 少到装得下时不封顶（窗口就是内容高）。
        let few = NotchMenuMetrics.agentCardLayout(total: 2)
        #expect(few.renderedRows == 2)
        #expect(few.windowHeight == 2 * NotchMenuMetrics.twoLineRowHeight)
        // 行内展开的目录编辑器长在窗口里，必须加进窗口高度，否则会被裁掉一半。
        let editor = NotchMenuMetrics.pickerOptionsHeight(
            visibleOptions: AgentDirSelector.visibleOptions)
        let expanded = NotchMenuMetrics.agentCardLayout(total: total, directoryEditorHeight: editor)
        #expect(expanded.windowHeight == layout.windowHeight + editor)
        #expect(expanded.renderedRows == total)
    }

    @Test("受支持的 Agent 多于卡片可见行数时，卡片高度不再随 Agent 数量变化")
    func agentsCardHeightIsCappedByVisibleRows() {
        // 这条钉住「接入新 Agent 不会偷偷把智能体页撑长」：只要受支持的 Agent 数量
        // 超过 `visibleAgentRows`，行数就固定成 `visibleAgentRows`，多出来的在卡内滚动。
        #expect(AgentKind.allCases.count >= NotchMenuMetrics.visibleAgentRows)
        let rows = NotchMenuMetrics.blocks(for: .agents)[0].rows
        // 入口行 + 动作条一行 + 封顶的 Agent 行。
        #expect(rows.count == 2 + NotchMenuMetrics.visibleAgentRows)
        #expect(
            rows.reduce(0, +)
                == NotchMenuMetrics.twoLineRowHeight + NotchMenuMetrics.rowHeight
                + CGFloat(NotchMenuMetrics.visibleAgentRows) * NotchMenuMetrics.twoLineRowHeight)
    }

    @Test("行为分组：刘海 3 行、会话 4 行 + 2 个开关；通知另成一页 5 行")
    func behaviorSectionRowsMatchRegroupedPages() {
        let behavior = NotchMenuMetrics.blocks(for: .behavior)
        // 完成提示/音效/提示范围搬去通知页，会话组补上两个两行开关；
        // 刘海组补上「关闭态刘海」（关闭态胶囊允许占掉多少菜单栏）。
        #expect(behavior.map(\.rows.count) == [3, 6])
        #expect(
            behavior[0].rows == Array(repeating: NotchMenuMetrics.rowHeight, count: 3),
            "刘海组：悬停展开 / 空闲可见性 / 关闭态刘海")
        #expect(
            behavior[1].rows
                == Array(repeating: NotchMenuMetrics.rowHeight, count: 4)
                + Array(repeating: NotchMenuMetrics.twoLineRowHeight, count: 2),
            "会话组：四个选择行 + 子代理明细 / 隐藏闲置两个两行开关")

        let notifications = NotchMenuMetrics.blocks(for: .notifications)
        #expect(notifications.map(\.rows.count) == [5])
        #expect(notifications[0].rows.allSatisfy { $0 == NotchMenuMetrics.rowHeight })
    }

    @Test("没到上限时面板高度就是固定开销加内容加展开量")
    func panelHeightBelowCapIsAdditive() {
        let expected =
            44 + NotchMenuMetrics.contentHeight(for: .general)
            + NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 3)
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general,
                expandedPickerHeight: NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 3),
                chromeHeight: 44) == expected)
    }

    @Test("静态内容被夹到本面上限，正好等于上限时不被削")
    func panelHeightClampsStaticContent() {
        let cap = NotchMenuMetrics.maxPanelHeight
        let content = NotchMenuMetrics.contentHeight(for: .general)

        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: 0, chromeHeight: cap) == cap)
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: 0, chromeHeight: 1000) == cap)
        // 恰好等于上限：仍是这个值（没有被多减）
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: 0, chromeHeight: cap - content) == cap)
    }

    /// 面板固定开销的可达集合（`chromeHeight = max(24, 胶囊高度) + 12`）：
    /// 外接屏自动档（菜单栏 24/25）→ 36/37、内置刘海 32 → 44、
    /// `notch` 档在没有内置刘海的屏上 38 → 50、胶囊高度自定义最高 64 → 76。
    private static let reachableChrome: [CGFloat] = [36, 37, 44, 50, 76]

    /// 静态内容本身就超过本面上限、改由页内滚动接管的组合。新增组合必须登记，
    /// 否则测试失败——那是「又加了一行，面板装不下了」的信号。
    ///
    /// - shortcuts@76（590 + 76 = 666 > 640）：只在胶囊高度自定义到最大时触顶。
    ///
    /// 值选择器的展开增量不在这张表里：panelHeight 把静态内容夹到本面上限之后，
    /// 再加展开增量，只受窗口上限（maxDashboardHeight = 730）约束，因此任何一个选择器
    /// 展开后整份选项都看得见，不会被 640 切掉。最高的组合是智能体页（530 + 106 + 76 = 712）
    /// 与行为页（486 + 138 + 76 = 700），都在 730 以内。
    ///
    /// 读数面（统计 / 额度）不在这个表里：它们不套 640，改用 maxDashboardHeight。
    private static let clampedPairs: Set<String> = [
        "shortcuts@76",
    ]

    @Test("额度分组：动作条 + 详情基准一行，账号个数与可选行不进静态表")
    func quotaSectionHasActionRowAndDetailRows() {
        let blocks = NotchMenuMetrics.blocks(for: .quota)
        #expect(blocks.count == 2)

        // 第一张卡片：动作条（添加账号 / 编辑凭据）。账号**个数**不出现在这里：行数 =
        // min(账号数, `visibleAccountRows`)，由 `NewAPIAccountPageState` 作为运行时增量
        // 交给 `NotchViewModel`（见 `expandedPickerHeight(for: .quota)`）。账号列表因此
        // 可以在卡内滚动，加一个账号不会把这一页撑长。
        #expect(blocks[0].rows == [NotchMenuMetrics.rowHeight])

        // 第二张卡片：静态只有「凭据」一行（配置摘要与编辑入口，任何账号都画）+ 脚注。
        // 身份行与密钥额度行是**可选**的运行时行——「拿不到数据的就不展示」，行数随选中
        // 账号的读数变化，增量同样在 `NewAPIAccountPageState` 里。
        #expect(NotchMenuMetrics.quotaDetailRows == 1)
        #expect(
            blocks[1].rows
                == Array(
                    repeating: NotchMenuMetrics.twoLineRowHeight,
                    count: NotchMenuMetrics.quotaDetailRows))
        #expect(blocks[1].hasFootnote == true)
        #expect(
            NotchMenuMetrics.quotaDetailHeight
                == CGFloat(NotchMenuMetrics.quotaDetailRows) * NotchMenuMetrics.twoLineRowHeight)
        #expect(NotchMenuMetrics.quotaDetailOptionalRowsMax == 2)
    }

    @Test("额度页在最高固定开销下也装得下满窗口的账号列表 + 全部可选行")
    func quotaRuntimeHeightsFitPanelCap() {
        // 两个运行时项都从真实来源推导（不许写死数字）：
        let listWindow = NewAPIAccountPageState.accountListHeight(
            rows: NotchMenuMetrics.visibleAccountRows)
        let optionalRows = NewAPIAccountPageState.detailOptionalHeight(
            rows: NotchMenuMetrics.quotaDetailOptionalRowsMax)
        let editing = NewAPIAccountPageState.editingRuntimeHeight
        let tallest = NewAPIAccountPageState.worstRuntimeHeight
        #expect(
            tallest == max(listWindow + optionalRows, editing),
            "最坏运行时增量应取两段里较大的那一段")

        // 读数态（满窗口 + 两行可选行）比编辑态高：编辑时列表折叠成一行、也没有可选行，
        // 因此两段不会叠加（否则会把面板顶过上限、凭据表单被页内滚动裁掉）。
        #expect(tallest == listWindow + optionalRows)
        #expect(editing < listWindow + optionalRows, "编辑态应当比读数态的最坏组合矮")

        // chrome 76 是可达的最大固定开销（胶囊高度自定义到 64）。
        let height = NotchMenuMetrics.panelHeight(
            for: .quota, expandedPickerHeight: tallest, chromeHeight: 76)
        #expect(height == 76 + NotchMenuMetrics.contentHeight(for: .quota) + tallest)
        // 额度页是读数面：判据用读数面上限（设置面的 640 会把它切掉）。
        #expect(height <= NotchMenuMetrics.heightCap(for: .quota))
    }

    @MainActor
    @Test("每页「内容 + 该页最高的单个展开 + 固定开销」都不越过夹取上限")
    func everySectionFitsCapWithTallestSingleExpansion() {
        // 每页最高的**单个**展开：档位数从真实枚举推出（不写死数字）。
        let tallestCount: [NotchMenuSection: Int] = [
            .general: max(AppLanguage.allCases.count, NotchHeightSelector.visibleOptions,
                          NotchWidthSelector.visibleOptions, TextSizeOption.allCases.count,
                          PanelSize.allCases.count),
            .behavior: max(HoverExpand.allCases.count, IdleNotchVisibility.allCases.count,
                           ClosedCapsuleLayout.allCases.count, SessionRetention.allCases.count,
                           SessionRowDensity.allCases.count, SessionRowClickAction.allCases.count,
                           RefreshCadence.allCases.count),
            .notifications: max(SoundSelector.maxVisibleOptions, QuietHours.allCases.count,
                                NotificationScope.allCases.count, CompletionBadge.allCases.count),
            .agents: max(AgentDirSelector.visibleOptions, ApprovalAskScope.allCases.count,
                         ApprovalDegradation.allCases.count, ApprovalAutoExpand.allCases.count),
            .quota: 0, .statistics: 0, .about: 0, .shortcuts: 0, .animations: 0,
        ]

        for section in NotchMenuSection.allCases {
            let expanded =
                section == .quota
                ? NewAPIAccountPageState.worstRuntimeHeight
                : NotchMenuMetrics.pickerOptionsHeight(visibleOptions: tallestCount[section] ?? 0)
            let content = NotchMenuMetrics.contentHeight(for: section)

            for chrome in Self.reachableChrome {
                let key = "\(section.rawValue)@\(Int(chrome))"
                let cap = NotchMenuMetrics.heightCap(for: section)
                // 与 `NotchMenuMetrics.panelHeight` 同一笔账：静态内容先夹到本面上限，
                // 展开增量再加在夹取之后、总量封在窗口上限。
                let expected = min(
                    min(chrome + content, cap) + expanded, NotchMenuMetrics.maxDashboardHeight)
                let height = NotchMenuMetrics.panelHeight(
                    for: section, expandedPickerHeight: expanded, chromeHeight: chrome)

                #expect(
                    height == expected,
                    "\(key) 高度不符合解析式：内容 \(content) + 展开 \(expanded) + 开销 \(chrome)")

                if Self.clampedPairs.contains(key) {
                    #expect(
                        expected < chrome + content + expanded,
                        "\(key) 登记为被夹取，但它其实装得下")
                } else {
                    #expect(
                        expected == chrome + content + expanded,
                        "\(key) 的最高单个展开被夹取：内容 \(content) + 展开 \(expanded) + 开销 \(chrome)")
                }
            }
        }
    }

    @Test("档位说明的可用宽 = 详情列 − 展开缩进 − 行内边距 − 固定开销")
    func optionRowTextWidthMatchesLayout() {
        // 说明与标签共用这一条：它是「档位说明放不放得下」的唯一判据，写成常量而不是
        // 各处手算，改动选项行几何时这里会先红。
        let expected =
            NotchMenuMetrics.settingsDetailWidth - NotchMenuMetrics.optionIndent
            - 2 * NotchMenuMetrics.optionHorizontalPadding - 8 - 8
            - NotchMenuMetrics.checkmarkWidth
        #expect(NotchMenuMetrics.optionRowTextWidth == expected)
        // 说明与标签都在这一行里，因此它必须比单个标签列宽——否则任何说明都放不下。
        #expect(NotchMenuMetrics.optionRowTextWidth > 0)
        #expect(
            NotchMenuMetrics.optionRowTextWidth
                < NotchMenuMetrics.settingsDetailWidth,
            "说明的可用宽不该等于整列宽：右边还有选中勾与弹性下限")
    }

    @Test("档位文案在选项行里放得下：按 catalog 逐语言实测")
    func optionCopyFitsTheOptionRow() {
        // 选项行只有一行：标签 + 8pt 间隙 + 说明必须塞进 `optionRowTextWidth`，否则
        // `truncationMode(.middle)` 会把整句吞掉半截（用户报过「关闭态刘海」那三行说明）。
        // 键就是代码里用的那条 en 原文，宽度按 catalog 的**译文**实测——翻译变长、
        // 或选项行几何变窄，都会在这里红。列表是「当前带说明 / 标签偏长的行」的抽样：
        // 新增同类行时在这里补一行（智能体页的三条保护档位名没列进来：它们是设计文档
        // `docs/approval-multi-agent.md` 里写明的档位名，en 侧按保守预算量超出 5–6pt）。
        let pairs: [(name: String, labelKey: String, detailKey: String?)] = [
            ("关闭态刘海 / 只留计数", "Badge Only", nil),
            ("关闭态刘海 / 只留挖孔", "Notch Only", nil),
            ("关闭态刘海 / 完整胶囊", "Full Capsule", nil),
            ("单击动作 / 打开对话", "Open Chat", nil),
            ("单击动作 / 定位终端", "Focus Terminal", nil),
            ("屏幕 / 自动", "Automatic", "Built-in or Main"),
        ]
        let labelFont = NSFont.systemFont(ofSize: AppTypeScale.option)
        let detailFont = NSFont.systemFont(ofSize: AppTypeScale.footnote)
        let budget = NotchMenuMetrics.optionRowTextWidth

        for code in AppLanguage.availableCodes {
            for pair in pairs {
                let label = LocalizationManager.t(pair.labelKey, languageCode: code)
                // 译文缺失时 `localizedString` 会把键原样返回：键名漂了、或 catalog 缺键
                // 都会在这里暴露，而不是让下面的宽度判据量一个不存在的文案。
                if code != "en" {
                    #expect(label != pair.labelKey, "键「\(pair.labelKey)」在 \(code) 里没有译文")
                }
                var used = (label as NSString).size(withAttributes: [.font: labelFont]).width
                if let detailKey = pair.detailKey {
                    let detail = LocalizationManager.t(detailKey, languageCode: code)
                    if code != "en" {
                        #expect(detail != detailKey, "键「\(detailKey)」在 \(code) 里没有译文")
                    }
                    used += 8 + (detail as NSString).size(withAttributes: [.font: detailFont]).width
                }
                #expect(
                    used <= budget,
                    "\(code) 的「\(label)」用了 \(used)pt，选项行只有 \(budget)pt：要么收短文案，要么改走 PreferencePickerRow.helpText")
            }
        }
    }

    @Test("选项块高度随选项数线性增长，空列表只留内边距")
    func pickerOptionsHeightScalesLinearly() {
        #expect(
            NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 0)
                == NotchMenuMetrics.optionListPadding)
        #expect(
            NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 2)
                - NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 1)
                == NotchMenuMetrics.optionRowHeight)
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

    @Test("行内小按钮的命中区不低于舒适下限，且顶不高选项行")
    func compactHitTargetMeetsComfortFloor() {
        // 20pt 见方的 ± 按钮在光标下太容易落空：`SettingsStepperRow` 把命中区外扩到这一档
        // （画出来的方块仍是 20），因此它必须不小于 macOS 的舒适下限。
        #expect(NotchMenuMetrics.compactHitTarget >= 28)
        // 命中区要装得进选项行的高度，否则会把行顶高、让面板高度脱离解析式。
        #expect(NotchMenuMetrics.compactHitTarget <= NotchMenuMetrics.optionRowHeight)
        // 而且必须真的比画出来的东西大：跟图标块一样大就等于没外扩。
        #expect(NotchMenuMetrics.compactHitTarget > NotchMenuMetrics.badgeSize)
    }
}
