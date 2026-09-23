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
    /// 取 6 是通知页的预算：展开块 = 6×32 + 10 = 202pt；通知页内容 332（含脚注）
    /// 加最大 chrome 76 共 610，仍在面板上限 728 内。
    /// 档位总数是动态的（内置 14 + 用户自带若干），因此这里定的是**可见行数**：
    /// 列表本身在 `SoundPickerRow` 里滚动，用户放多少音效都不改变面板高度。
    nonisolated static let maxVisibleOptions = 6

    private init() {}

    // MARK: - Public API

    /// Extra height needed when picker is expanded (capped for scrolling)
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        // 固定按「可见档位数」算，不看总档位数：面板高度必须可解析，
        // 而用户音效有几个是运行时才知道的（超出的在列表里滚动）。
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: Self.maxVisibleOptions)
    }
}
