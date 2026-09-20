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
    nonisolated static let maxVisibleOptions = 6

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
