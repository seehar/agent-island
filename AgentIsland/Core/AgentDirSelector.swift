//
//  AgentDirSelector.swift
//  AgentIsland
//
//  「监控的智能体」卡片里逐行目录编辑器的展开态：同一时刻只展开一行，
//  NotchViewModel 与卡片都据此把可视窗口撑高（与其它选择器的 expand/collapse
//  同一套做法）。
//

import Combine
import Foundation

@MainActor
class AgentDirSelector: ObservableObject {
    static let shared = AgentDirSelector()

    /// 当前展开目录编辑器的 Agent；nil = 全部收起。
    ///
    /// 单个值而不是每行一个 Bool：编辑器占的是卡片窗口的高度，同时展开多行就得
    /// 把窗口撑成「多份编辑器」高，而面板高度预算是按一份算的（见
    /// `expandedPickerHeight`）。
    @Published var expandedKind: AgentKind?

    /// 展开后的选项行数：自动检测 + 选择文件夹 + 恢复默认。
    /// 面板高度按它算，预算核对（`NotchMenuMetricsTests`）也读它，不要再写数字。
    nonisolated static let visibleOptions = 3

    private init() {}

    /// 展开时卡片需要多出来的高度。
    var expandedPickerHeight: CGFloat {
        guard expandedKind != nil else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: Self.visibleOptions)
    }

    /// 点同一行是收起，点另一行是换展开（同时只能展开一行）。
    ///
    /// 展开时到 `PickerExpansion` 登记：面板里同一时刻只留一个展开块（含其它页的
    /// 选择器），否则叠加的展开高度会把面板顶到上限、内容落进隐藏滚动条里。
    func toggle(_ kind: AgentKind) {
        guard expandedKind != kind else {
            expandedKind = nil
            PickerExpansion.didCollapse(self)
            return
        }
        PickerExpansion.willExpand(self)
        expandedKind = kind
    }
}