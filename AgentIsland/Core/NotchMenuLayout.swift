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
    /// 应用级偏好：语言、屏幕、胶囊高度、通知音效、登录时启动、辅助功能。
    case general
    /// 各 Agent CLI 的监控开关、集成状态与 Claude 配置目录。
    case agents
    /// 版本与更新、GitHub、退出。
    case about

    var id: String { rawValue }

    /// 分段控件的图标；只表达分组含义，具体设置行各自用自己的图标。
    var symbolName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .agents: return "cpu"
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
    /// 上限取 728 是为了保证「展开的东西看得见」：通用页最高的单个展开是音效
    /// （6 行选项，718），再覆盖「语言 + 屏幕」这对常见组合（正好 728）。再多一起
    /// 展开就交给页内滚动——没有哪个上限能容下所有组合。
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
    static func contentHeight(for section: NotchMenuSection) -> CGFloat {
        var height =
            listPaddingHeight + pageHeaderHeight + rowSpacing + tabBarHeight + rowSpacing
            + contentTopGap

        let blocks = blocks(for: section)
        for (index, block) in blocks.enumerated() {
            if block.hasHeader {
                height += sectionHeaderHeight + sectionHeaderGap
            }
            height += block.rows.reduce(0, +)
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
        var rows: [CGFloat]
        /// 卡片下方是否有脚注。
        var hasFootnote: Bool = false
    }

    /// 各分组从上到下的版面表。
    static func blocks(for section: NotchMenuSection) -> [Block] {
        switch section {
        case .general:
            return [
                // 界面：语言 / 屏幕 / 胶囊高度 / 胶囊宽度 / 内容字号 / 通知音效
                Block(rows: [rowHeight, rowHeight, rowHeight, rowHeight, rowHeight, rowHeight]),
                // 系统：登录时启动（开关行，带副标题）/ 辅助功能
                Block(rows: [twoLineRowHeight, rowHeight]),
            ]
        case .agents:
            return [
                // 监控的智能体：每个 Agent 一行（标题 + 集成状态），带一行脚注
                Block(
                    rows: Array(repeating: twoLineRowHeight, count: AgentKind.allCases.count),
                    hasFootnote: true
                ),
                // Claude Code：配置目录
                Block(rows: [rowHeight]),
            ]
        case .about:
            return [
                // 标识块（图标 + 名称 + 版本）：不画卡片也没有标题
                Block(hasHeader: false, rows: [appIdentityHeight]),
                // 检查更新 / GitHub
                Block(hasHeader: false, rows: [twoLineRowHeight, rowHeight]),
                // 退出（破坏性操作单独一张卡片）
                Block(hasHeader: false, rows: [rowHeight]),
            ]
        }
    }
}
