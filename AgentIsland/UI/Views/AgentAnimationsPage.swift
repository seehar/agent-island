//
//  AgentAnimationsPage.swift
//  AgentIsland
//
//  「标记动态」设置页：把各 Agent 标记的运行时动效一次铺开——顶上一行选状态
//  （空闲 / 处理中 / 待审批），下面按网格渲染每一枚标记，让用户看清谁在什么时候怎么动。
//
//  这一页**不占分段位**（分段条放不下第六段，实测见 `NotchMenuTabBar`），入口是
//  「智能体」页页眉里的那枚按钮（与快捷键页从「关于」页进入同构）。
//  高度是定值（`NotchMenuMetrics.animationsSectionHeight`）：画廊窗口封顶、超出的在
//  画廊里滚动，因此新增 Agent 不会把面板撑长。
//

import SwiftUI

struct AgentAnimationsSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 预览的活动状态：只影响这一页的渲染，不写任何偏好。
    @State private var activity: AgentLogoActivity = .working

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(
                footnote: l10n.t("Pick an activity to preview how every mark animates.")
            ) {
                AgentActivityRow(activity: $activity)
                AgentAnimationGallery(activity: activity)
            }
        }
    }
}

// MARK: - 页眉入口按钮

/// 「智能体」页页眉里的入口：进「标记动态」页。与 `ShortcutResetButton`、统计页的范围
/// 控件同一格——页眉这一行不占页面高度，因此入口不需要动高度预算。
struct AgentAnimationsHeaderButton: View {
    let action: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(l10n.t("Animations"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: UsageStatsMetrics.headerActionSize)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovered ? AppPalette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(l10n.t("Preview Agent Animations")))
    }
}

// MARK: - 状态选择行

/// 预览状态选择行：空闲 / 处理中 / 待审批。行内分段控件，不展开、不撑高面板。
private struct AgentActivityRow: View {
    @Binding var activity: AgentLogoActivity

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .symbol(name: "sparkles", tint: AppPalette.accent)),
            title: l10n.t("Activity")
        ) {
            AgentActivitySegmentedControl(selection: $activity)
        }
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(true)
    }
}

/// 三档状态的小分段控件。做法与分组切换条同源（滑块 `matchedGeometryEffect` 滑过去，
/// 而不是两段各自亮一下），只是尺寸收进一行里。
private struct AgentActivitySegmentedControl: View {
    @Binding var selection: AgentLogoActivity

    @ObservedObject private var l10n = LocalizationManager.shared
    @Namespace private var thumb

    private static let options: [AgentLogoActivity] = [.idle, .working, .alert]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppPalette.segmentedTrack)
        )
    }

    private func segment(_ option: AgentLogoActivity) -> some View {
        let isSelected = option == selection

        return Button {
            withAnimation(SettingsMotion.segment) { selection = option }
        } label: {
            Text(label(option))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(
                    isSelected ? AppPalette.primaryText : AppPalette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppPalette.segmentedThumb)
                            .matchedGeometryEffect(id: "activity-thumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .accessibilityLabel(Text(label(option)))
    }

    /// 状态文案：键保持字面量，本地化守卫才能审计到。
    private func label(_ option: AgentLogoActivity) -> String {
        switch option {
        case .idle: return l10n.t("Idle")
        case .working: return l10n.t("Working")
        case .alert: return l10n.t("Needs Approval")
        }
    }
}

// MARK: - 画廊

/// 各 Agent 标记的画廊：渲染**全部**标记（只截断窗口高度，超出的在画廊里滚动），
/// 与「监控的智能体」卡片同一条不变量——否则窗口外的 Agent 就永远看不到它的动效。
private struct AgentAnimationGallery: View {
    let activity: AgentLogoActivity

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: NotchMenuMetrics.animationGalleryColumns
    )

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: NotchMenuMetrics.animationGalleryRowSpacing) {
                ForEach(AgentKind.allCases) { kind in
                    AgentAnimationTile(kind: kind, activity: activity)
                }
            }
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
            .padding(.bottom, NotchMenuMetrics.rowVerticalPadding)
        }
        .frame(height: NotchMenuMetrics.animationGalleryHeight)
    }
}

/// 画廊里的一格：黑色舞台 + 动画中的标记，下面一行短名。
private struct AgentAnimationTile: View {
    let kind: AgentKind
    let activity: AgentLogoActivity

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)

                AgentLogo(agent: kind, size: 32, activity: activity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchMenuMetrics.animationGalleryMarkTileHeight)

            Text(kind.shortName)
                .font(.system(size: 10))
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: NotchMenuMetrics.animationGalleryTileTextHeight)
        }
        .frame(height: NotchMenuMetrics.animationGalleryTileHeight)
    }
}
