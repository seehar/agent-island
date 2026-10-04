//
//  NotchMenuView.swift
//  AgentIsland
//
//  设置面板容器：左侧竖向侧栏（配置页分组切换，仅设置面）+ 右列页眉（返回 + 标题）
//  与当前分组的内容。读数面（统计 / 额度）不显示侧栏，整块内容占满面板宽度。
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
    /// 额度页的视图模型：同样由内容根（`NotchView`）持有并透传——头部额度按钮与设置面板
    /// 共用一个实例，从哪边进来看到的配置与读数都是同一份。
    @ObservedObject var balanceViewModel: NewAPIBalanceViewModel
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isBackHovered = false

    var body: some View {
        // 侧栏在左、详情在右；**读数面（统计 / 额度）不显示侧栏**——它们不是设置导航里的
        // 一页（`railSelection(for:)` 返回 nil），整块内容占满面板宽度。
        //
        // 左右内边距取 4pt、栏间距取 12pt：两者合计与改动前的 8 + 4 相同，**详情列宽度
        // 一pt 不变**，换来的是侧栏左移 4pt、且与详情之间有 8pt 更宽的呼吸——原先 4pt
        // 直接复用了轨内条目间距（`sidebarItemSpacing`），两栏看着糊成一块。
        HStack(alignment: .top, spacing: NotchMenuMetrics.sidebarContentSpacing) {
            if let railSelection = NotchMenuSection.railSelection(for: viewModel.menuSection) {
                NotchMenuSidebar(
                    selection: railSelection,
                    // 可用内容宽决定侧栏档位（带标签 / 纯图标，见 `sidebarShowsLabels`）：
                    // 面板宽随「面板尺寸」档缩放、也会被屏幕宽度夹取，所以这里现算而不是取常量。
                    contentWidth: NotchMenuMetrics.contentAreaWidth(
                        inPanelWidth: viewModel.openedSize.width)
                ) { section in
                    viewModel.menuSection = section
                }
            }

            detailColumn
        }
        .padding(.horizontal, NotchMenuMetrics.panelContentPadding)
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

    /// 右列：页眉（范围控件那一格）+ 统计页的范围展开块 + 滚动区。
    private var detailColumn: some View {
        VStack(spacing: NotchMenuMetrics.rowSpacing) {
            pageHeader

            // 统计页的范围选择器：页眉控件的展开块，作为固定块插在页眉与滚动区之间，
            // 滚动视口因此收缩（正在挑日期时看不到多少内容是可以接受的）。
            // 它不参与 `openedSize`：读数面的高度是解析式（内容 635 + 开销，上限 730、
            // 不会被夹），这种展开只挤占视口——因此这里不需要给 `NotchViewModel` 加订阅。
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
            // 展开的选择器列表画在**滚动视口之上**的一层浮层里（不参与布局，因此不影响
            // 面板高度）。这一层还负责定义行取矩形用的坐标空间——浮层因此能跳出卡片的
            // 圆角裁切，贴着那一行摆放（见 `SettingsPickerOverlay`）。
            .settingsPickerOverlay()
        }
    }

    // MARK: - 页眉

    /// 页眉：返回会话列表的箭头 + 当前分组的标题。面板右上角的关闭按钮也在做同一件事，
    /// 但设置页自己需要一条导航式的返回与一个能说明「这是哪一页」的标题。
    /// 标题取当前分组名（与侧栏同一份映射，见 `NotchMenuSection.title(_:)`）——侧栏是
    /// 图标栏、标签全靠这里。只说「设置」等于让页眉与返回箭头两条信息说同一件事。
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

            // 快捷键页的「恢复默认」：与统计页的重扫按钮同一格。页眉这一行不占页面
            // 高度，页面里因此只有动作行，版面表与高度解析式保持一一对应。
            if viewModel.menuSection == .shortcuts {
                ShortcutResetButton()
            }

            // 统计页的时间范围控件在这一行里（不再占页面顶部一行）：左侧的分段控件
            // 形状与设置页的分组切换条相同，两条叠在一起会被读成「第二层导航」。
            if viewModel.menuSection == .statistics {
                StatsRangeControl(viewModel: statsViewModel)
                StatsRescanButton(viewModel: statsViewModel)
            } else if viewModel.menuSection == .quota {
                // 额度页没有范围可挑，这一格只放「更新于 HH:MM + 刷新」（与统计页互斥的另一支）。
                QuotaRefreshControl(viewModel: balanceViewModel)
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
            AgentsSettingsPage(onOpenAnimations: { viewModel.openAnimationsSettings() })
        case .shortcuts:
            ShortcutsSettingsPage()
        case .animations:
            AgentAnimationsSettingsPage()
        case .statistics:
            UsageStatisticsSettingsPage(viewModel: statsViewModel)
        case .quota:
            QuotaSettingsPage(viewModel: balanceViewModel)
        case .about:
            AboutSettingsPage(updateManager: updateManager, viewModel: viewModel)
        }
    }
}
