//
//  NotchMenuLayout.swift
//  AgentIsland
//
//  设置面板的分组定义与版面尺寸。分组枚举同时被视图（渲染页签）与
//  NotchViewModel（按当前分组撑高面板）使用，版面常量集中在这里，
//  避免视图与视图模型各写一套数值而漂移。
//

import CoreGraphics
import Foundation

/// 设置面板的分组。设置项按用途拆开，面板只按当前分组撑高，
/// 因此每个分组都保持在一屏之内，不再随设置项增加而越拉越长。
nonisolated enum NotchMenuSection: String, CaseIterable, Identifiable, Sendable {
    /// 应用级偏好：语言、屏幕、通知音效、登录时启动、辅助功能。
    case general
    /// 各 Agent CLI 的监控开关、集成状态与 Claude 配置目录。
    case agents
    /// 版本与更新、GitHub、退出。
    case about

    var id: String { rawValue }

    /// 页签图标；只表达分组含义，具体设置行各自用自己的图标。
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
/// 数值与视图里的实际排版一一对应，且都经离屏渲染实测校准过（把面板撑到
/// 2000pt，量页面内容的真实底边）：设置行 36（上下各 10 内边距 + 13 号字
/// 行高）、Agent 行 48（两行状态文案）、行距 4、页签栏 39、容器上下内边距 16。
nonisolated enum NotchMenuMetrics {
    /// 普通设置行（MenuRow / MenuToggleRow / 选择器主行）的高度。
    static let rowHeight: CGFloat = 36
    /// 单个 Agent 行的高度（行内有「集成状态 + 路径」两行文案）。
    static let agentRowHeight: CGFloat = 48
    /// 行间距，与视图里的 VStack spacing 一致。
    static let rowSpacing: CGFloat = 4
    /// 页签栏高度。
    static let tabBarHeight: CGFloat = 39
    /// 容器上下内边距，等于 `rowSpacing * 4`。
    static let listPaddingHeight: CGFloat = 16
    /// 面板高度上限：分组内容超出时由页内滚动接管，面板不再继续变长。
    static let maxPanelHeight: CGFloat = 560

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

    /// 当前分组的内容高度（返回行 + 页签栏 + 设置行 + 内边距）。
    static func contentHeight(for section: NotchMenuSection) -> CGFloat {
        let rows = rows(for: section)
        let stacked = rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowSpacing
        return listPaddingHeight + stacked + rowSpacing + tabBarHeight
    }

    /// 所有 Agent 行叠起来的高度（`AgentSettingsSection` 内行间无间距）。
    static var agentSectionHeight: CGFloat {
        CGFloat(AgentKind.allCases.count) * agentRowHeight
    }

    // MARK: - Private

    /// 各分组从上到下的行高表；首项固定是返回行。
    private static func rows(for section: NotchMenuSection) -> [CGFloat] {
        switch section {
        case .general:
            return [rowHeight, rowHeight, rowHeight, rowHeight, rowHeight, rowHeight]
        case .agents:
            return [rowHeight, agentSectionHeight, rowHeight]
        case .about:
            return [rowHeight, rowHeight, rowHeight, rowHeight]
        }
    }
}
