//
//  PickerExpansion.swift
//  AgentIsland
//
//  设置面板里「展开块」的互斥：同一时刻只保留一个展开的选择器。
//
//  面板高度是按「内容 + 该页最高的**单个**展开 + chrome ≤ 728」核对的（见 `NotchMenuMetrics`），
//  多个展开块叠加会把面板直接顶到上限、内容落进隐藏滚动条的页内滚动里——用户只看到箭头
//  翻转，选项列表跑到视口外。因此这里把展开做成互斥：打开一个就收起上一个。
//
//  登记处**只记住当前展开的那一个**，不逐个列出选择器：列清单会与高度表漂移，
//  而弱引用登记天然只关心「现在谁开着」。
//

import Foundation

/// 可以被行内展开的选择器（枚举偏好骨架与各专用选择器都实现它）。
@MainActor
protocol PickerExpansionControlling: AnyObject {
    var isPickerExpanded: Bool { get set }
}

extension PickerExpansionControlling {
    /// 行内点按：展开前先收起面板里上一个展开块。
    func toggleExpansion() {
        if isPickerExpanded {
            isPickerExpanded = false
            PickerExpansion.didCollapse(self)
        } else {
            PickerExpansion.willExpand(self)
            isPickerExpanded = true
        }
    }
}

/// 展开块的互斥登记处。弱引用：选择器都是长生命周期单例，但登记不该延长任何人的寿命。
@MainActor
enum PickerExpansion {
    /// 当前展开的选择器；nil = 全部收起。
    private static weak var current: (any PickerExpansionControlling)?

    /// 展开前调用：收起上一个，再把自己登记为当前。
    static func willExpand(_ picker: any PickerExpansionControlling) {
        if let current, current !== picker {
            current.isPickerExpanded = false
        }
        current = picker
    }

    /// 收起时调用：只有当前登记的就是自己时才清空，别把后来者的登记擦掉。
    ///
    /// 绑定名不能叫 `current`：那样会把静态变量遮蔽成 `let` 常量，赋值就编译不过。
    static func didCollapse(_ picker: any PickerExpansionControlling) {
        guard let expanded = current, expanded === picker else { return }
        current = nil
    }
}

// MARK: - 参与互斥的选择器

/// 枚举偏好的骨架自带展开态，直接满足协议。
extension EnumPreference: PickerExpansionControlling {}

/// 语言、屏幕、音效、字号、胶囊高度与宽度都是「一个 Bool 的展开态」，逐个接上即可。
extension LanguageSelector: PickerExpansionControlling {}
extension ScreenSelector: PickerExpansionControlling {}
extension SoundSelector: PickerExpansionControlling {}
extension TextSizeSelector: PickerExpansionControlling {}
extension NotchHeightSelector: PickerExpansionControlling {}
extension NotchWidthSelector: PickerExpansionControlling {}
/// 额度页的「编辑凭据」：它当然不是选择器，但同样会撑高面板（账号列表折叠成一行 +
/// 三行读数换成凭据表单），因此接到同一套形状上——订阅守卫用例（`NotchMenuSubscriptionTests`）
/// 与展开互斥都按这个属性工作。
extension NewAPIAccountPageState: PickerExpansionControlling {
    var isPickerExpanded: Bool {
        get { isEditingCredentials }
        set { isEditingCredentials = newValue }
    }
}

/// 逐 Agent 的目录编辑器用 `expandedKind`（它天然只开一行），这里接到同一套互斥上：
/// 读 = 「有没有展开的」；写只发生在收起方向——展开哪一行由卡片的 `toggle(_:)` 给出，
/// 那一步自己会去登记（见 `AgentDirSelector.toggle`）。
extension AgentDirSelector: PickerExpansionControlling {
    var isPickerExpanded: Bool {
        get { expandedKind != nil }
        set { if !newValue { expandedKind = nil } }
    }
}
