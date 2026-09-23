//
//  PreferencePickerRow.swift
//  AgentIsland
//
//  枚举偏好行的通用骨架：图标块 + 标题 + 当前取值（含补充说明），展开后列出所有档位。
//  选项文案与说明由调用方给出：文案必须在视图里按字面量取键，本地化守卫才能审计到，
//  所以不把文案放到 `PreferenceOption` 上。
//

import SwiftUI

struct PreferencePickerRow<Option: PreferenceOption>: View {
    let badge: SettingsBadge
    let title: String
    /// 订阅这个选择器：改档位时本行要重画（当前取值与选中勾）。
    /// 不能写成普通的 `let`——那样只有祖先视图碰巧重算时才刷新（「改了设置不生效」的经典成因）。
    @ObservedObject var selector: EnumPreference<Option>
    /// 档位文案。
    let label: (Option) -> String
    /// 档位右侧的补充说明（数值 + 单位）；返回 nil 就不画。
    var detail: (Option) -> String? = { _ in nil }
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。带默认值的参数放最后，
    /// 调用点才能把它写在实参表末尾。
    var showsSeparator: Bool = true

    private var currentValue: String {
        guard let detailText = detail(selector.option) else { return label(selector.option) }
        return "\(label(selector.option)) · \(detailText)"
    }

    var body: some View {
        SettingsPickerRow(
            badge: badge,
            title: title,
            value: currentValue,
            isExpanded: selector.isPickerExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起上一个展开块
                // （面板高度只按单个展开核对，见 `PickerExpansion`）。
                withAnimation(SettingsMotion.expand) {
                    selector.toggleExpansion()
                }
            }
        ) {
            ForEach(Array(Option.allCases), id: \.self) { option in
                SettingsOptionRow(
                    label: label(option),
                    detail: detail(option),
                    isSelected: selector.option == option
                ) {
                    selector.select(option)
                    collapseAfterDelay()
                }
            }
        }
    }

    /// 选择后短暂延迟再收起，让用户看到选中态的变化。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(SettingsMotion.expand) {
                selector.isPickerExpanded = false
            }
        }
    }
}
