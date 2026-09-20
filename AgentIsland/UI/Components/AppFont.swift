//
//  AppFont.swift
//  AgentIsland
//
//  全应用共用的「按用户字号档位缩放」的文字入口：`.appFont(_:)` 的调用形状与
//  `.font(.system(size:))` 一致，区别只是磅值乘上环境里的比例，并在档位变化时重排。
//
//  比例由内容根注入（NotchView 的会话列表与对话两个分支，见 `\.appTextScale`）。
//  设置面板不注入：面板高度由 NotchMenuMetrics 的常量解析式算出，设置行缩放会让
//  面板高度与真实版面漂移。
//

import CoreGraphics
import SwiftUI

private struct AppTextScaleKey: EnvironmentKey {
    /// 没有注入时的基准比例。
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 内容面的字号比例（1 = 基准档）。由内容根注入，见 `AppFont`。
    var appTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

extension View {
    /// 按当前字号档位缩放的系统字体。
    ///
    /// 用法与 `.font(.system(size:))` 相同；读环境里的比例，因此用户改档位时，
    /// 用到它的视图会跟着重排。
    func appFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(AppFontModifier(size: size, weight: weight, design: design))
    }
}

/// 把环境里的字号比例应用到 `.font(.system(size:))`。
private struct AppFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    @Environment(\.appTextScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}
