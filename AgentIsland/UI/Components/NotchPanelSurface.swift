//
//  NotchPanelSurface.swift
//  AgentIsland
//
//  面板卡片的承载面：给出「一块可裁成任意形状的卡片底」，并按系统版本分叉。
//

import SwiftUI

/// 面板卡片的背景。
///
/// 面板过去是纯黑（`Color.black`）。这里换成系统材质，但**必须**在材质之上再叠一层
/// 压暗罩（`scrim`）——面板里的文字层级全部建立在「底是纯黑」之上：
/// `AppPalette` 的四级文字是 `white` 上 0.92 / 0.55 / 0.38 / 0.30 四档叠白，
/// `cardFill` / `rowHover` / `separator` 同理。直接换成浅色材质，第四级文字会直接
/// 消失在亮背景里。压暗罩把有效亮度拉回接近纯黑，于是**上层配色一行都不用改**，
/// 只有底层观感变了。
///
/// 按版本分叉：
/// - macOS 26+：原生 Liquid Glass（`glassEffect`）。
/// - 更早（部署目标 15.6）：SwiftUI 原生 `Material`。
///
/// 两条分支共用同一个 `scrim`，材质本身的差异被压暗罩压到看不出来。
///
/// **层次顺序**（`ZStack` 自下而上）：材质 → 压暗罩 → 内容。压暗罩如果画在内容之上
/// 会把文字一起压暗 0.62，那才是错的。
///
/// - Note: 关闭态胶囊与展开态面板**共用这个组件**（见 `NotchView.NotchCard`）：无刘海的屏上
///   胶囊整块飘在菜单栏上，纯黑会读成一条贴死的黑边；有物理刘海的屏上，挖孔那段背后是黑
///   像素、材质在它上面只剩压暗后的近黑，而两耳取的是菜单栏底色——亮度差随背景色而定。
struct NotchPanelSurface: ViewModifier {
  /// 卡片形状。与 `NotchView` 裁剪用的是同一个 `NotchShape`，不另写一份圆角。
  let shape: NotchShape
  /// 材质之上的压暗罩不透明度。越大越接近纯黑（文字层级越稳），越小越透出下层色温。
  var scrim: Double

  /// 面板底默认的压暗罩强度。
  ///
  /// 取值区间 0.55~0.7；往下调会让 `AppPalette.subtleText`（0.30）那层开始发飘，
  /// 往上调材质就白透了个寂寞。改它只需要重装 + 截同一组页面对比。
  static let defaultScrim: Double = 0.62

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
          } else {
            shape.fill(.ultraThinMaterial)
          }
          shape.fill(.black.opacity(scrim))
        }
      }
  }
}

extension View {
  /// 面板卡片底：系统材质 + 压暗罩。裁剪仍由调用方的 `clipShape` 负责。
  ///
  /// - Parameters:
  ///   - shape: 卡片形状，调用方通常传 `currentNotchShape`（与 `clipShape` 同源）。
  ///   - scrim: 压暗罩强度，默认 `NotchPanelSurface.defaultScrim`。
  func notchPanelSurface(
    shape: NotchShape,
    scrim: Double = NotchPanelSurface.defaultScrim
  ) -> some View {
    modifier(NotchPanelSurface(shape: shape, scrim: scrim))
  }
}
