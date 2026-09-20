//
//  SettingsKit.swift
//  AgentIsland
//
//  设置面板的视觉语言与可复用骨架：分组卡片、卡片内的发丝分隔线、每行左侧的
//  彩色图标块、单一强调色的控件。取法 macOS「系统设置」的排版语言，并按黑色
//  刘海面板重新取值——黑底上用叠白代替阴影，文字层级用白色透明度而非不同灰度。
//  行的几何（图标块 22、上下内边距 9、左右 12）与 NotchMenuMetrics 共用同一组
//  常量，面板高度因此仍可由常量解析地推出。
//

import SwiftUI

// MARK: - 调色

/// 设置面板的语义色。
///
/// 强调色跟随系统「强调色」偏好——这是 macOS 控件的惯例：用户换了强调色，开关、
/// 选中勾与分段滑块跟着换。成功/警告/危险只表达状态，不参与选中态，避免一个颜色
/// 同时表示「被选中」和「状态正常」两件事。
enum SettingsPalette {
    /// 控件强调色：开关、选中勾、分段滑块、行内按钮。
    static let accent = Color.accentColor
    /// 成功 / 健康：集成已安装、已启用。
    static let success = Color(red: 0.40, green: 0.78, blue: 0.47)
    /// 警告：集成不可用、需要授权。
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)
    /// 危险：退出、错误文案。
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// 主要文字：行标题、分段控件里选中的标签。
    static let primaryText = Color.white.opacity(0.92)
    /// 次要文字：当前取值、状态副标题。
    static let secondaryText = Color.white.opacity(0.55)
    /// 三级文字：路径、分组标题、脚注。
    static let tertiaryText = Color.white.opacity(0.38)

    /// 卡片底色与描边（黑底上给卡片一条亮边，取代阴影）。
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.06)
    /// 卡片内一行的悬停底色、按下时叠加的底色。
    static let rowHover = Color.white.opacity(0.06)
    static let rowPressed = Color.white.opacity(0.12)
    /// 卡片内行之间的发丝分隔线。
    static let separator = Color.white.opacity(0.08)
    /// 分段控件的轨道与滑块。
    static let segmentedTrack = Color.white.opacity(0.09)
    static let segmentedThumb = Color.white.opacity(0.16)
}

// MARK: - 动效

/// 设置面板的动效。展开与切换都用临界阻尼的短弹簧：跟手、不晃；设置面板里没有
/// 「甩出去」的手势，因此不需要回弹。
enum SettingsMotion {
    static let expand = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let segment = Animation.spring(response: 0.28, dampingFraction: 0.9)
}

// MARK: - 卡片与分组

/// 设置卡片：把一组行包成一张圆角卡片。行之间的分隔线由行自己画（用 overlay，
/// 不占行高），卡片只负责底色、描边与圆角。
struct SettingsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            SettingsPalette.cardFill,
            in: RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
                .strokeBorder(SettingsPalette.cardStroke, lineWidth: 0.5)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
        )
    }
}

/// 分组标题：卡片上方的小号次级标题，与卡片内标题列左对齐。
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(SettingsPalette.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
    }
}

/// 一个设置分组：可选的小号标题 + 一张卡片 + 可选的脚注。
/// 页面的分组顺序与 `NotchMenuMetrics.blocks(for:)` 的版面表一一对应。
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let footnote: String?
    private let content: Content

    init(title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SettingsSectionHeader(title: title)
                    .padding(.bottom, NotchMenuMetrics.sectionHeaderGap)
            }

            SettingsCard { content }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundColor(SettingsPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
                    .padding(.top, NotchMenuMetrics.footnoteGap)
            }
        }
    }
}

// MARK: - 行内构件

/// 行左侧的图标块：SF Symbol 配一个色调，或者某个 Agent 的品牌标记。
/// 两种来源共用同一套几何，卡片里因此有一列对齐的彩色方块。
struct SettingsBadge: View {
    /// 图标来源。
    enum Source {
        /// SF Symbol + 色调。
        case symbol(name: String, tint: Color)
        /// Agent 品牌标记（底色取该 Agent 的品牌色）。
        case agent(AgentKind)
    }

