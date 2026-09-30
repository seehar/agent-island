//
//  NotchMenuSidebar.swift
//  AgentIsland
//
//  设置面板的分组切换：竖向的图标侧栏（选中态在条目之间滑动）。
//

import Combine
import SwiftUI

/// 设置面板左侧的分组导航。
///
/// **为什么不用 `TabView` / `NavigationSplitView`**（两条都实测否决，理由写在这里
/// 以免以后有人再走一遍）：
///
/// - 宽度预算不够。面板内容宽 464pt（紧凑档 406pt）。原生侧栏最少要吃掉 150~200pt，
///   详情区只剩 263~313pt，而**统计页是以 464pt 标定的**（紧凑档 422 已经被裁掉
///   15.5pt，见 `UsageStatsLayout`）、**标记动态页画廊的硬下限是 304pt**
///   （见 `NotchMenuLayout` 的画廊常量）。两页都会被挤破，而 `panelWidthMax` 是面板、
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
/// + `matchedGeometryEffect`）竖着画：**只画图标不画文字**，详情区因此只被吃掉
/// `sidebarWidth`（32pt），没有任何一页的已标定版面被牺牲。分组名由页眉承担——
/// `pageHeader` 本来就在显示当前分组名，侧栏是第二处说明而不是唯一定位。
struct NotchMenuSidebar: View {
  @Binding var selection: NotchMenuSection
  @ObservedObject private var l10n = LocalizationManager.shared
  @State private var hoveredSection: NotchMenuSection?
  @Namespace private var thumb
  /// 「减弱动态效果」是系统级无障碍偏好：勾了就把换页的滑动换掉（见 `AppMotion`）。
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .center, spacing: NotchMenuMetrics.sidebarItemSpacing) {
      // 一级分组会滚动，「关于」钉底常驻。
      //
      // 分两条是因为**侧栏必须能放进最矮的一页**：额度页在没有账号时内容高只有 218pt
      // （`NotchMenuMetrics.contentHeight`），扣掉容器上下内边距只剩 238pt，而 6 个
      // 一级分组按 40pt 行高要 312pt。卡片外层是 `clipShape` 的，超出就会被裁掉——
      // 「关于」会直接消失。因此上面这一组自己滚动，下面这一组常驻，钉底可见。
      // `sidebarFooterAlwaysFits` 守住这个不变量。
      //
      // 滚动条必须藏起来（`showsIndicators: false`），**不要**用 `.scrollIndicators(.automatic)`：
      // macOS 上的 `.automatic` 是「内容放不下就常驻一条 overlay 轨道」，不像 iOS 会自动收起——
      // 而这条 32pt 窄栏本来就常年放不下（额度页那档），于是侧栏上会永远压着一根灰色滑块，
      // 还会盖住栏与详情区之间的缝隙，看起来像画错了。窄栏滚动靠图标本身与选中滑块提示即可。
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .center, spacing: NotchMenuMetrics.sidebarItemSpacing) {
          ForEach(NotchMenuSection.sidebarSections) { section in
            item(for: section)
          }
        }
      }
      .frame(maxHeight: .infinity)

      Rectangle()
        .fill(AppPalette.separator)
        .frame(
          width: NotchMenuMetrics.sidebarDividerLength,
          height: NotchMenuMetrics.sidebarDividerThickness
        )

      ForEach(NotchMenuSection.sidebarFooterSections) { section in
        item(for: section)
      }
    }
    .frame(width: NotchMenuMetrics.sidebarWidth)
    .padding(.vertical, 2)
    // 指针**整个离开侧栏**时清掉悬停态。只靠条目自己的 `onHover(false)` 清不干净：
    // 面板收起、`ignoresMouseEvents` 切换、指针瞬移这几种情况下退出事件不会送达，
    // 悬停底色会留在上一个条目上——与真正的选中底色叠在一起，看上去像「选中了两个」。
    .onHover { inside in
      if !inside { hoveredSection = nil }
    }
  }

  // MARK: - 条目

  /// 一个条目。选中态由 `matchedGeometryEffect` 在条目之间移动，因此换页时看到的是
  /// 高亮滑过去，而不是新条目突然亮一下。
  private func item(for section: NotchMenuSection) -> some View {
    let isSelected = section == selection

    return Button {
      // 动画挂在点击上：选中标记滑动与面板高度的变化（`openedSize` 随分组变）同帧，
      // 不再像分段栏那样靠外层的 `withAnimation` 兜底。
      withAnimation(AppMotion.pick(SettingsMotion.segment, reduceMotion: reduceMotion)) {
        selection = section
      }
    } label: {
      Image(systemName: section.symbolName)
        .font(.system(size: NotchMenuMetrics.sidebarIconSize, weight: .medium))
        .foregroundColor(foregroundColor(for: section))
        // 命中区是**整条栏 × 行高**（点得到，也和右侧设置行按同一节奏排）；
        // 底色则是 `sidebarItemBox` 见方的瓦片，在行高里居中——铺满 40 高会读成一块
        // 竖长方，而不是一个图标（判据见 `NotchMenuMetrics.sidebarItemBox`）。
        .frame(
          width: NotchMenuMetrics.sidebarWidth,
          height: NotchMenuMetrics.sidebarItemHeight
        )
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
              .fill(AppPalette.segmentedThumb)
              .frame(
                width: NotchMenuMetrics.sidebarItemBox,
                height: NotchMenuMetrics.sidebarItemBox
              )
              .matchedGeometryEffect(id: "sidebar-thumb", in: thumb)
          } else if hoveredSection == section {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
              .fill(AppPalette.rowHover)
              .frame(
                width: NotchMenuMetrics.sidebarItemBox,
                height: NotchMenuMetrics.sidebarItemBox
              )
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
    // 侧栏只画图标（`sidebarWidth` 装不下文字），页名必须另有一个出口：悬停提示给出
    // 这一页叫什么，取的与页眉同一份映射（`NotchMenuSection.title(_:)`）。
    .help(section.title(l10n))
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
  /// 分组标题：侧栏的无障碍标签与设置面板的页眉共用同一份映射（页眉要说清「现在在哪一页」）。
  /// 在视图里解析而不是放进 `NotchMenuSection`：key 保持字面量，本地化守卫才能审计到；
  /// 同时在观察 `LocalizationManager` 的视图内解析，切换语言才会重新渲染。
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
