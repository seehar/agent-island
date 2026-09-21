//
//  ClaudeDirSelector.swift
//  AgentIsland
//
//  Manages the expand/collapse state of the Claude directory picker row,
//  so NotchViewModel can grow the settings panel when the picker is open
//  (matching SoundSelector / ScreenSelector behavior).
//

import Combine
import Foundation

@MainActor
class ClaudeDirSelector: ObservableObject {
    static let shared = ClaudeDirSelector()

    @Published var isPickerExpanded: Bool = false


    /// 展开后的选项行数：自动检测 + 选择文件夹。
    /// 面板高度按它算，预算核对（`NotchMenuMetricsTests`）也读它，不要再写数字。
    nonisolated static let visibleOptions = 2

    private init() {}

    /// Extra height needed when the picker is expanded.
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: Self.visibleOptions)
    }
}
