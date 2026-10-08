//
//  NotchMenuLayout.swift
//  AgentIsland
//
//  设置面板的分组定义与版面尺寸。分组枚举同时被视图（渲染分段控件）与
//  NotchViewModel（按当前分组撑高面板）使用；版面常量集中在这里，行的几何
//  也在这里——视图与高度计算读同一组值，避免各写一套数值而漂移。
//

import CoreGraphics
import Foundation

/// 设置面板的分组。设置项按用途拆开，面板只按当前分组撑高，
/// 因此每个分组都保持在一屏之内，不再随设置项增加而越拉越长。
nonisolated enum NotchMenuSection: String, CaseIterable, Identifiable, Sendable {
    /// 应用级偏好：语言、屏幕、胶囊高度、胶囊宽度、内容字号、面板尺寸、
    /// 登录时启动、辅助功能、接管键盘焦点。
    case general
    /// 行为类偏好：悬停展开、空闲可见性、会话保留、列表密度/过滤与刷新频率。
    case behavior
    /// 通知音效、音量、安静时段、提示范围与完成提示。
    case notifications
    /// 各 Agent CLI 的监控开关与集成状态、三个全局的工具调用保护档位、Claude 配置目录。
    case agents
    /// 用量统计：token、会话与工具调用的汇总读数（只读页，不是配置）。
    case statistics
    /// New API 额度：账户余额与当前 Key 额度的读数 + 取数配置（只读页）。
    case quota
    /// 版本与更新、GitHub、退出。
    case about
    /// 键盘快捷键：全局一条 + 面板内数条，可逐条录制。**不占侧栏位**——侧栏只放
    /// 一级分组，这一页的入口在「关于」页。
    case shortcuts
    /// 标记动态：把各 Agent 的运行时**像素角色**一次铺开预览（空闲 / 处理中 / 待审批）。
    /// 同样**不占侧栏位**的页，入口是「监控的智能体」卡片的第一行。
    case animations

    var id: String { rawValue }

    /// 侧栏的 5 个入口（显示序即这个序）：**4 个配置页 + 收尾的「关于」**。
    ///
    /// 「关于」就是这一列的**最后一项**：它曾经单独成组、被弹性 `Spacer` 钉到栏底
    /// （在面板里与前四项隔着一大段空白），用户反馈不如直接排在菜单最后 —— 于是
    /// 取消了那个分组，分组线也随之删掉。顺序即上面这个数组的序，不再有第二个分组。
    ///
    /// 统计与额度是**读数**（仪表盘），不是配置：它们不占侧栏位、也不显示侧栏，
    /// 而是占满整宽的一条独立内容面，入口是面板头部的图表 / 额度按钮
    /// （`NotchViewModel.toggleStatistics` / `toggleQuota`）。这么做解掉两个结构问题：
    /// ① 侧栏本来要滚动（6 项 250pt 高过最矮一页的可用高度，当前页那项会被挤到视口外）；
    /// ② 统计页套在设置上限（640）下每个 chrome 档都会被切掉一截（内容 635 + 开销）。
    static let sidebarSections: [NotchMenuSection] = [
        .general, .behavior, .notifications, .agents, .about,
    ]

    /// 读数面（统计 / 额度）：不占侧栏位、不显示侧栏，整块内容占满面板宽度，
    /// 且不套设置面的高度上限（见 `NotchMenuMetrics.heightCap(for:)`）。
    static func isDashboard(_ section: NotchMenuSection) -> Bool {
        section == .statistics || section == .quota
    }

    /// 该分组在侧栏里该点亮哪一项；nil = 这个面**不显示侧栏**。
    ///
    /// 不占侧栏位的两页（快捷键 / 标记动态）保留侧栏并点亮它的**父页**——与 macOS
    /// 侧栏「推到子页时父项仍高亮」一致，比「一列里没有任何一项选中」更好读。
    /// 写成穷举 switch 而不是查表：新加分组时编译器会逼你在这里做一次决定。
    static func railSelection(for section: NotchMenuSection) -> NotchMenuSection? {
        switch section {
        case .general, .behavior, .notifications, .agents, .about:
            return section
        // 入口是「关于」页那一行（`AboutSettingsPage` 的「Keyboard Shortcuts」）。
        case .shortcuts: return .about
        // 入口是「监控的智能体」卡片的第一行（那一行就是「标记动态」入口）。
        case .animations: return .agents
        // 读数面不显示侧栏（见 `isDashboard`）。
        case .statistics, .quota: return nil
        }
    }

    /// 分段控件的图标；只表达分组含义，具体设置行各自用自己的图标。
    var symbolName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .behavior: return "switch.2"
        case .notifications: return "bell.badge"
        case .agents: return "cpu"
        case .statistics: return "chart.bar.xaxis"
        case .quota: return "creditcard"
        case .shortcuts: return "keyboard"
        case .animations: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

/// 设置面板的版面常量与高度计算。
///
/// 常量与视图里的实际排版一一对应（`SettingsKit` 里的行、卡片与分组都读这里的值），
/// 面板高度因此可以直接由常量推出；`blocks(for:)` 的分组表与页面里分组的顺序一致。
/// 数值经离屏渲染实测校准（把面板撑到 2000pt 再量页面内容的真实底边）。
nonisolated enum NotchMenuMetrics {
    // MARK: - 面板

    /// 面板宽度上限：实例列表、设置面板与统计页共用同一个宽度
    /// （`NotchViewModel.openedSize` 与版面测试都读它，不要再写字面量）。
    static let panelWidthMax: CGFloat = 480

    /// 展开态卡片的**头部内边距**：卡片在面板宽度预算之外，左右各再留这一圈。
    ///
    /// `panelWidthMax` 约束的是「内容 + 侧内边距」这一层；头部内边距是外圈留白，所以
    /// 卡片实测宽度 = `panelWidthMax + 2 × panelCardHeaderInset` = 518pt。夹掉这一圈会把
    /// 内容一起压窄 38pt，观感上整块缩一截（这正是这批改动一度出现的现象）。
    static let panelCardHeaderInset: CGFloat = 19
    /// 展开态卡片的**侧内边距**：内容与卡片左右边缘的距离，由上面两圈共同组成
    /// （`panelCardHeaderInset + panelCardSideInset` = 31pt）。
    static let panelCardSideInset: CGFloat = 12

    /// 侧栏窄轨与详情列之间的横向间距。
    ///
    /// **不复用 `sidebarItemSpacing`**（那是轨内条目之间的纵向间距）：两列之间要的是
    /// 「这是两栏」的呼吸感，4pt 会让侧栏和详情糊成一整块。配合容器左右内边距取小值
    /// （`NotchMenuView` 的 4pt），合计与改动前同宽——详情列宽度不变，窄轨反而左移。
    static let sidebarContentSpacing: CGFloat = 12

    // MARK: - 行的几何

    /// 行左侧图标块的边长与圆角。圆角取全应用档位（`AppRadius`），不再各写一个数。
    static let badgeSize: CGFloat = 22
    static let badgeRadius: CGFloat = AppRadius.control
    /// 图标块与标题之间的间距。
    static let badgeGap: CGFloat = 10
    /// 行内小按钮（± 微调、返回箭头这类，见 `SettingsStepperRow`）的**命中区**下限。
    ///
    /// 画出来的方块是 20pt，命中区外扩到这一档：20pt 见方在光标下太容易落空，macOS 的
    /// 舒适下限是 28pt。`optionRowHeight` 是 32，因此这个下限顶不高选项行。
    static let compactHitTarget: CGFloat = 28
    /// 行的左右内边距。
    static let rowHorizontalPadding: CGFloat = 12
    /// 行的上下内边距：单行行高 = 图标块 22 + 9×2 = 40。
    static let rowVerticalPadding: CGFloat = 9
    /// 标题与副标题之间的间距。
    static let titleSpacing: CGFloat = 1
    /// 卡片圆角（同上：取 `AppRadius` 的卡片档）。
    static let cardRadius: CGFloat = AppRadius.card
    /// 分隔线、展开选项块的左侧缩进：与标题列对齐。
    static var separatorInset: CGFloat { rowHorizontalPadding + badgeSize + badgeGap }
    /// 选项行自己的左右内边距；选项块向左退回这么多，文字就落在标题列上。
    static let optionHorizontalPadding: CGFloat = 10
    static var optionIndent: CGFloat { separatorInset - optionHorizontalPadding }

    // MARK: - 行高

    /// 单行设置行（按钮、选择行）。注意开关行会更高：开关控件 24 比图标块 22 高，
    /// 单行开关行是 42——本仓库目前没有单行开关行，用到时按这个值量过再写进分组表。
    static let rowHeight: CGFloat = 40
    /// 两行设置行（标题 + 副标题）：比图标块高，行高在视图里固定成这个值，
    /// 有无副标题都不改变面板高度。
    static let twoLineRowHeight: CGFloat = 48
    /// 单行开关行：开关控件 24 比图标块 22 高，行高因此比普通行多 2。
    static let toggleRowHeight: CGFloat = 42
    /// 展开的选择器里的一行选项（含微调行）。
    static let optionRowHeight: CGFloat = 32
    /// 选项列表的上下留白：选项块总高 = 选项数 × 行高 + 这个值。
    static let optionListPadding: CGFloat = 10
    static let optionListTopPadding: CGFloat = 4
    static let optionListBottomPadding: CGFloat = 6

    // MARK: - 分组与页眉

    /// 分组标题行高（11 号大写高文本一行）与标题到卡片的间距。
    static let sectionHeaderHeight: CGFloat = 14
    static let sectionHeaderGap: CGFloat = 6
    /// 卡片与下一个分组标题之间的间距。
    static let groupSpacing: CGFloat = 12
    /// 页脚（卡片下方的小号说明）的行高与它到卡片的间距。
    static let footnoteHeight: CGFloat = 20
    static let footnoteGap: CGFloat = 6
    /// 页眉：返回按钮 + 页面标题。
    static let pageHeaderHeight: CGFloat = 28
    // MARK: - 侧栏（设置导航）

    /// 纯图标档的侧栏宽度（老形态，见 `NotchMenuSidebar`）。内容宽装不下带标签的宽档时
    /// 退回这一档——紧凑档（面板宽 ×0.88 − 卡片侧内边距 24 − 容器内边距 8）的内容宽只有 390.4pt。
    static let sidebarIconWidth: CGFloat = 32

    /// 带标签档的侧栏宽度：由「最长页面名」的实测宽推出（见 `sidebarWidth(forLabelWidth:)`）。
    ///
    /// 入参是 `Notifications`（当前最长的页面名）在 `sidebarLabelSize` 下的排版宽 68.55pt。
    /// **en 是源语言、标签也最长**（zh-Hans 最长只有 43.74pt），因此按它取上界即可；
    /// 「两种语言各自都排得下」由 `NotchMenuMetricsTests.sidebarWidthFitsEveryLocalizedLabel`
    /// 按 catalog 逐条实测——改名或加分组后那条用例会失败，提示重算这里。
    static var sidebarLabeledWidth: CGFloat {
        sidebarWidth(forLabelWidth: 68.55)
    }

    /// 由「最长标签的实测宽」推出侧栏宽度：图标前留白 + 图标 + 间距 + 标签 + 尾距，
    /// 夹在可读区间里（`sidebarLabeledWidthMin`…`sidebarLabeledWidthMax`）。
    static func sidebarWidth(forLabelWidth labelWidth: CGFloat) -> CGFloat {
        let needed =
            sidebarIconLeading + sidebarIconSize + sidebarIconLabelGap + labelWidth
            + sidebarLabelTrailing
        return min(sidebarLabeledWidthMax, max(sidebarLabeledWidthMin, needed.rounded(.up)))
    }

    /// 带标签档的宽度区间。下限让短标签（zh-Hans）下的栏不至于窄成一个图标槽；
    /// 上限防止某个语言的长标签把详情列吃掉——超上限就截断（`.lineLimit(1)`），
    /// 并让上面那条实测用例失败。
    static let sidebarLabeledWidthMin: CGFloat = 84
    static let sidebarLabeledWidthMax: CGFloat = 116

    /// 侧栏图标尺寸（两档共用）。
    static let sidebarIconSize: CGFloat = 14
    /// 侧栏行内几何（带标签档）：图标左缘留白 / 图标与标签的间距 / 标签右缘尾距。
    static let sidebarIconLeading: CGFloat = 10
    static let sidebarIconLabelGap: CGFloat = 8
    static let sidebarLabelTrailing: CGFloat = 12
    /// 侧栏标签字号。宽度是用与渲染同一把尺子（`NSFont.systemFont(ofSize:weight:.medium)`）
    /// 量的，见 `sidebarLabeledWidth`。
    static let sidebarLabelSize: CGFloat = AppTypeScale.footnote

    /// 侧栏一个条目的行高。带标签档取 30（macOS 侧栏的节奏）；图标档沿用设置行行高
    /// （`rowHeight` = 40，方形瓦片在 40 高的行里居中）。
    static func sidebarItemHeight(showsLabels: Bool) -> CGFloat {
        showsLabels ? sidebarLabeledItemHeight : rowHeight
    }
    static let sidebarLabeledItemHeight: CGFloat = 30
    /// 选中/悬停底色相对条目的内缩：带标签档是一条整行的圆角矩形，图标档是方形瓦片。
    static let sidebarThumbInset: CGFloat = 2
    /// 图标档的方形瓦片边长（= 图标栏宽）。铺满行高（40）会读成一块竖长方，而不是
    /// 一个图标瓦片（实机截图就是这个观感）。
    static let sidebarItemBox: CGFloat = sidebarIconWidth

    /// 侧栏条目之间的间距（**纵向**）。取 2pt：条目之间只有一条细缝，才连成一条轨；
    /// 栏与详情之间的横向间距是另一档（`sidebarContentSpacing`），不要混用。
    static let sidebarItemSpacing: CGFloat = 2
    /// 侧栏自身的内边距（`NotchMenuSidebar` 的 `.padding(.vertical, …)`）。
    /// 它是侧栏高度账的一项：条目表 + 这一圈才是整条栏占的高度。
    static let sidebarVerticalPadding: CGFloat = 2
    /// 面板内容容器的左右内边距（`NotchMenuView`）。
    ///
    /// 与 `sidebarContentSpacing` 成对使用：两者合计决定「侧栏到详情」的总留白，
    /// 调一个要同时看另一个，否则详情列宽度会变。
    static let panelContentPadding: CGFloat = 4

    /// 内容区宽度：面板宽预算减去**卡片侧内边距**与容器的左右内边距。
    ///
    /// 两圈都要减，顺序与 `NotchView` 的排版一致：`contentView` 先把内容层收成
    /// `notchSize.width - 2 × panelCardSideInset`（见那个 `.frame(width:)`），
    /// `NotchMenuView` 再在它内部留 `panelContentPadding`。**只减后者会高估 24pt**，
    /// 而 24pt 正好把「侧栏带不带标签」的判据推到详情列低于画廊硬下限的一侧。
    static func contentAreaWidth(inPanelWidth panelWidth: CGFloat) -> CGFloat {
        panelWidth - 2 * (panelCardSideInset + panelContentPadding)
    }

    /// 标准档（`panelWidthMax`）下的内容区宽度：读数面（统计 / 额度）不显示侧栏，
    /// 占的就是这一份宽（480 − 2×(12 + 4) = 448）。
    static var contentAreaWidth: CGFloat { contentAreaWidth(inPanelWidth: panelWidthMax) }

    /// 详情列的宽度下限：由「标记动态」页的画廊推出——每格至少要装得下一个角色
    /// （`animationGalleryMascotSize`）加列间距，否则画廊会把角色裁掉。
    static var minDetailWidth: CGFloat {
        CGFloat(animationGalleryColumns) * animationGalleryMascotSize
            + CGFloat(animationGalleryColumns - 1) * animationGalleryColumnSpacing
    }

    /// 侧栏在当前内容宽下是否带标签：判据是「带上标签之后详情列仍不低于画廊硬下限」。
    ///
    /// 标准档内容宽 448pt：113 + 12 + 304 = 429 ≤ 448 ⇒ 带标签（详情列 323pt）。
    /// 紧凑档 390.4pt（480 × 0.88 − 2×(12 + 4)）装不下 ⇒ 退回图标档（详情列 346.4pt）。
    /// 屏幕更窄（`min(screenRect.width * 0.4, panelWidthMax)` 生效）时同样退回图标档，
    /// 因此画廊的硬下限在任何档位下都守得住。
    static func sidebarShowsLabels(inContentWidth contentWidth: CGFloat) -> Bool {
        sidebarLabeledWidth + sidebarContentSpacing + minDetailWidth <= contentWidth
    }

    /// 侧栏在当前内容宽下的宽度（带标签档 / 图标档）。
    static func sidebarWidth(inContentWidth contentWidth: CGFloat) -> CGFloat {
        sidebarShowsLabels(inContentWidth: contentWidth) ? sidebarLabeledWidth : sidebarIconWidth
    }

    /// 设置详情列的宽度：内容区减去侧栏与栏间距。
    static func settingsDetailWidth(inContentWidth contentWidth: CGFloat) -> CGFloat {
        contentWidth - sidebarWidth(inContentWidth: contentWidth) - sidebarContentSpacing
    }

    /// 标准档下的设置详情列宽度。
    static var settingsDetailWidth: CGFloat {
        settingsDetailWidth(inContentWidth: contentAreaWidth)
    }

    /// 外层 VStack 的间距。
    static let rowSpacing: CGFloat = 4
    /// 容器上下内边距（8 + 8）。
    static let listPaddingHeight: CGFloat = 16
    /// 分段控件与首个分组之间的间距。
    static let contentTopGap: CGFloat = 10
    /// 关于页的标识块（图标 + 名称 + 版本）的高度。
    static let appIdentityHeight: CGFloat = 99
    /// 「监控的智能体」卡片要**渲染**多少行、可视窗口多高。
    ///
    /// 这条不变量是踩过坑的：曾经把「渲染」也按可见行数截断，于是窗口里没有可滚动的
    /// 内容，第 N+1 个之后的 Agent 在设置面板里**永远够不着**（关不掉、也看不到集成
    /// 状态）。正确形态是：渲染全部行，只有窗口高度封顶，滚动由卡内接管。
    ///
    /// `directoryEditorHeight` 是某个 Agent 行展开的目录编辑器高度：它长在窗口内部，
    /// 因此要把它加进窗口高度，否则展开的编辑器会被窗口裁掉一半。
    static func agentCardLayout(
        total: Int,
        directoryEditorHeight: CGFloat = 0
    ) -> (renderedRows: Int, windowHeight: CGFloat) {
        (
            renderedRows: total,
            windowHeight: CGFloat(min(total, visibleAgentRows)) * twoLineRowHeight
                + directoryEditorHeight
        )
    }

    /// 「监控的智能体」卡片里最多同时显示多少行：其余行在卡内滚动
    /// （与音效选择器的 `maxVisibleOptions` 同一套做法）。
    ///
    /// 取值与高度预算绑定：agent 页内容高 = 58（页内固定开销：容器内边距 + 页眉 + 间距）
    /// + 20（卡标题）+ **48（「标记动态」入口行）** + 40（动作条：全部启用/全部关闭）
    /// + 行数×48 + 20（脚注）+ 12（组间距）+ 20 + 120（工具调用保护卡）。
    /// 4 行时是 **530**（58+20+48+40+192+20+12+20+120）——与加入口行之前逐项同高：
    /// 入口行的 48 正是从可见行数里挪出来的（5 → 4，卡片仍渲染全部行、只是要滚动）。
    /// 该页最高的**单个**展开（Agent 行内的目录编辑器 106）加进去、chrome 取可达的最大
    /// 76 时是 712 —— **越过设置面的 640 上限**（其余页里只有通用页也这样），因此它在
    /// 任何 chrome 档下都会夹取、由页内滚动接管（登记在 `NotchMenuMetricsTests` 的
    /// `clampedPairs`）。**再给这一页加行、或把某个档位加宽到 4 档，都要先按
    /// `maxPanelHeight` 的加法重核**。
    static let visibleAgentRows = 4

    /// 「标记动态」页：每行铺几个角色、一格多高、画廊窗口最多几行。
    ///
    /// 与 `visibleAgentRows` 同一套做法——渲染全部 Agent，只把画廊窗口高度封顶，
    /// 超出的在画廊里滚动。列数 × 窗口行数刚好装下当前的 19 个 Agent（6 × 4；
    /// 第 19 个是内嵌 CodeBuddy CLI 的 `.workBuddy`），
    /// 因此默认一屏就能看全所有角色；新增 Agent 只会在画廊里多一行可滚动内容。
    /// 高度账（4 行）：画廊内容高 = 4×68（格高）+ 3×8（行距）+ 9（留白）= 305，
    /// `animationsSectionHeight` = 2×40 + 305 = 385，该页内容高 = 385 + 78 = 463，
    /// 加可达的最大 chrome 76 是 **539 ≤ 640**（`maxPanelHeight`），仍一屏看全、不夹取。
    static let animationGalleryColumns = 6
    /// 列间距。
    static let animationGalleryColumnSpacing: CGFloat = 8
    /// 一个格子里黑色舞台的高度与名称行的高度。
    static let animationGalleryMarkTileHeight: CGFloat = 52
    static let animationGalleryTileTextHeight: CGFloat = 16
    /// 舞台里角色的边长（角色画在这个方形舞台里）。
    static let animationGalleryMascotSize: CGFloat = 44
    static var animationGalleryTileHeight: CGFloat {
        animationGalleryMarkTileHeight + animationGalleryTileTextHeight
    }
    static let animationGalleryRowSpacing: CGFloat = 8
    static let animationGalleryMaxVisibleRows = 4

    /// 画廊窗口的内容高：行数超过窗口时只算窗口那几行（渲染全部、窗口封顶）。
    ///
    /// 网格下方还有一份 `rowVerticalPadding` 的留白，它也算内容——不算进去的话，
    /// 即使刚好装下一屏（6×4），窗口里仍有一小段空内容可滚、滚动条会为它亮起来。
    static var animationGalleryHeight: CGFloat {
        let rows = min(
            (AgentKind.allCases.count + animationGalleryColumns - 1) / animationGalleryColumns,
            animationGalleryMaxVisibleRows)
        let gaps = CGFloat(max(0, rows - 1)) * animationGalleryRowSpacing
        return CGFloat(rows) * animationGalleryTileHeight + gaps + rowVerticalPadding
    }

    /// 「标记动态」页的固定内容高（`fixedHeight` 块）：状态行 + 速度行 + 画廊。
    static var animationsSectionHeight: CGFloat {
        rowHeight * 2 + animationGalleryHeight
    }

    /// 额度页：账号列表不滚动就能看到的账号数。
    ///
    /// 与 `visibleAgentRows` 同一套做法——渲染全部账号，只把卡片窗口高度封顶，超出的在
    /// 卡内滚动；行数是**运行时**才知道的（用户增删账号），因此这里只登记上限，真实增量
    /// 由 `NewAPIAccountPageState.runtimeHeight` 算出来。
    ///
    /// 取值与高度预算绑定：额度页静态内容 218（页内固定 58 + 账号卡的头/动作条 20+40 +
    /// 组间距 12 + 详情卡的头/**一行**/脚注 20+48+20）、该页最高的运行时增量
    /// `max(账号窗口 5 行 240 + 可选行 2 行 96, 编辑态 240)` = 336 ⇒ 最大 chrome 76 下
    /// 630 ≤ 730（读数面上限 `maxDashboardHeight`，余量 100，见 `NotchMenuMetricsTests`）。
    /// 取 6 会变成 678：仍然装得下，
    /// 但窗口再高就没有意义了（一次看 5 个账号已经超出常见用法）。
    static let visibleAccountRows = 5

    /// 详情卡里的**静态基准行数**：只有「凭据」一行——它是配置摘要与编辑入口，任何账号都画。
    ///
    /// 身份行与密钥额度行是**可选的运行时行**：拿不到数据的就不展示（平台只给 `sk-` 时没有
    /// 账号数据、只给访问令牌时没有密钥额度），行数因此随选中账号的读数变化，由
    /// `NewAPIAccountPageState.optionalDetailRowCount` 交出去（见那里的注释）。
    static let quotaDetailRows = 1

    /// 详情卡里可选行的上限（身份 / 密钥额度）。
    static let quotaDetailOptionalRowsMax = 2

    /// 详情卡的静态基准高度：编辑凭据时它被凭据表单替换，两者之差就是编辑态的一部分增量。
    static var quotaDetailHeight: CGFloat { CGFloat(quotaDetailRows) * twoLineRowHeight }

    /// 凭据表单的高度：行数取字段表本身（`NewAPIAccountField.allCases.count`），
    /// 加一个字段就自动长高——版面漂移由 `UsageStatsLayoutTests` 的真实排版用例兜住。
    static var credentialFormHeight: CGFloat {
        CGFloat(NewAPIAccountField.allCases.count) * twoLineRowHeight
    }

    /// 设置面的面板高度上限：**静态内容**超出时由页内滚动接管，面板不再继续变长。
    ///
    /// 上限取 **640**：它原先是 728，观感上就是面板一路往上长、把菜单栏下面的大半屏吃掉。
    /// **这是有意的取舍**：智能体页因此会开始滚动，换来的是面板不再随内容胀大。
    ///
    /// 这条上限**只约束静态内容**。就地展开的选择器是瞬时交互，它的增量加在夹取**之后**、
    /// 只受窗口高度约束（`maxDashboardHeight` = 730）：展开时整份选项必须可见，否则最后一个
    /// 档位会落到隐藏滚动条的视口之外——用户只看到箭头翻转（这正是它一度改成浮层的起因，
    /// 那版的手感被判为「难用」，已按用户要求改回就地展开，见 `SettingsPickerRow`）。
    ///
    /// 逐页的「静态内容 + 该页最高单个展开」：通用 480 + 138、行为 486 + 138、通知 298 + 202、
    /// 智能体 530 + 106、关于 391 + 0、快捷键 590 + 0、标记动态 387 + 0。chrome 可达 36…76。
    /// 静态内容只有**快捷键页**在 chrome 76 时触顶（590 + 76 = 666 > 640）；加上展开后最高的
    /// 组合是智能体页（530 + 106 + 76 = 712）与行为页（486 + 138 + 76 = 700），都在窗口上限
    /// 730 以内——**任何一个选择器展开后整份选项都看得见**。被夹取的组合登记在
    /// `NotchMenuMetricsTests.clampedPairs`。展开块是**互斥**的（见 `PickerExpansion`），
    /// 因此按「该页最高的单个展开」核对即可。**读数面不套这个上限**，见 `maxDashboardHeight`。
    static let maxPanelHeight: CGFloat = 640

    /// 读数面（统计 / 额度）的高度上限。它们不是设置导航里的一页（见
    /// `NotchMenuSection.isDashboard`），整块内容要一次看全，因此**不套** `maxPanelHeight`：
    /// 套上之后统计页在**每一个** chrome 档都会被切掉一截（内容 635 + 开销 ≥ 671 > 640），
    /// 而它底部正是新加的那行口径脚注——用户在隐藏滚动条的视口里根本看不到「下面还有」。
    ///
    /// 上限只由宿主窗口给出：`NotchWindowController` 的窗口高 750pt，减去与
    /// `scaledPanelHeight` 同源的 20pt 余量（`NotchView` 还要在面板下方留 12pt）。
    /// 实测：统计页在可达的最大开销 76 下是 711pt，仍在其内；额度页最坏组合 630pt。
    static let maxDashboardHeight: CGFloat = 730

    // MARK: - 推导

    /// 展开的选择器需要多出来的高度。
    static func pickerOptionsHeight(visibleOptions: Int) -> CGFloat {
        CGFloat(visibleOptions) * optionRowHeight + optionListPadding
    }

    /// 该分组的面板高度上限（**只约束静态内容**）：设置面 640、读数面 730。
    /// 展开的选择器增量加在它之外，见 `panelHeight`。
    static func heightCap(for section: NotchMenuSection) -> CGFloat {
        NotchMenuSection.isDashboard(section) ? maxDashboardHeight : maxPanelHeight
    }

    /// 面板总高度：静态内容（受本面上限约束）+ 该分组里展开的选择器增量（受窗口高度约束）。
    ///
    /// 展开增量加在夹取**之后**：静态内容再长也不会把面板顶过 640，而用户正在选值时
    /// 整份选项必须可见——把增量一起夹到 640 就会把最后一个档位切到隐藏滚动条的视口外。
    static func panelHeight(
        for section: NotchMenuSection,
        expandedPickerHeight: CGFloat,
        chromeHeight: CGFloat
    ) -> CGFloat {
        let staticHeight = min(
            chromeHeight + contentHeight(for: section), heightCap(for: section))
        return min(staticHeight + expandedPickerHeight, maxDashboardHeight)
    }

    /// 当前分组的内容高度：页眉 + 各分组（标题 + 卡片 + 页脚）+ 组间距。
    /// 分组内容按行累加；`fixedHeight` 的块（统计页）按它自己的高度算——两者不同时出现。
    ///
    /// 分组切换从横排分段控件变成竖排侧栏之后，**每页少掉 34pt 的固定开销**
    /// （`tabBarHeight` 30 + 一次 `rowSpacing`）：侧栏是横向的，垂直方向零成本。
    static func contentHeight(for section: NotchMenuSection) -> CGFloat {
        var height =
            listPaddingHeight + pageHeaderHeight + rowSpacing + contentTopGap

        let blocks = blocks(for: section)
        for (index, block) in blocks.enumerated() {
            if block.hasHeader {
                height += sectionHeaderHeight + sectionHeaderGap
            }
            height += block.fixedHeight ?? block.rows.reduce(0, +)
            if block.hasFootnote {
                height += footnoteHeight
            }
            if index < blocks.count - 1 {
                height += groupSpacing
            }
        }

        return height
    }

    // MARK: - 分组表

    /// 快捷键页「面板内」那一组的行数：**从动作枚举推出来**，不写死数字。
    ///
    /// 设置页的行也是同一个筛选（`ShortcutsSettingsPage.panelActions`），新加一个面板内动作
    /// 时两边一起长；写死的话新动作会落到解析式之外——页面上被裁掉最后一行（面板按行表
    /// 撑高，行表少了就画不下）。
    static var shortcutPanelRowCount: Int {
        ShortcutAction.allCases.filter { $0.scope == .panel }.count
    }

    /// 一个分组在版面里的描述：有没有分组标题、卡内各行的行高、有没有页脚。
    /// 页面按同样的顺序摆分组，高度因此可以直接相加。
    struct Block {
        /// 是否画分组标题（无标题时不占标题行的高度）。
        var hasHeader: Bool = true
        /// 卡片内从上到下的行高。
        var rows: [CGFloat] = []
        /// 固定高的整块内容（统计页这类整页）：给值时按它算高度，不再按行累加。
        var fixedHeight: CGFloat?
        /// 卡片下方是否有脚注。
        var hasFootnote: Bool = false
    }

    /// 各分组从上到下的版面表。
    static func blocks(for section: NotchMenuSection) -> [Block] {
        switch section {
        case .general:
            return [
                // 界面：语言 / 屏幕 / 胶囊高度 / 胶囊宽度 / 内容字号 / 面板尺寸
                Block(rows: [rowHeight, rowHeight, rowHeight, rowHeight, rowHeight, rowHeight]),
                // 系统：登录时启动（开关行，带副标题）/ 辅助功能 / 接管键盘焦点（单行开关）
                Block(rows: [twoLineRowHeight, rowHeight, toggleRowHeight]),
            ]
        case .behavior:
            return [
                // 胶囊：悬停展开 / 空闲可见性 / 关闭态占位（完成提示已移到通知页）
                Block(rows: Array(repeating: rowHeight, count: 3)),
                // 会话：保留已结束 / 信息密度 / 单击动作 / 刷新 / 子代理详情 / 隐藏闲置
                Block(rows: [
                    rowHeight, rowHeight, rowHeight, rowHeight, twoLineRowHeight, twoLineRowHeight,
                ]),
            ]
        case .notifications:
            return [
                // 通知：音效（点选即试听）/ 音量 / 安静时段 / 提示音范围 / 完成提示
                // + 一行脚注（说明用户音效放在 ~/Library/Sounds）
                Block(rows: Array(repeating: rowHeight, count: 5), hasFootnote: true)
            ]
        case .agents:
            return [
                // 监控的智能体：**入口行**（标记动态：轮播角色缩略图 + 标题 + 副标题）
                // + 动作条（全部启用并安装 / 全部关闭并卸载）+ 每个 Agent 一行
                // （标题 + 集成状态；行内可展开该 Agent 的目录编辑器）+ 一行脚注。
                // 受支持的 Agent 会随接入面扩大而增加（现在 19 个），整张卡片按
                // `visibleAgentRows` 封顶、超出的在卡内滚动——否则这一页会把面板
                // 撑到上限之外，用户得滚很久才能摸到下面的保护档位。
                Block(
                    rows: [twoLineRowHeight, rowHeight]
                        + Array(
                            repeating: twoLineRowHeight,
                            count: min(AgentKind.allCases.count, visibleAgentRows)
                        ),
                    hasFootnote: true
                ),
                // 工具调用保护：问什么 / 应用未运行时 / 有待处理请求时自动展开（三个全局档位）
                Block(rows: Array(repeating: rowHeight, count: 3)),
            ]
        case .animations:
            // 标记动态页是整块预览（状态选择行 + 画廊），不按设置行算——它不是配置项。
            // 高度由 `animationsSectionHeight` 给出（与页面实际排版一致）：画廊按网格铺开、
            // 窗口封顶，新增 Agent 只会在画廊里多一行可滚动内容，不改变面板高度。
            return [
                Block(hasHeader: false, fixedHeight: animationsSectionHeight, hasFootnote: true)
            ]
        case .shortcuts:
            return [
                // 全局：唤出/收起 + 脚注槽（注册失败的提示）
                Block(rows: [rowHeight], hasFootnote: true),
                // 面板内：每条动作一行（行数由 `shortcutPanelRowCount` 从动作枚举推出）+
                // 脚注槽（输入框规则 / 录制被拒的原因）
                Block(
                    rows: Array(repeating: rowHeight, count: shortcutPanelRowCount),
                    hasFootnote: true
                ),
            ]
        case .statistics:
            // 统计页是整页读数：高度由 UsageStatsMetrics.sectionHeight 给出（与页面实际
            // 排版一致），不按设置行算——它没有行，面板高度也不随数据多少变化。
            return [Block(hasHeader: false, fixedHeight: UsageStatsMetrics.sectionHeight)]
        case .quota:
            return [
                // 账号：动作条（添加账号 / 编辑凭据）+ 每账号一行读数。账号**个数**不进
                // 静态版面表——行数 = min(账号数, `visibleAccountRows`)，由
                // `NewAPIAccountPageState` 作为运行时增量交出去；超出的账号在卡内滚动
                // （渲染全部、只封顶窗口高度，与智能体卡同一条不变量）。
                Block(rows: [rowHeight]),
                // 详情（选中账号）：静态只有「凭据」一行 + 脚注；身份行与密钥额度行是
                // **可选**的运行时行（拿不到数据的就不展示，见 `quotaDetailRows` 的注释），
                // 它们的增量同样算在 `NewAPIAccountPageState.runtimeHeight` 里。
                // 「编辑凭据」态下这一行被凭据表单替换（`credentialFormHeight`）。
                Block(
                    rows: Array(repeating: twoLineRowHeight, count: quotaDetailRows),
                    hasFootnote: true
                ),
            ]
        case .about:
            return [
                // 标识块（图标 + 名称 + 版本）：不画卡片也没有标题
                Block(hasHeader: false, rows: [appIdentityHeight]),
                // 检查更新 / 自动检查更新（开关行）/ GitHub / 键盘快捷键
                Block(
                    hasHeader: false,
                    rows: [twoLineRowHeight, toggleRowHeight, rowHeight, rowHeight]),
                // 退出（破坏性操作单独一张卡片）
                Block(hasHeader: false, rows: [rowHeight]),
            ]
        }
    }
}