    let source: Source

    /// 图标与底色的色调。
    private var tint: Color {
        switch source {
        case .symbol(_, let tint): return tint
        case .agent(let kind): return kind.brandColor
        }
    }

    var body: some View {
        glyph
            .frame(width: NotchMenuMetrics.badgeSize, height: NotchMenuMetrics.badgeSize)
            .background(
                RoundedRectangle(cornerRadius: NotchMenuMetrics.badgeRadius, style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch source {
        case .symbol(let name, _):
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
        case .agent(let kind):
            AgentLogo(agent: kind, size: 12)
        }
    }
}

/// 行内排版：图标块 + 标题（与可选副标题）+ 尾部控件。
/// 行高 = max(图标块 22, 文案块) + 上下内边距各 9。
struct SettingsRowLabel<Trailing: View>: View {
    private let badge: SettingsBadge
    private let title: String
    private let subtitle: String?
    private let titleColor: Color
    private let subtitleColor: Color
    private let trailing: Trailing

    init(
        badge: SettingsBadge,
        title: String,
        subtitle: String? = nil,
        titleColor: Color = SettingsPalette.primaryText,
        subtitleColor: Color = SettingsPalette.secondaryText,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.subtitleColor = subtitleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: NotchMenuMetrics.badgeGap) {
            badge

            VStack(alignment: .leading, spacing: NotchMenuMetrics.titleSpacing) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(titleColor)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(subtitleColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
        .padding(.vertical, NotchMenuMetrics.rowVerticalPadding)
    }
}

/// 行右侧的「当前取值 + 展开箭头」。
struct SettingsDisclosureValue: View {
    let value: String
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(SettingsPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(SettingsPalette.tertiaryText)
        }
    }
}

/// 行右侧的状态：可选的圆点 + 一行说明文字。圆点只用于「正常/异常」这类状态，
/// 选中态一律用强调色的勾，两者不混用。
struct SettingsStatusValue: View {
    let text: String
    var color: Color = SettingsPalette.secondaryText
    var dotColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }

            Text(text)
                .font(.system(size: 11))
                .foregroundColor(color)
                .lineLimit(1)
        }
    }
}

// MARK: - 行

/// 可点的一行：图标块 + 标题 + 右侧控件，整行可点。
struct SettingsButtonRow<Trailing: View>: View {
    private let badge: SettingsBadge
    private let title: String
    private let subtitle: String?
    private let titleColor: Color
    private let subtitleColor: Color
    private let showsSeparator: Bool
    private let isDimmed: Bool
    private let trailing: Trailing
    private let action: () -> Void

    @State private var isHovered = false

    init(
        badge: SettingsBadge,
        title: String,
        subtitle: String? = nil,
        titleColor: Color = SettingsPalette.primaryText,
        subtitleColor: Color = SettingsPalette.secondaryText,
        showsSeparator: Bool = true,
        isDimmed: Bool = false,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) {
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.subtitleColor = subtitleColor
        self.showsSeparator = showsSeparator
        self.isDimmed = isDimmed
        self.trailing = trailing()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRowLabel(
                badge: badge,
                title: title,
                subtitle: subtitle,
                titleColor: titleColor,
                subtitleColor: subtitleColor
            ) {
                trailing
            }
            .background(isHovered ? SettingsPalette.rowHover : Color.clear)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .settingsRowSeparator(showsSeparator)
        .opacity(isDimmed ? 0.5 : 1)
    }
}

extension SettingsButtonRow where Trailing == EmptyView {
    /// 没有尾部控件的一行：链接、退出这类只需要「点一下」的设置项。
    init(
        badge: SettingsBadge,
        title: String,
        titleColor: Color = SettingsPalette.primaryText,
        showsSeparator: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            badge: badge,
            title: title,
            titleColor: titleColor,
            showsSeparator: showsSeparator,
            trailing: { EmptyView() },
            action: action
        )
    }
}

