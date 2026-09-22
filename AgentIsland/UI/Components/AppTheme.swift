//
//  AppTheme.swift
//  AgentIsland
//
//  全应用共用的语义 token：颜色（AppPalette）、圆角（AppRadius）。设置面板、刘海
//  菜单、对话与工具结果视图都从这里取值，因此同一个语义在各处是同一个数、同一个
//  颜色。取法 macOS 的语义色惯例：黑底上用叠白代替阴影，文字层级用白色透明度而
//  非不同灰度；颜色只表达状态与层级，不用来表达「被选中」。
//

import SwiftUI

// MARK: - 调色

/// 全应用的语义色。
///
/// 强调色跟随系统「强调色」偏好——这是 macOS 控件的惯例：用户换了强调色，开关、
/// 选中勾与分段滑块跟着换。**成功/警告/危险只表达状态，不参与选中态**：一个颜色
/// 不能同时表示「被选中」和「状态正常」两件事，选中一律用 `accent`。
enum AppPalette {
    /// 控件强调色：开关、选中勾、分段滑块、行内按钮。**唯一的选中态颜色**；
    /// 不要在状态表达（成功/警告/危险）里用它，也不要用它画装饰。
    static let accent = Color.accentColor
    /// 成功 / 健康：集成已安装、已启用、更新已是最新。只表状态，不当选中色，
    /// 也不要用作通用「绿色强调」。
    static let success = Color(red: 0.40, green: 0.78, blue: 0.47)
    /// 警告：集成不可用、需要授权。只表「可恢复的异常」，不用于错误文案，
    /// 也不当选中色。
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)
    /// 危险：退出、错误文案、不可用状态。只表「出错或破坏性操作」，不要拿它做
    /// 普通强调，也不当选中色。
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// 主要文字：行标题、正文、分段控件里选中的标签。不要用它写副标题或说明，
    /// 那两级另有取值，否则层级会塌成一片。
    static let primaryText = Color.white.opacity(0.92)
    /// 次要文字：当前取值、状态副标题。比正文弱一档但仍可读；不要用它写正文，
    /// 也不要用它当禁用色。
    static let secondaryText = Color.white.opacity(0.55)
    /// 三级文字：路径、分组标题、脚注。仅用于「补充信息」，正文与取值不要降到
    /// 这一级。
    static let tertiaryText = Color.white.opacity(0.38)
    /// 四级文字：时间戳、行列号、终端类输出（对话列表与工具结果里原先散落的
    /// `white.opacity(0.3)`）。比三级更弱，只适合「可看可不看」的辅助信息，
    /// 任何需要读懂的文案都不要用。
    static let subtleText = Color.white.opacity(0.30)

    /// 卡片底色与描边（黑底上给卡片一条亮边，取代阴影）。用于「有边框的分组
    /// 容器」；铺满整块的浮层请用 `panelFill`，两者的叠白力度不同。
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.06)
    /// 浮层底色：面板、对话气泡底座这类大面积容器（原先散落在各处的叠白 0.05）。
    /// 比卡片更暗，不要用在卡片上，否则卡片与面板会失去层次。
    static let panelFill = Color.white.opacity(0.05)
    /// 卡片内一行的悬停底色、按下时叠加的底色。只在行有悬停/按压反馈时用，
    /// 不要拿它当静态底色。
    static let rowHover = Color.white.opacity(0.06)
    static let rowPressed = Color.white.opacity(0.12)
    /// 卡片内行之间的发丝分隔线。只画线，不要当边框或底色用。
    static let separator = Color.white.opacity(0.08)
    /// 分段控件的轨道与滑块。两者成对出现，不要单独拿去当行底色。
    static let segmentedTrack = Color.white.opacity(0.09)
    static let segmentedThumb = Color.white.opacity(0.16)
}

// MARK: - 圆角

/// 全应用的圆角档位。数值取自代码里实际在用的档位，按「控件 → 行 → 卡片 → 浮层
/// → 气泡」递增；不要为单点需求另起数值，选最接近的一档即可。
enum AppRadius {
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

// MARK: - 统计图表的序列色

/// 统计曲线图的序列色。**不是状态色**：只在同一张图里区分维度，因此不复用
/// `success` / `warning` / `danger`（它们在别的页面表达状态），也不参与选中态
/// （选中态一律 `accent`）。五路在黑色面板上两两可辨：色相分开，亮度都落在可读区间。
enum ChartPalette {
    /// 总量（输入 + 输出 + 缓存读 + 缓存写）：最亮的一路，面积填充也画它。
    static let total = Color(red: 0.62, green: 0.80, blue: 1.00)
    static let input = Color(red: 0.44, green: 0.72, blue: 0.98)
    static let output = Color(red: 0.78, green: 0.62, blue: 0.98)
    static let cacheRead = Color(red: 0.36, green: 0.86, blue: 0.78)
    static let cacheWrite = Color(red: 1.00, green: 0.83, blue: 0.55)
}
