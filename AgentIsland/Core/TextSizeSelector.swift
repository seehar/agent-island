//
//  TextSizeSelector.swift
//  AgentIsland
//
//  内容面的字号档位。会话列表、对话与工具结果按这一档缩放；设置面板本身不缩放——
//  它的高度是由 NotchMenuMetrics 的常量解析式算出来的，缩放设置行会让面板高度与
//  真实版面漂移。
//  档位是「比例」而不是绝对磅值：各处本来就有 9~14 的层级，按比例缩放才能保住层级。
//

import Combine
import CoreGraphics
import Foundation

/// 内容面的字号档位。原始值即持久化值。
nonisolated enum TextSizeOption: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge = "extra-large"

    var id: String { rawValue }

    /// 相对基准档（`standard`）的字号比例。
    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .standard: return 1
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }
}

/// 字号档位的持久化与行内展开状态（与 LanguageSelector / NotchHeightSelector 同族）。
@MainActor
final class TextSizeSelector: ObservableObject {
    static let shared = TextSizeSelector()

    // MARK: - 状态

    /// 当前档位。
    @Published private(set) var option: TextSizeOption = .standard
    /// 选择器是否展开（展开时由 NotchViewModel 撑高面板）。
    @Published var isPickerExpanded: Bool = false

    // MARK: - 持久化

    /// 持久化键。
    private let optionKey = "textSizeOption"

    private let defaults: UserDefaults

    /// 默认读写标准偏好域；测试传独立域，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - 取值

    /// 当前档位对应的字号比例。
    var scale: CGFloat { option.scale }

    /// 展开时面板需要多出来的高度。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: TextSizeOption.allCases.count)
    }

    // MARK: - 修改

    /// 选择新档位并持久化。
    func select(_ newOption: TextSizeOption) {
        guard newOption != option else { return }
        option = newOption
        defaults.set(newOption.rawValue, forKey: optionKey)
    }

    // MARK: - 私有

    private func load() {
        guard let raw = defaults.string(forKey: optionKey),
            let stored = TextSizeOption(rawValue: raw)
        else { return }
        option = stored
    }
}
