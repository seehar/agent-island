//
//  PickerExpansion.swift
//  AgentIsland
//
//  设置面板里「展开块」的互斥：同一时刻只保留一个展开的选择器。
//
//  值选择的选项列表是浮层（见 `SettingsPickerOverlay`），因此互斥不再是为了面板高度，
//  而是三条实打实的交互需要：
//  **① 打开一个就收起上一个**（面板那么小，两张浮层互相压着没法读）；
//  **② Esc 先收浮层、再逐层返回**（`ShortcutController` 调 `collapseCurrent()`，
//  返回 true 表示这一次按键到此为止）；
//  **③ 离开面板 / 换页时收干净**（`NotchMenuView` 的 onChange），否则回来时那张浮层
//  没有主人——它的行还没挂载。
//
//  登记处**只记住当前展开的那一个**，不逐个列出选择器：列清单会与浮层的实际来源漂移，
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

    /// 收起当前展开的选项列表，返回「这次是否真的收起了一个」。
    ///
    /// 存在的理由：`ShortcutController` 的 Esc（返回/收起）必须先走这一步。展开块在界面上
    /// 只有鼠标两条收起路径（行内点按、点箭头），键盘上再无别路；Esc 若按面的层级直接退出，
    /// 用户会连整页一起被带出设置页——想「只收起这张列表」就得重新进页面、重新展开。
    /// 因此收起成功的这一次按键到此为止，页面的逐层返回留到下一次。
    ///
    /// 返回值 false 有两层含义：本来就没有展开块，或者登记还在、其实已经收起（有的路径
    /// 直接改 `isPickerExpanded`，不走登记处）——后者顺手把陈旧登记清掉。
    @discardableResult
    static func collapseCurrent() -> Bool {
        guard let picker = current else { return false }
        guard picker.isPickerExpanded else {
            current = nil
            return false
        }
        picker.isPickerExpanded = false
        current = nil
        return true
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
