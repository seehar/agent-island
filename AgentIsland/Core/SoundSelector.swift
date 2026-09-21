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
    /// 取 4 是行为页的预算：那一页内容高 536，加展开量 138 与外部屏的固定开销 44
    /// 等于 718，仍在面板上限 728 内。改大这个数会把最后一个档位挤出可视区
    /// （滚动条是隐藏的，用户看不到还有内容）。
    nonisolated static let maxVisibleOptions = 4

    private init() {}

    // MARK: - Public API

    /// Extra height needed when picker is expanded (capped for scrolling)
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        let totalOptions = NotificationSound.allCases.count
        let visibleOptions = min(totalOptions, Self.maxVisibleOptions)
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: visibleOptions)
    }
}
