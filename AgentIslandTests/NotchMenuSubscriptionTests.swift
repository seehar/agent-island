//
//  NotchMenuSubscriptionTests.swift
//  AgentIslandTests
//
//  设置面板的**展开订阅**不变量：`NotchViewModel.expandedPickerHeight(for:)` 里累加的每一个
//  选择器，都必须在 `observeSelectors()` 里被订阅。
//
//  为什么必须单独钉：面板内的点击不走 `handleMouseDown`（落在面板内会直接 return），
//  只有订阅路径才会让 `openedSize` 重算。漏掉一个的症状是「**只有那一行**展开时面板不长高、
//  选项被下边缘裁掉」——而版面表与高度公式本身都是对的，所以预算用例抓不到它
//  （本仓历史上漏过两次，2026-09-23 又漏了一次安静时段）。
//
//  判据必须数**重发布**，不能读 `openedSize`：它是计算属性，读的时候按当前状态重算，
//  因此「漏了订阅」也照样返回正确高度（第一版就是这么写错的，消融实验当场证伪）。
//  真正会坏的是 SwiftUI 的失效链——漏订阅 ⇒ 选择器变化不会让面板重算 ⇒ 界面不长高。
//

import Combine
import CoreGraphics
import Testing

@testable import AgentIsland

@MainActor
@Suite("设置面板的展开订阅")
struct NotchMenuSubscriptionTests {
    /// 与真实窗口同形：内置刘海 32 → chrome 44，各页在这个开销下都不会被夹到上限，
    /// 因此「展开 → 长高」是可观测的。
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 180, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750,
            hasPhysicalNotch: true)
    }

    /// 触发一次变化，返回 `NotchViewModel` 重发布的次数。
    private func republications(_ model: NotchViewModel, change: () -> Void) -> Int {
        var count = 0
        var bag = Set<AnyCancellable>()
        model.objectWillChange
            .sink { _ in count += 1 }
            .store(in: &bag)
        change()
        return count
    }

    @Test("每个可展开的选择器都被订阅：在它所属那一页展开，面板必须被重发布")
    func everyExpandablePickerIsObserved() {
        let model = makeViewModel()
        model.contentType = .menu

        // 与 `NotchViewModel.expandedPickerHeight(for:)` 的分项一一对应：
        // 新增一个可展开行时，这里也要补一行（漏了就会被这条用例挡下来）。
        let pickers: [(name: String, section: NotchMenuSection, picker: any PickerExpansionControlling)] = [
            ("语言", .general, LanguageSelector.shared),
            ("屏幕", .general, ScreenSelector.shared),
            ("胶囊高度", .general, NotchHeightSelector.shared),
            ("胶囊宽度", .general, NotchWidthSelector.shared),
            ("内容字号", .general, TextSizeSelector.shared),
            ("面板尺寸", .general, PanelSizeSelector.shared),

            ("悬停展开", .behavior, HoverExpandSelector.shared),
            ("空闲胶囊", .behavior, IdleNotchVisibilitySelector.shared),
            ("已结束会话", .behavior, SessionRetentionSelector.shared),
            ("行信息密度", .behavior, SessionRowDensitySelector.shared),
            ("单击动作", .behavior, SessionRowClickActionSelector.shared),
            ("刷新频率", .behavior, RefreshCadenceSelector.shared),

            ("通知音效", .notifications, SoundSelector.shared),
            ("安静时段", .notifications, QuietHoursSelector.shared),
            ("提示音范围", .notifications, NotificationScopeSelector.shared),
            ("完成提示", .notifications, CompletionBadgeSelector.shared),

            ("运行前询问什么", .agents, ApprovalAskScopeSelector.shared),
            ("应用未运行时", .agents, ApprovalDegradationSelector.shared),
            ("待批自动展开", .agents, ApprovalAutoExpandSelector.shared),

            ("账号", .quota, NewAPIAccountSelector.shared),
        ]

        for (name, section, picker) in pickers {
            // 从收起态起测：展开互斥（`PickerExpansion`）只在行内点按时生效，
            // 这里直接改属性，因此必须自己保证起点干净。
            picker.isPickerExpanded = false
            model.menuSection = section

            let count = republications(model) { picker.isPickerExpanded = true }

            #expect(
                count > 0,
                "「\(name)」在 \(section.rawValue) 页展开时 NotchViewModel 没有重发布：`observeSelectors()` 里漏了它的订阅（界面症状：只有这一行展开时面板不长高、最后一个档位被下边缘裁掉）")

            // 顺带交叉检查它确实算进了那一页的高度：chrome = max(24, 胶囊高度) + 12
            // （与 `NotchViewModel.panelChromeHeight` 同式，这里按测试模型的参数算）。
            let chrome = max(24, makeViewModel().deviceNotchRect.height) + 12
            #expect(
                model.openedSize.height > NotchMenuMetrics.contentHeight(for: section) + chrome,
                "「\(name)」展开后没有计入 \(section.rawValue) 页的高度")

            picker.isPickerExpanded = false
        }
    }

    @Test("智能体页的行内目录编辑器也在订阅里（它用 expandedKind，不是 Bool 属性）")
    func agentDirectoryEditorIsObserved() {
        let model = makeViewModel()
        model.contentType = .menu
        model.menuSection = .agents
        AgentDirSelector.shared.expandedKind = nil

        let count = republications(model) {
            AgentDirSelector.shared.expandedKind = .claudeCode
        }

        #expect(
            count > 0,
            "目录编辑器展开时 NotchViewModel 没有重发布：漏了 `AgentDirSelector.$expandedKind` 的订阅")

        AgentDirSelector.shared.expandedKind = nil
    }
}
