//
//  AppRadius.swift
//  AgentIsland
//
//  全应用的圆角档位。
//
//  放在 Core 而不是 UI：`NotchMenuLayout` / `UsageStatsLayout` 这些版面常量要用它算
//  面板高度与内边距，而 Core 不该反过来依赖 UI 层（原先它挂在 `UI/Components/AppTheme.swift`
//  里，Core → UI 的反向引用就是这么来的）。颜色仍然留在 UI（`AppPalette`）。
//

import CoreGraphics

// MARK: - 圆角

/// 全应用的圆角档位。数值取自代码里实际在用的档位，按「控件 → 行 → 卡片 → 浮层
/// → 气泡」递增；不要为单点需求另起数值，选最接近的一档即可。
nonisolated enum AppRadius {
    /// 小控件：图标块、返回按钮、终端输出块、内联徽标底。与
    /// `NotchMenuMetrics.badgeRadius` 同值。
    static let control: CGFloat = 6
    /// 行：列表行、消息头、行内缩略图块的圆角。
    static let row: CGFloat = 8
    /// 卡片：设置卡片等分组容器。与 `NotchMenuMetrics.cardRadius` 同值。
    static let card: CGFloat = 10
    /// 浮层：对话气泡底座、实例卡片这类大块容器。
    static let panel: CGFloat = 12
    /// 气泡：用户消息气泡。
    static let bubble: CGFloat = 18
}

extension AppRadius {
    /// 面板卡片自身的圆角（关闭态胶囊 / 展开态面板）。**与 `AppRadius.card` 不是同一档**：
    /// 这两档描述的是「贴着屏幕顶边、要在顶边融进刘海或菜单栏」的那一块，形状由
    /// `NotchShape` 在两个状态之间插值，因此单独成档。
    static let panelClosedTop: CGFloat = 6
    static let panelClosedBottom: CGFloat = 14
    static let panelOpenedTop: CGFloat = 19
    static let panelOpenedBottom: CGFloat = 24
}
