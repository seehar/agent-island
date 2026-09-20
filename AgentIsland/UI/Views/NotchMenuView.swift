//
//  NotchMenuView.swift
//  AgentIsland
//
//  设置面板容器：返回行 + 分组页签 + 当前分组的内容。
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

    var body: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            // 返回会话列表
            MenuRow(
                icon: "chevron.left",
                label: l10n.t("Back")
            ) {
                viewModel.toggleMenu()
            }

            NotchMenuTabBar(selection: $viewModel.menuSection)

            // 当前分组的内容：放不下时在这里滚动
            ScrollView(.vertical, showsIndicators: false) {
                page
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
