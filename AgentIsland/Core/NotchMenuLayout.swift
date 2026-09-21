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
    /// 登录时启动、辅助功能。
    case general
    /// 行为类偏好：悬停展开、空闲可见性、完成提示、会话保留与刷新频率、
    /// 通知（音效与提示音覆盖范围）。
    case behavior
    /// 各 Agent CLI 的监控开关与集成状态、三个全局的审批闸门档位、Claude 配置目录。
    case agents
    /// 用量统计：token、会话与工具调用的汇总读数（只读页，不是配置）。
    case statistics
    /// 版本与更新、GitHub、退出。
    case about

    var id: String { rawValue }

    /// 分段控件的图标；只表达分组含义，具体设置行各自用自己的图标。
    var symbolName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .behavior: return "switch.2"
        case .agents: return "cpu"
        case .statistics: return "chart.bar.xaxis"
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

    // MARK: - 行的几何

    /// 行左侧图标块的边长与圆角。
    static let badgeSize: CGFloat = 22
    static let badgeRadius: CGFloat = 6
    /// 图标块与标题之间的间距。
    static let badgeGap: CGFloat = 10
    /// 行的左右内边距。
    static let rowHorizontalPadding: CGFloat = 12
    /// 行的上下内边距：单行行高 = 图标块 22 + 9×2 = 40。
    static let rowVerticalPadding: CGFloat = 9
    /// 标题与副标题之间的间距。
    static let titleSpacing: CGFloat = 1
    /// 卡片圆角。
    static let cardRadius: CGFloat = 10
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
    /// 展开的选择器选项行（含微调行）。
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
    /// 分段控件（分组切换）的高度。
    static let tabBarHeight: CGFloat = 30
    /// 外层 VStack 的间距。
    static let rowSpacing: CGFloat = 4
    /// 容器上下内边距（8 + 8）。
    static let listPaddingHeight: CGFloat = 16
    /// 分段控件与首个分组之间的间距。
    static let contentTopGap: CGFloat = 10
    /// 关于页的标识块（图标 + 名称 + 版本）的高度。
    static let appIdentityHeight: CGFloat = 99
    /// 面板高度上限：分组内容超出时由页内滚动接管，面板不再继续变长。
    ///
    /// 判据可核算：**每页都要满足「内容高 + 该页最高的单个展开 + chrome ≤ 728」**。
    /// chrome = `max(24, 胶囊高度) + 12`，可达区间是 **28…76**：外接屏自动档
    /// （菜单栏 24/25）→ 36/37；内置刘海 32 → 44；`notch` 档在没有内置刘海的屏上 38 → 50；
    /// 胶囊高度自定义 16…64 → 28…76。因此「装得下」是按页给阈值的——允许的最大 chrome
    /// （= 728 − 内容高 − 该页最高单个展开）：通用 118、行为 **54**、智能体 **74**、
    /// 统计 76、关于 343。
    /// 已知会被夹取的组合：胶囊高度自定义 ≥ 43（chrome ≥ 55）时的行为页
    /// （674 + 76 = 750）与自定义 ≥ 63（chrome ≥ 75）时的智能体页（654 + 76 = 730），
    /// 由页内滚动接管（滚动条是隐藏的）。
    /// 行为页的最高展开由音效选择器的 `SoundSelector.maxVisibleOptions`（4）与 4 档枚举
    /// 共同决定：把任一项改大，最后一个档位就落到可视区外。
    /// 改任何一页的行数、档位数或某个选择器的可见选项数，都要重核这些阈值——
    /// `NotchMenuMetricsTests` 有一条表驱动的用例钉着它（chrome 取可达集合）。
    /// 再多一起展开同样交给页内滚动——没有哪个上限能容下所有组合。
    static let maxPanelHeight: CGFloat = 728

    // MARK: - 推导

    /// 展开的选择器需要多出来的高度。
    static func pickerOptionsHeight(visibleOptions: Int) -> CGFloat {
        CGFloat(visibleOptions) * optionRowHeight + optionListPadding
    }

    /// 面板总高度：菜单之外的固定开销 + 当前分组内容 + 该分组里展开的选择器增量。
    ///
    /// - Parameters:
    ///   - section: 当前分组。
    ///   - expandedPickerHeight: 当前分组里展开的选择器增量。
    ///   - chromeHeight: 菜单之外的固定开销（头部行 + 面板底部内边距），由调用方给出。
    static func panelHeight(
        for section: NotchMenuSection,
        expandedPickerHeight: CGFloat,
        chromeHeight: CGFloat
    ) -> CGFloat {
        min(chromeHeight + contentHeight(for: section) + expandedPickerHeight, maxPanelHeight)
    }

    /// 当前分组的内容高度：页眉 + 分段控件 + 各分组（标题 + 卡片 + 页脚）+ 组间距。
    /// 分组内容按行累加；`fixedHeight` 的块（统计页）按它自己的高度算——两者不同时出现。
    static func contentHeight(for section: NotchMenuSection) -> CGFloat {
        var height =
            listPaddingHeight + pageHeaderHeight + rowSpacing + tabBarHeight + rowSpacing
            + contentTopGap

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
                // 系统：登录时启动（开关行，带副标题）/ 辅助功能
                Block(rows: [twoLineRowHeight, rowHeight]),
            ]
        case .behavior:
            return [
                // 胶囊：悬停展开 / 空闲可见性 / 完成提示
                Block(rows: Array(repeating: rowHeight, count: 3)),
                // 会话：保留已结束的会话 / 列表信息密度 / 单击动作 / 刷新频率
                Block(rows: Array(repeating: rowHeight, count: 4)),
                // 通知：音效 / 提示音覆盖哪些事件
                Block(rows: Array(repeating: rowHeight, count: 2)),
            ]
        case .agents:
            return [
                // 监控的智能体：每个 Agent 一行（标题 + 集成状态），带一行脚注
                Block(
                    rows: Array(repeating: twoLineRowHeight, count: AgentKind.allCases.count),
                    hasFootnote: true
                ),
                // 审批闸门：问什么 / 应用未运行时 / 待批时自动展开（三个全局档位）
                Block(rows: Array(repeating: rowHeight, count: 3)),
                // Claude Code：配置目录
                Block(rows: [rowHeight]),
            ]
        case .statistics:
            // 统计页是整页读数：高度由 UsageStatsMetrics.sectionHeight 给出（与页面实际
            // 排版一致），不按设置行算——它没有行，面板高度也不随数据多少变化。
            return [Block(hasHeader: false, fixedHeight: UsageStatsMetrics.sectionHeight)]
        case .about:
            return [
                // 标识块（图标 + 名称 + 版本）：不画卡片也没有标题
                Block(hasHeader: false, rows: [appIdentityHeight]),
                // 检查更新 / 自动检查更新（开关行）/ GitHub
                Block(hasHeader: false, rows: [twoLineRowHeight, toggleRowHeight, rowHeight]),
                // 退出（破坏性操作单独一张卡片）
                Block(hasHeader: false, rows: [rowHeight]),
            ]
        }
    }
}
