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
    /// 统计页的视图模型：由内容根（`NotchView`）持有并透传——头部图标与设置面板两个
    /// 入口共用同一份状态（时间窗口、快照），从分组切回来不会重新取一次数据。
    @ObservedObject var statsViewModel: UsageStatsViewModel
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isBackHovered = false

    var body: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            pageHeader

            NotchMenuTabBar(selection: $viewModel.menuSection)

            // 统计页的范围选择器：页眉控件的展开块，作为固定块插在分段条与滚动区之间，
            // 滚动视口因此收缩（正在挑日期时看不到多少内容是可以接受的）。
            // 它不参与 `openedSize`：统计分组是固定 560 的整块，而这种组合已顶到 728
            // 上限，撑高与否都夹在上限上——因此这里不需要给 `NotchViewModel` 加订阅。
            if viewModel.menuSection == .statistics, statsViewModel.isRangePickerExpanded {
                StatsRangePickerPanel(viewModel: statsViewModel)
                    .padding(.top, NotchMenuMetrics.contentTopGap)
            }

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

    /// 页眉：返回会话列表的箭头 + 当前分组的标题。面板右上角的关闭按钮也在做同一件事，
    /// 但设置页自己需要一条导航式的返回与一个能说明「这是哪一页」的标题。
    /// 标题取当前分组名（与分段条同一份映射，见 `NotchMenuSection.title(_:)`）：
    /// 只说「设置」等于让页眉、分段条、返回箭头三条信息说同一件事，标题本身不表达位置。
    private var pageHeader: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.exitMenu()
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

            Text(viewModel.menuSection.title(l10n))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppPalette.primaryText)

            Spacer(minLength: 8)

            // 统计页的时间范围控件在这一行里（不再占页面顶部一行）：左侧的分段控件
            // 形状与设置页的分组切换条相同，两条叠在一起会被读成「第二层导航」。
            if viewModel.menuSection == .statistics {
                StatsRangeControl(viewModel: statsViewModel)
                StatsRescanButton(viewModel: statsViewModel)
            }
        }
        .frame(height: NotchMenuMetrics.pageHeaderHeight)
    }

    // MARK: - Page

    /// 当前分组对应的设置页。
    @ViewBuilder
    private var page: some View {
        switch viewModel.menuSection {
        case .general:
            GeneralSettingsPage(screenSelector: screenSelector)
        case .behavior:
            BehaviorSettingsPage()
        case .notifications:
            NotificationsSettingsPage()
        case .agents:
            AgentsSettingsPage()
        case .statistics:
            UsageStatisticsSettingsPage(viewModel: statsViewModel)
        case .about:
            AboutSettingsPage(updateManager: updateManager)
        }
    }
}
