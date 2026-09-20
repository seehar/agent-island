//
//  LanguageSelector.swift
//  ClaudeIsland
//
//  管理语言选择行的展开/收起状态，使 NotchViewModel 能在选择器展开时
//  同步撑高设置面板（与 SoundSelector / ScreenSelector 的行为一致）。
//

import Combine
import Foundation

@MainActor
class LanguageSelector: ObservableObject {
    static let shared = LanguageSelector()

    @Published var isPickerExpanded: Bool = false

    /// 单个选项行的高度（与 SoundOptionRowInline 保持一致）。
    private let rowHeight: CGFloat = 32

    private init() {}

    /// 选择器展开时所需的额外高度。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return CGFloat(AppLanguage.allCases.count) * rowHeight + 8  // +8 为内边距
    }
}
