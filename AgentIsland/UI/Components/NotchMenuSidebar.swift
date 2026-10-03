//
//  NotchMenuSidebar.swift
//  AgentIsland
//
//  设置面板的分组切换：竖向侧栏（选中态在条目之间滑动）。内容宽够时带文字标签，
//  装不下时退回纯图标档——判据见 `NotchMenuMetrics.sidebarShowsLabels`。
//

import Combine
import SwiftUI

/// 设置面板左侧的分组导航。
///
/// **为什么不用 `TabView` / `NavigationSplitView`**（两条都实测否决，理由写在这里
/// 以免以后有人再走一遍）：
///
/// - 宽度预算不够。面板内容宽 448pt（紧凑档 390pt）。原生侧栏最少要吃掉 150~200pt，
///   详情区只剩 250~320pt，而**「标记动态」页画廊的硬下限是 304pt**
///   （`NotchMenuMetrics.minDetailWidth` 就是从它推出的）；`panelWidthMax` 又是面板、
///   会话列表、统计页**共用**的常量，抬它就要重标定统计页的全部尺寸常量。
/// - 原生 chrome 打架。面板是 `.borderless` + `nonactivatingPanel` + `isOpaque = false`
///   的浮层，卡片由 `AppPalette` 自绘并带圆角裁切；`NavigationSplitView` 会画自己的
///   分隔线与 vibrancy 材质侧栏，材质块被外层圆角裁出直角边。
/// - `List` 是 NSTableView 支撑的滚动控件，会接管滚轮与追踪区。本窗口盖住屏顶 750pt，
///   「只在卡片矩形内吃事件」是刻意的约束（见 `NotchWindowController` 的
///   `updateMouseAcceptance` 与 `ClickForwarding`），叠一层不受控的 AppKit 命中测试
///   风险太高。
///
/// 所以侧栏用与原分段栏同一套自绘原语（`AppPalette` + `SettingsCompactButtonStyle`
/// + `matchedGeometryEffect`）画成两档：
///
/// - **带标签档**（`NotchMenuMetrics.sidebarLabeledWidth`，113pt）：图标 + 页面名。
///   4 个配置页各有各的名字，用户不必逐个悬停去猜——这一档存在的全部理由。
/// - **图标档**（`sidebarIconWidth`，32pt）：内容宽装不下「标签 + 画廊硬下限」时退回
///   这一档（紧凑档内容宽只有 414pt），详情列因此与侧栏化之前同宽。
///
/// 哪些分组进侧栏、子页点亮谁、哪种面根本不显示侧栏，全部由
/// `NotchMenuSection.sidebarSections` 与 `railSelection(for:)` 决定——视图不自己判断。
struct NotchMenuSidebar: View {
    /// 该点亮哪一项（`NotchMenuSection.railSelection(for:)`：不占侧栏位的子页点亮父页）。
    let selection: NotchMenuSection
    /// 可用内容宽（面板宽减去容器的左右内边距）：决定带标签还是退回图标档。
    let contentWidth: CGFloat
    /// 选中某一项（写回面板的 `menuSection`）。
    let onSelect: (NotchMenuSection) -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var hoveredSection: NotchMenuSection?
    @Namespace private var thumb
    /// 「减弱动态效果」是系统级无障碍偏好：勾了就把换页的滑动换掉（见 `AppMotion`）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前档位。
    private var showsLabels: Bool {
        NotchMenuMetrics.sidebarShowsLabels(inContentWidth: contentWidth)
    }

    private var railWidth: CGFloat {
        NotchMenuMetrics.sidebarWidth(inContentWidth: contentWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.sidebarItemSpacing) {
            // 4 个配置页，加钉底常驻的「关于」。
            //
            // **这里不再套 `ScrollView`**：4 + 1 项在最矮的设置页也放得下（判据见
            // `NotchMenuMetricsTests.sidebarFitsShortestSettingsPage`）。也不要再加回来
            // 一个 `ScrollView` + `.scrollIndicators(.automatic)`：macOS 上的 `.automatic`
            // 与 iOS 相反，是「内容放不下就**常驻**一条 overlay 轨道」，窄栏上会永远压着
            // 一根灰滑块、还盖住栏与详情之间的缝隙（这个回归实机截图里报过一次）。
            ForEach(NotchMenuSection.sidebarSections) { section in
                item(for: section)
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(AppPalette.separator)
                .frame(
                    width: NotchMenuMetrics.sidebarDividerLength(showsLabels: showsLabels),
                    height: NotchMenuMetrics.sidebarDividerThickness
                )
                .padding(.leading, NotchMenuMetrics.sidebarIconLeading)

            ForEach(NotchMenuSection.sidebarFooterSections) { section in
                item(for: section)
            }
        }
        .frame(width: railWidth, alignment: .leading)
        // 钉底的「关于」靠这一条撑开（父级 HStack 的 `alignment: .top`，详情列自己更高）。
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.vertical, NotchMenuMetrics.sidebarVerticalPadding)
        // 指针**整个离开侧栏**时清掉悬停态。只靠条目自己的 `onHover(false)` 清不干净：
        // 面板收起、`ignoresMouseEvents` 切换、指针瞬移这几种情况下退出事件不会送达，
        // 悬停底色会留在上一个条目上——与真正的选中底色叠在一起，看上去像「选中了两个」。
        .onHover { inside in
            if !inside { hoveredSection = nil }
        }
    }

