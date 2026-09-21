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
            ForEach(NotchMenuSection.allCases) { section in
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

                Text(title(for: section))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
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
        .accessibilityLabel(Text(title(for: section)))
    }

    // MARK: - 表现

    /// 段标题。在视图里解析而不是放进 `NotchMenuSection`：key 保持字面量，
    /// 本地化守卫才能审计到；同时在观察 `LocalizationManager` 的视图内解析，
    /// 切换语言才会重新渲染。
    private func title(for section: NotchMenuSection) -> String {
        switch section {
        case .general: return l10n.t("General")
        case .behavior: return l10n.t("Behavior")
        case .agents: return l10n.t("Agents")
        case .statistics: return l10n.t("Statistics")
        case .about: return l10n.t("About")
        }
    }

    private func foregroundColor(for section: NotchMenuSection) -> Color {
        if section == selection { return AppPalette.primaryText }
        if hoveredSection == section { return Color.white.opacity(0.75) }
        return AppPalette.secondaryText
    }
}
