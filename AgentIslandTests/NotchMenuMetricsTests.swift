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
            "画廊窗口高还要算上网格下方那一条留白，否则 18 枚刚好装下时仍有一小段空内容可滚")
    }

    @Test("统计分组是固定高的一整块，不按设置行算")
    func statisticsSectionIsFixedHeightBlock() {
        let blocks = NotchMenuMetrics.blocks(for: .statistics)
        #expect(blocks.count == 1)
        #expect(blocks.first?.hasHeader == false)
        #expect(blocks.first?.rows.isEmpty == true)
        #expect(blocks.first?.fixedHeight == UsageStatsMetrics.sectionHeight)
    }

    @Test("统计分组：上限压到 640 后在所有 chrome 档都被夹取，页内滚动接管")
    func statisticsSectionIsClampedAtTheCap() {
        // 上限 728 时统计页是 635 + 76 = 711，最紧的一档之一；降到 640 之后它在**每一个**
        // chrome 档都被夹取（最小的 36 也已经是 671）。这是有意的取舍：面板不再一路胀高，
        // 代价是统计页要滚动才能看全趋势图。
        let low = NotchMenuMetrics.panelHeight(
            for: .statistics, expandedPickerHeight: 0, chromeHeight: 42)
        let high = NotchMenuMetrics.panelHeight(
            for: .statistics, expandedPickerHeight: 0, chromeHeight: 76)
        #expect(low == NotchMenuMetrics.maxPanelHeight)
        #expect(high == NotchMenuMetrics.maxPanelHeight)
        // 夹取之后仍要能说清「本来该多高」——否则这一档会退化成一个没有来由的数字。
        #expect(
            NotchMenuMetrics.contentHeight(for: .statistics) + 76 > NotchMenuMetrics.maxPanelHeight,
            "统计页不再越界，说明上限或内容高改了，clampedPairs 里的登记要一起更新")
    }

    // MARK: - 侧栏

    @Test("侧栏条目把一级分组分完，且互不重叠")
    func sidebarSectionsPartitionTopLevelGroups() {
        let sidebar = NotchMenuSection.sidebarSections + NotchMenuSection.sidebarFooterSections
        #expect(Set(sidebar).count == sidebar.count, "同一个分组在侧栏里出现了两次")
        // 不占侧栏位的两页（快捷键 / 标记动态）各有页内入口行，其余必须都在侧栏里。
        let hidden: Set<NotchMenuSection> = [.shortcuts, .animations]
        let missing = Set(NotchMenuSection.allCases)
            .subtracting(hidden)
            .subtracting(sidebar)
        #expect(missing.isEmpty, "这些分组既不在侧栏也没有页内入口：\(missing.map(\.rawValue))")
    }

    @Test("侧栏底部常驻项在最矮的一页也放得下")
    func sidebarFooterAlwaysFits() {
        // 额度页在没有账号时内容高只有 218pt，扣掉容器上下内边距只剩 238pt——放不下
        // 6 个一级分组（312pt）。因此上面那组滚动、下面这组钉底；这里守住「钉底这组
        // 在任何一页都放得下」，否则「关于」会在被裁掉的卡片里消失，用户再也回不去。
        let needed =
            CGFloat(NotchMenuSection.sidebarFooterSections.count)
            * (NotchMenuMetrics.sidebarItemHeight + NotchMenuMetrics.sidebarItemSpacing)
            + NotchMenuMetrics.sidebarDividerThickness + NotchMenuMetrics.sidebarItemSpacing
        let shortest = NotchMenuSection.allCases.min {
            NotchMenuMetrics.contentHeight(for: $0) < NotchMenuMetrics.contentHeight(for: $1)
        }!
        for chrome in [CGFloat(36), NotchMenuMetrics.maxPanelHeight] {
            let available =
                NotchMenuMetrics.panelHeight(
                    for: shortest, expandedPickerHeight: 0, chromeHeight: chrome)
                - NotchMenuMetrics.listPaddingHeight
            #expect(
                needed <= available,
                "钉底项需要 \(needed)pt，但 \(shortest.rawValue) 页在 chrome=\(chrome) 时只有 \(available)pt")
        }
    }

    @Test("侧栏不吃掉统计页与标记动态页的版面")
    func sidebarKeepsCalibratedPageWidths() {
        // 详情区宽度 = 面板宽度预算 − 容器左右内边距 − 窄轨 − 栏间距。四项都取常量：
        // 此前这里写的是 `- 16 - sidebarItemSpacing`，与实际版面的「4×2 + 12」数值恰好相等
        // 才没暴露——改任一档都会静默失配。
        let content =
            NotchMenuMetrics.panelWidthMax
            - 2 * NotchMenuMetrics.panelContentPadding
            - NotchMenuMetrics.sidebarWidth
            - NotchMenuMetrics.sidebarContentSpacing
        // 统计页以 panelWidthMax − 16 为标定基准；紧凑档（0.88）已经贴到 422.4。
        // 侧栏后详情区仍要不低于紧凑档的标定宽度，否则趋势图绘图区会被新裁。
        let compactCalibrated = NotchMenuMetrics.panelWidthMax * 0.88 - 16
        #expect(content >= compactCalibrated, "统计页详情区 \(content)pt 窄于紧凑档标定的 \(compactCalibrated)pt")
        // 标记动态页的画廊是硬下限 304pt。
        #expect(content >= 304, "画廊放不下：详情区只有 \(content)pt")
    }

    @Test("侧栏不能宽成一个空槽")
    func sidebarStaysProportionateToTheDetailColumn() {
        // 初版侧栏给 44pt、条目底色 40pt，几乎占满整条栏，相对右侧几百点的详情区
        // 就是一个过宽的空槽（实机截图就是这个观感）。这条钉住「侧栏只是图标栏，
        // 不是第二列内容」：它占的宽度必须显著小于详情区，且自身要装得下图标。
        let detail =
            NotchMenuMetrics.panelWidthMax
            - 2 * NotchMenuMetrics.panelContentPadding
            - NotchMenuMetrics.sidebarWidth
            - NotchMenuMetrics.sidebarContentSpacing
        #expect(
            NotchMenuMetrics.sidebarWidth * 4 <= detail,
            "侧栏 \(NotchMenuMetrics.sidebarWidth)pt 相对详情区 \(detail)pt 太宽了")
        // 图标两侧要留得下呼吸位，否则会顶到栏边。
        #expect(
            NotchMenuMetrics.sidebarWidth - NotchMenuMetrics.sidebarIconSize >= 8,
            "\(NotchMenuMetrics.sidebarIconSize)pt 图标在 \(NotchMenuMetrics.sidebarWidth)pt 栏里太满")
        // 分隔线不能比栏还宽。
        #expect(NotchMenuMetrics.sidebarDividerLength < NotchMenuMetrics.sidebarWidth)
        // 选中/悬停底色是**正方形**瓦片（宽高共用 `sidebarItemBox`）：行高是 40
        // （与设置行对齐），底色若铺满行高会读成一块竖长方（实机截图就是这个观感）。
        // 正方形是结构保证的，能断言的是它装得下、且上下留白够。
        #expect(
            NotchMenuMetrics.sidebarItemBox >= NotchMenuMetrics.sidebarIconSize,
            "瓦片比图标还小")
        #expect(
            NotchMenuMetrics.sidebarItemBox <= NotchMenuMetrics.sidebarItemHeight,
            "底色 \(NotchMenuMetrics.sidebarItemBox)pt 比行高 \(NotchMenuMetrics.sidebarItemHeight)pt 还高"
        )
        // 上下留白要够，否则瓦片会贴到相邻条目上。
        let pad = (NotchMenuMetrics.sidebarItemHeight - NotchMenuMetrics.sidebarItemBox) / 2
        #expect(pad >= NotchMenuMetrics.sidebarItemSpacing, "瓦片上下只留 \(pad)pt，比条目间距还窄")
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

    @Test("行为分组：刘海 2 行、会话 4 行 + 2 个开关；通知另成一页 5 行")
    func behaviorSectionRowsMatchRegroupedPages() {
        let behavior = NotchMenuMetrics.blocks(for: .behavior)
        // 完成提示/音效/提示范围搬去通知页，会话组补上两个两行开关。
        #expect(behavior.map(\.rows.count) == [2, 6])
        #expect(
            behavior[0].rows == Array(repeating: NotchMenuMetrics.rowHeight, count: 2),
            "刘海组：悬停展开 / 空闲可见性")
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

    @Test("超过上限时面板高度被夹住，正好等于上限时不被削")
    func panelHeightIsClampedAtCap() {
        let cap = NotchMenuMetrics.maxPanelHeight
        let content = NotchMenuMetrics.contentHeight(for: .general)

        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: cap, chromeHeight: 400) == cap)
        #expect(
            NotchMenuMetrics.panelHeight(
                for: .general, expandedPickerHeight: 1000, chromeHeight: 400) == cap)
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
    ///
    /// 上限从 728 降到 640 之后，下列组合**会被夹取**，该档下由页内滚动接管（滚动条隐藏）：
    ///
    /// - `general@{36,37,44,50,76}`：通用页内容 480 + 最高单个展开 138（刘海高度 4 档）
    ///   ＝ 618，最小的 chrome 36 就已经是 654。因此**通用页在所有 chrome 档下展开选择器
    ///   都会被切掉十几 pt**——这是把上限压到 640 的直接代价。
    /// - `agents@{36,37,44,50,76}`：530 + 106 ＝ 636，同样在最小 chrome 就越界。
    /// - `statistics@{36,37,44,50,76}`：635 + 0 ＝ 635，最小 chrome 也是 663。统计页在
    ///   任何 chrome 档下都需要滚动才能看全趋势图。
    /// - `behavior@{76}`（660）与 `shortcuts@{76}`（666）：只在胶囊高度自定义到最大时触顶。
    ///
    /// 新增分组、加行或加档位若顶到上限，必须登记到这里（见 `NotchMenuLayout.maxPanelHeight`
    /// 的加法）。
    private static let clampedPairs: Set<String> = [
        "general@36", "general@37", "general@44", "general@50", "general@76",
        "behavior@76",
        "agents@36", "agents@37", "agents@44", "agents@50", "agents@76",
        "statistics@36", "statistics@37", "statistics@44", "statistics@50", "statistics@76",
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
        #expect(height <= NotchMenuMetrics.maxPanelHeight)
    }

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
                    HoverExpand.allCases.count,
                    IdleNotchVisibility.allCases.count,
                    SessionRetention.allCases.count,
                    SessionRowDensity.allCases.count,
                    SessionRowClickAction.allCases.count,
                    RefreshCadence.allCases.count)),
            // 音效列表的档位总数是动态的（内置 + 用户自带），可见行数才是常量。
            .notifications: max(
                NotchMenuMetrics.pickerOptionsHeight(
                    visibleOptions: SoundSelector.maxVisibleOptions),
                NotchMenuMetrics.pickerOptionsHeight(
                    visibleOptions: max(
                        QuietHours.allCases.count,
                        NotificationScope.allCases.count,
                        CompletionBadge.allCases.count))),
            .agents: NotchMenuMetrics.pickerOptionsHeight(
                visibleOptions: max(
                    AgentDirSelector.visibleOptions,
                    ApprovalAskScope.allCases.count,
                    ApprovalDegradation.allCases.count,
                    ApprovalAutoExpand.allCases.count)),
            // 额度页的运行时增量有两段（账号列表窗口 / 「编辑凭据」态），生产代码里互斥
            // （编辑态折叠列表），因此「最高的单个展开」取两段里较大的那一段。
            .quota: NewAPIAccountPageState.worstRuntimeHeight,
            // 统计页与关于页都没有「撑高面板的展开项」：统计页的范围选择器是页眉控件，
            // 展开块占的是页内滚动视口（见 UsageStatsLayoutTests.rangePickerLeavesUsableViewport）。
            .statistics: 0,
            .about: 0,
            // 快捷键页也没有撑高面板的展开项：录制行是行内的按键块，不展开。
            .shortcuts: 0,
            // 标记动态页同样没有撑高面板的展开项：状态选择是行内的分段控件。
            .animations: 0,
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

    @Test("音效选择器展开后仍装得进通知页的预算")
    func soundPickerFitsNotificationsBudget() {
        let expanded = NotchMenuMetrics.pickerOptionsHeight(
            visibleOptions: SoundSelector.maxVisibleOptions)
        let height = NotchMenuMetrics.panelHeight(
            for: .notifications, expandedPickerHeight: expanded, chromeHeight: 44)
        #expect(height == 44 + NotchMenuMetrics.contentHeight(for: .notifications) + expanded)
        #expect(height <= NotchMenuMetrics.maxPanelHeight)
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
