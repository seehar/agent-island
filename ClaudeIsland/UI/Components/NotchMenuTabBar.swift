//
//  NotchMenuTabBar.swift
//  ClaudeIsland
//
//  设置面板的分组切换栏：等宽的图标 + 名称页签。
//

import Combine
import SwiftUI

struct NotchMenuTabBar: View {
    @Binding var selection: NotchMenuSection
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var hoveredSection: NotchMenuSection?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NotchMenuSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = section
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: section.symbolName)
                            .font(.system(size: 12, weight: .medium))
                        Text(l10n.t(section.titleKey))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(foregroundColor(for: section))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(backgroundColor(for: section))
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        hoveredSection = section
                    } else if hoveredSection == section {
                        hoveredSection = nil
                    }
                }
                .accessibilityLabel(Text(l10n.t(section.titleKey)))
            }
        }
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: - Presentation

    private func foregroundColor(for section: NotchMenuSection) -> Color {
        if section == selection { return .white }
        return .white.opacity(hoveredSection == section ? 0.8 : 0.45)
    }

    private func backgroundColor(for section: NotchMenuSection) -> Color {
        if section == selection { return Color.white.opacity(0.12) }
        return hoveredSection == section ? Color.white.opacity(0.06) : Color.clear
    }
}
