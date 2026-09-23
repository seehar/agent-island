//
//  NotchMenuTabBar.swift
//  AgentIsland
//
//  设置面板的分组切换：macOS 的分段控件（segmented control）——一条轨道里放三段，
//  选中的那一段由滑块表示，滑块在段之间滑过去而不是两段各自亮一下。
//

import Combine
import SwiftUI

struct NotchMenuTabBar: View {
    @Binding var selection: NotchMenuSection
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var hoveredSection: NotchMenuSection?
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchMenuSection.tabSections) { section in
                segment(for: section)
            }
        }
        .padding(2)
        .frame(height: NotchMenuMetrics.tabBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppPalette.segmentedTrack)
        )
    }

    // MARK: - 段

    /// 一段：图标 + 名称。选中段的滑块用 `matchedGeometryEffect` 在段之间移动，
    /// 因此切换分组时看到的是滑块滑过去，而不是新段突然变亮。
    private func segment(for section: NotchMenuSection) -> some View {
        let isSelected = section == selection

        return Button {
            withAnimation(SettingsMotion.segment) {
                selection = section
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 10, weight: .semibold))

                // 缩字而不是截断。字宽实测（`NSAttributedString`，11pt medium）：五段时
                // 每段 90pt（面板 480 − 左右内边距 16 − 轨道内边距 4 − 段间距 8 后除以 5），
                // 最宽的 Statistics 连图标约 66pt；「面板尺寸」档 compact（0.88 → 面板 422）
                // 时每段只剩约 79pt，仍够。
                // 因此**第 6 段放不下**：五段变六段会把每段压到 75pt / 紧凑档 65pt，
                // 低于最宽标签的 66pt（除非改成只画图标或标签取更短的单字）。
                Text(section.title(l10n))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundColor(foregroundColor(for: section))
            .frame(maxWidth: .infinity)
            .frame(height: NotchMenuMetrics.tabBarHeight - 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppPalette.segmentedThumb)
                        .matchedGeometryEffect(id: "segment-thumb", in: thumb)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovering in
            if isHovering {
                hoveredSection = section
            } else if hoveredSection == section {
                hoveredSection = nil
            }
        }
        .accessibilityLabel(Text(section.title(l10n)))
    }

    // MARK: - 表现

    private func foregroundColor(for section: NotchMenuSection) -> Color {
        if section == selection { return AppPalette.primaryText }
        if hoveredSection == section { return Color.white.opacity(0.75) }
        return AppPalette.secondaryText
    }
}

// MARK: - 分组标题

extension NotchMenuSection {
    /// 分组标题：分段条与设置面板的页眉共用同一份映射（页眉要说清「现在在哪一页」）。
    /// 在视图里解析而不是放进 `NotchMenuSection`：key 保持字面量，本地化守卫才能审计到；
    /// 同时在观察 `LocalizationManager` 的视图内解析，切换语言才会重新渲染。
    func title(_ l10n: LocalizationManager) -> String {
        switch self {
        case .general: return l10n.t("General")
        case .behavior: return l10n.t("Behavior")
        case .notifications: return l10n.t("Notifications")
        case .agents: return l10n.t("Agents")
        case .statistics: return l10n.t("Statistics")
        case .about: return l10n.t("About")
        }
    }
}