    // MARK: - 条目

    /// 一个条目。图标档没有文字，页名只能靠悬停提示给出；带标签档下标签就在眼前，
    /// 再叠一条 tooltip 是噪声。
    @ViewBuilder
    private func item(for section: NotchMenuSection) -> some View {
        if showsLabels {
            itemButton(for: section)
        } else {
            itemButton(for: section).help(section.title(l10n))
        }
    }

    /// 条目本体。选中态由 `matchedGeometryEffect` 在条目之间移动，因此换页时看到的是
    /// 高亮滑过去，而不是新条目突然亮一下。
    private func itemButton(for section: NotchMenuSection) -> some View {
        let isSelected = section == selection

        return Button {
            // 动画挂在点击上：选中标记滑动与面板高度的变化（`openedSize` 随分组变）同帧。
            withAnimation(AppMotion.pick(SettingsMotion.segment, reduceMotion: reduceMotion)) {
                onSelect(section)
            }
        } label: {
            Group {
                if showsLabels {
                    // 标签列宽 = 栏宽 − 图标左留白 − 图标 − 间距 − 尾距，与
                    // `sidebarWidth(forLabelWidth:)` 是同一笔账（那条就是按最长标签推的）。
                    HStack(spacing: NotchMenuMetrics.sidebarIconLabelGap) {
                        glyph(for: section)

                        Text(section.title(l10n))
                            .font(.system(size: NotchMenuMetrics.sidebarLabelSize, weight: .medium))
                            .foregroundColor(foregroundColor(for: section))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, NotchMenuMetrics.sidebarIconLeading)
                    .padding(.trailing, NotchMenuMetrics.sidebarLabelTrailing)
                } else {
                    glyph(for: section)
                }
            }
            .frame(
                width: railWidth,
                height: NotchMenuMetrics.sidebarItemHeight(showsLabels: showsLabels)
            )
            .background {
                background(isSelected: isSelected, for: section)
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

    /// 选中 / 悬停底色。带标签档是一条整行的圆角矩形，图标档是 `sidebarItemBox` 见方的
    /// 方形瓦片——铺满行高（40）会读成一块竖长方，而不是一个图标（实机截图就是这个观感）。
    @ViewBuilder
    private func background(isSelected: Bool, for section: NotchMenuSection) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        if isSelected {
            thumbFrame(shape.fill(AppPalette.segmentedThumb))
                .matchedGeometryEffect(id: "sidebar-thumb", in: thumb)
        } else if hoveredSection == section {
            thumbFrame(shape.fill(AppPalette.rowHover))
        }
    }

    /// 底色的尺寸：带标签档相对条目内缩 `sidebarThumbInset`（整行一条），图标档取
    /// `sidebarItemBox` 见方、在行高里**居中**。
    ///
    /// 图标档必须显式给这个方形 frame：底色层拿到的是整个条目框（栏宽 × 行高 40），
    /// 只内缩 `sidebarThumbInset` 会得到一个 28 × 36 的竖长方——正是 `sidebarItemBox`
    /// 注释里说的那个观感缺陷（离屏渲染逐行量过：32 × 32 → 28 × 36）。
    @ViewBuilder
    private func thumbFrame(_ shape: some View) -> some View {
        if showsLabels {
            shape.padding(NotchMenuMetrics.sidebarThumbInset)
        } else {
            shape.frame(
                width: NotchMenuMetrics.sidebarItemBox,
                height: NotchMenuMetrics.sidebarItemBox)
        }
    }

    private func glyph(for section: NotchMenuSection) -> some View {
        Image(systemName: section.symbolName)
            .font(.system(size: NotchMenuMetrics.sidebarIconSize, weight: .medium))
            .foregroundColor(foregroundColor(for: section))
            .frame(
                width: NotchMenuMetrics.sidebarIconSize, height: NotchMenuMetrics.sidebarIconSize)
    }

    // MARK: - 表现

    private func foregroundColor(for section: NotchMenuSection) -> Color {
        if section == selection { return AppPalette.primaryText }
        if hoveredSection == section { return AppPalette.hoverForeground }
        return AppPalette.secondaryText
    }
}

// MARK: - 分组标题

extension NotchMenuSection {
    /// 分组标题：侧栏的标签与无障碍标签、设置面板的页眉共用同一份映射（页眉要说清
    /// 「现在在哪一页」）。在视图里解析而不是放进 `NotchMenuSection`：key 保持字面量，
    /// 本地化守卫才能审计到；同时在观察 `LocalizationManager` 的视图内解析，切换语言
    /// 才会重新渲染。
    func title(_ l10n: LocalizationManager) -> String {
        switch self {
        case .general: return l10n.t("General")
        case .behavior: return l10n.t("Behavior")
        case .notifications: return l10n.t("Notifications")
        case .agents: return l10n.t("Agents")
        case .statistics: return l10n.t("Statistics")
        case .quota: return l10n.t("Quota")
        case .shortcuts: return l10n.t("Keyboard Shortcuts")
        case .animations: return l10n.t("Animations")
        case .about: return l10n.t("About")
        }
    }
}
