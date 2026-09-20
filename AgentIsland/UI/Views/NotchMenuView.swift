//
//  NotchMenuView.swift
//  AgentIsland
//
//  设置面板容器：页眉（返回 + 标题）+ 分组切换 + 当前分组的内容。
//  面板高度由 NotchMenuMetrics 按当前分组算出（见 NotchViewModel.openedSize），
//  内容超出时在页内滚动，而不是把面板越撑越长。
//

import Combine
import SwiftUI

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var soundSelector = SoundSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isBackHovered = false

    var body: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            pageHeader

            NotchMenuTabBar(selection: $viewModel.menuSection)

            // 当前分组的内容：放不下时在这里滚动
            ScrollView(.vertical, showsIndicators: false) {
                page
                    .padding(.top, NotchMenuMetrics.contentTopGap)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            screenSelector.refreshScreens()
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .menu {
                screenSelector.refreshScreens()
            }
        }
    }

    // MARK: - 页眉

    /// 页眉：返回会话列表的箭头 + 页面标题。面板右上角的关闭按钮也在做同一件事，
    /// 但设置页自己需要一条导航式的返回与一个能说明「这是哪一页」的标题。
    private var pageHeader: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.toggleMenu()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppPalette.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isBackHovered ? AppPalette.rowHover : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsCompactButtonStyle())
            .onHover { isBackHovered = $0 }
            .accessibilityLabel(Text(l10n.t("Back")))

            Text(l10n.t("Settings"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppPalette.primaryText)

            Spacer()
        }
        .frame(height: NotchMenuMetrics.pageHeaderHeight)
    }

    // MARK: - Page

    /// 当前分组对应的设置页。
    @ViewBuilder
    private var page: some View {
        switch viewModel.menuSection {
        case .general:
            GeneralSettingsPage(screenSelector: screenSelector, soundSelector: soundSelector)
        case .agents:
            AgentsSettingsPage()
        case .about:
            AboutSettingsPage(updateManager: updateManager)
        }
    }
}
