//
//  NewAPIAccountSelector.swift
//  AgentIsland
//
//  「额度」页账号行（选择当前账号）的行内展开态：与其它选择器同一套做法——
//  NotchViewModel 按它撑高面板（见 `expandedPickerHeight(for: .quota)`），
//  账号列表本身在选项块里滚动，列表长度不参与面板高度。
//
//  账号是运行时才知道有几个的（用户增删），因此这里只登记**可见行数**这一个常量：
//  面板高度必须可解析，超出可见行数的账号在列表里滚动。
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class NewAPIAccountSelector: ObservableObject {
    static let shared = NewAPIAccountSelector()

    // MARK: - 状态

    /// 选择器是否展开（展开时由 NotchViewModel 撑高面板）。
    @Published var isPickerExpanded: Bool = false

    /// 账号列表的可见行数（1…`visibleOptions`），由视图在账号增删时写回。
    ///
    /// 它参与面板高度解析式：账号少时展开块就矮——固定按 3 行算会让只有一个账号的用户
    /// 看到一截空白（音效列表不这样，是因为内置音效永远多于可见行数，账号不是）。
    @Published private(set) var visibleOptionCount = 1

    // MARK: - 常量

    /// 展开后不滚动就能看到的账号数；超出的部分在选项列表里滚动。
    ///
    /// 取 3 是额度页的预算：展开块 = 3×32 + 10 = 106pt；额度页内容 540（页内两块的头/行/脚注）
    /// 加最大 chrome 76 共 722，仍在面板上限 728 内（见 `NotchMenuMetricsTests`）。
    nonisolated static let visibleOptions = 3

    private init() {}

    // MARK: - 写入

    /// 账号数量变化时写回可见行数（至少 1 行：永远有一个账号可编辑）。
    func setAccountCount(_ count: Int) {
        let visible = max(1, min(count, Self.visibleOptions))
        guard visible != visibleOptionCount else { return }
        visibleOptionCount = visible
    }

    // MARK: - 高度

    /// 展开时面板需要多出来的高度。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: visibleOptionCount)
    }
}
