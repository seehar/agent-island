//
//  NotchPanelSurface.swift
//  AgentIsland
//
//  面板卡片的承载面：给出「一块可裁成任意形状的卡片底」，并按系统版本分叉。
//  形状是泛型的：展开态面板 / 关闭态胶囊传 `NotchShape`，浮在面板之上的小块
//  （热力图悬停浮卡）传圆角矩形——玻璃质感只在这一处实现。
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
struct NotchPanelSurface<S: Shape>: ViewModifier {
  /// 卡片形状。面板传 `NotchShape`（与 `NotchView` 裁剪用的是同一份，不另写圆角），
  /// 浮在面板之上的小块（热力图悬停浮卡）传圆角矩形。
  let shape: S
  /// 材质之上的压暗罩不透明度。越大越接近纯黑（文字层级越稳），越小越透出下层色温。
  /// 档位见 `NotchSurfaceScrim`。
  var scrim: Double = NotchSurfaceScrim.panel
  /// 玻璃上的染色（Liquid Glass 的 `tint`）。面板不染；浮在面板之上的小块染一层黑
  /// ——应用本身是暗色的（`AppPalette` 全套叠白都按「底是纯黑」定的），而系统在**浅色外观**
  /// 下会把规则玻璃画成浅色卡片，白字压不住。
  var tint: Color?

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
            Color.clear.glassEffect(glass, in: shape)
          } else {
            shape.fill(.ultraThinMaterial)
          }
          shape.fill(.black.opacity(scrim))
        }
      }
  }
}

/// 压暗罩的几档强度（面板与浮卡共用同一套材质，只在这里分档）。
nonisolated enum NotchSurfaceScrim {
  /// 面板底。取值区间 0.55~0.7；往下调会让 `AppPalette.subtleText`（0.30）那层开始发飘，
  /// 往上调材质就白透了个寂寞。改它只需要重装 + 截同一组页面对比。
  static let panel: Double = 0.62
  /// 浮在面板之上的小块（热力图悬停浮卡这类）：比面板浅一档，读起来是「面板之上的一层」，
  /// 同时比「叠白 0.05」实得多——浮卡要压得住底下的格网、还得看清两行读数。
  static let floating: Double = 0.45
  /// 浮卡的玻璃染色：把规则玻璃按应用的暗色口径压一层，浅色外观下也是暗玻璃。
  static let floatingTint = Color.black.opacity(0.35)
}

extension View {
  /// 卡片底：系统材质 + 压暗罩。裁剪仍由调用方的 `clipShape` 负责。
  ///
  /// - Parameters:
  ///   - shape: 卡片形状。面板传 `currentNotchShape`（与 `clipShape` 同源），
  ///     浮卡传 `RoundedRectangle`。
  ///   - scrim: 压暗罩强度，档位见 `NotchSurfaceScrim`。
  func notchPanelSurface<S: Shape>(
    shape: S,
    scrim: Double = NotchSurfaceScrim.panel,
    tint: Color? = nil
  ) -> some View {
    modifier(NotchPanelSurface(shape: shape, scrim: scrim, tint: tint))
  }
}
