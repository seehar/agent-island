//
//  SoundSelector.swift
//  AgentIsland
//
//  Manages sound selection state for the settings menu
//

import Combine
import Foundation

@MainActor
class SoundSelector: ObservableObject {
    static let shared = SoundSelector()

    // MARK: - Published State

    @Published var isPickerExpanded: Bool = false

    // MARK: - Constants

    /// 展开后不滚动就能看到的音效数；超出的部分在选项列表里滚动。
    ///
    /// 取 4 是通知页的预算：音效列表 4 行 + 顶部试听行共 170pt；通知页内容高 312，
    /// 加最大 chrome 76 共 558，仍在面板上限 728 内。改大档位数会把最后一档挤出可视区。
    nonisolated static let maxVisibleOptions = 4

    /// 展开块里不参与滚动的行数（顶部那行「试听」）。
    /// 提成常量是为了让展开高度与预算用例读同一个来源，而不是各写一个 +32。
    nonisolated static let previewRows = 1

    private init() {}

    // MARK: - Public API

    /// Extra height needed when picker is expanded (capped for scrolling)
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        let totalOptions = NotificationSound.allCases.count
        let visibleOptions = min(totalOptions, Self.maxVisibleOptions)
        // 试听行与列表同属这个展开块：列表本身在 SoundPickerRow 里滚动，试听行不滚。
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: visibleOptions + Self.previewRows)
    }
}