/// 开关行：只有开关本身响应点击——macOS 的开关行也不整行可点，免得点标题与
/// 开关自己的手势打架。
struct SettingsToggleRow: View {
    private let badge: SettingsBadge
    private let title: String
    private let subtitle: String?
    private let subtitleColor: Color
    private let isOn: Bool
    private let showsSeparator: Bool
    private let onToggle: () -> Void

    init(
        badge: SettingsBadge,
        title: String,
        subtitle: String? = nil,
        subtitleColor: Color = SettingsPalette.secondaryText,
        isOn: Bool,
        showsSeparator: Bool = true,
        onToggle: @escaping () -> Void
    ) {
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.isOn = isOn
        self.showsSeparator = showsSeparator
        self.onToggle = onToggle
    }

    var body: some View {
        SettingsRowLabel(
            badge: badge, title: title, subtitle: subtitle, subtitleColor: subtitleColor
        ) {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(SettingsPalette.accent)
                .accessibilityLabel(Text(title))
        }
        .settingsRowSeparator(showsSeparator)
    }
}

/// 可展开的设置行：主行显示当前取值，展开后把选项插在同一张卡片里，
/// 选项因此属于这一行，而不是另起一张卡片。
struct SettingsPickerRow<Options: View>: View {
    private let badge: SettingsBadge
    private let title: String
    private let value: String
    private let isExpanded: Bool
    private let showsSeparator: Bool
    private let onToggle: () -> Void
    private let options: Options

    @State private var isHovered = false

    init(
        badge: SettingsBadge,
        title: String,
        value: String,
        isExpanded: Bool,
        showsSeparator: Bool = true,
        onToggle: @escaping () -> Void,
        @ViewBuilder options: () -> Options
    ) {
        self.badge = badge
        self.title = title
        self.value = value
        self.isExpanded = isExpanded
        self.showsSeparator = showsSeparator
        self.onToggle = onToggle
        self.options = options()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                SettingsRowLabel(badge: badge, title: title) {
                    SettingsDisclosureValue(value: value, isExpanded: isExpanded)
                }
                .background(isHovered ? SettingsPalette.rowHover : Color.clear)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(spacing: 0) {
                    options
                }
                .padding(.top, NotchMenuMetrics.optionListTopPadding)
                .padding(.bottom, NotchMenuMetrics.optionListBottomPadding)
                .padding(.leading, NotchMenuMetrics.optionIndent)
            }
        }
        .settingsRowSeparator(showsSeparator)
    }
}

/// 展开的选择器里的一行选项：标签 + 可选的补充说明 + 选中勾。
/// 高度取 `NotchMenuMetrics.optionRowHeight`，面板高度因此不用猜文案的行高。
struct SettingsOptionRow: View {
    let label: String
    /// 选项的补充说明（屏幕的「内置/主屏」、高度来源的实际数值等）。
    var detail: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(
                        isSelected ? SettingsPalette.primaryText : SettingsPalette.secondaryText
                    )
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(SettingsPalette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SettingsPalette.accent)
                }
            }
            .padding(.horizontal, NotchMenuMetrics.optionHorizontalPadding)
            .frame(height: NotchMenuMetrics.optionRowHeight)
            .background(isHovered ? SettingsPalette.rowHover : Color.clear)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// 卡片内的错误提示行：不弹窗，保持与其它行同一套排版。
struct SettingsNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(SettingsPalette.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
            .padding(.bottom, 8)
    }
}

// MARK: - 反馈

/// 设置行的按压反馈：按下即叠加一层更亮的底色，不做位移——macOS 列表行的惯例。
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? SettingsPalette.rowPressed : Color.clear)
    }
}

/// 行内小按钮（返回箭头、启用按钮）的按压反馈：整体压暗，不改变尺寸。
struct SettingsCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

extension View {
    /// 在行的底边画分隔线。用 overlay 而不是插一行，行高因此保持整数，
    /// 面板高度的解析式不必为每条线再加 1。
    func settingsRowSeparator(_ isVisible: Bool) -> some View {
        overlay(alignment: .bottom) {
            if isVisible {
                Rectangle()
                    .fill(SettingsPalette.separator)
                    .frame(height: 1)
                    .padding(.leading, NotchMenuMetrics.separatorInset)
            }
        }
    }
}
