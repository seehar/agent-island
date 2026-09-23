//
//  ShortcutAction.swift
//  AgentIsland
//
//  可作为快捷键的动作目录：默认绑定、生效页面、作用域与输入框内是否生效。
//

import Foundation

/// 可作为快捷键的动作。
///
/// `rawValue` 同时是偏好域键名的后缀（`shortcut.<rawValue>`）——**改名等于丢用户绑定**，只能新增。
nonisolated enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    /// 唤出/收起面板。唯一允许注册成全局热键的动作（面板关着、应用不在前台也生效）。
    case summon
    /// 返回或收起：对话 → 列表、设置 → 列表、列表 → 收起面板。
    case dismiss
    /// 批准最靠前的待处理请求。
    case approve
    /// 拒绝最靠前的待处理请求（交互式提问按「跳过」处理）。
    case deny
    /// 选中项上移。
    case moveSelectionUp
    /// 选中项下移。
    case moveSelectionDown
    /// 打开选中会话的对话。
    case openChat
    /// 聚焦选中会话的终端。
    case focusTerminal
    /// 打开/关闭设置面板。
    case openSettings
    /// 打开/关闭用量统计页。
    case toggleStatistics
    /// 统计页重新统计。
    case rescan

    var id: String { rawValue }

    /// 动作生效的页面。解析器按它过滤：同一个按键可以在不同页面绑给不同动作。
    enum Page: Equatable, Sendable {
        /// 会话列表。
        case instances
        /// 某个会话的对话页。
        case chat
        /// 设置面板（非统计分组）。
        case settings
        /// 统计页（设置面板的一个分组，但不占分段位）。
        case statistics
    }

    /// 作用域：全局动作由 Carbon 注册热键，其余只在面板持有键盘焦点时生效。
    enum Scope: Equatable, Sendable {
        case global
        case panel
    }

    /// 该动作能生效的页面。
    ///
    /// 全局动作按「每一页都算」声明——它不经过本地监视（见 `ShortcutResolver`），但这样
    /// 绑定冲突检测才能看见它与面板内动作抢同一个组合（全局热键会先把组合吃掉）。
    var pages: Set<Page> {
        switch self {
        case .summon, .dismiss, .openSettings, .toggleStatistics:
            return [.instances, .chat, .settings, .statistics]
        case .approve, .deny:
            return [.instances, .chat]
        case .moveSelectionUp, .moveSelectionDown, .openChat, .focusTerminal:
            return [.instances]
        case .rescan:
            return [.statistics]
        }
    }

    var scope: Scope {
        self == .summon ? .global : .panel
    }

    /// 输入框聚焦时是否仍然生效。
    ///
    /// 只有「返回/收起」与「批准」为真：聊天输入框就在同一个面板里，其余按键必须让位给
    /// 文本编辑（`⌘⌫` 是删到行首、`↑/↓/↩` 是光标与发送）。
    var worksWhileTextEditing: Bool {
        switch self {
        case .dismiss, .approve: return true
        default: return false
        }
    }

    /// 是否允许录制成全局组合（只有唤出；全局组合还必须带 ⌥ 或 ⌃，见 `ShortcutController`）。
    var allowsGlobalBinding: Bool { scope == .global }

    /// 默认绑定。
    var defaultChord: KeyChord {
        switch self {
        case .summon: return KeyChord(keyCode: 34, modifiers: [.option, .command])
        case .dismiss: return KeyChord(keyCode: 53)
        case .approve: return KeyChord(keyCode: 36, modifiers: [.command])
        case .deny: return KeyChord(keyCode: 51, modifiers: [.command])
        case .moveSelectionUp: return KeyChord(keyCode: 126)
        case .moveSelectionDown: return KeyChord(keyCode: 125)
        case .openChat: return KeyChord(keyCode: 36)
        case .focusTerminal: return KeyChord(keyCode: 36, modifiers: [.shift])
        case .openSettings: return KeyChord(keyCode: 43, modifiers: [.command])
        case .toggleStatistics: return KeyChord(keyCode: 1, modifiers: [.command, .shift])
        case .rescan: return KeyChord(keyCode: 15, modifiers: [.command])
        }
    }

    /// 设置行左侧的图标（SF Symbol 名）。
    var symbolName: String {
        switch self {
        case .summon: return "command"
        case .dismiss: return "arrow.uturn.left"
        case .approve: return "checkmark"
        case .deny: return "xmark"
        case .moveSelectionUp: return "arrow.up"
        case .moveSelectionDown: return "arrow.down"
        case .openChat: return "bubble.left"
        case .focusTerminal: return "eye"
        case .openSettings: return "gearshape"
        case .toggleStatistics: return "chart.bar.xaxis"
        case .rescan: return "arrow.clockwise"
        }
    }
}
