//
//  ShortcutResolver.swift
//  AgentIsland
//
//  按键 → 动作的纯决策核心：不含任何 AppKit 状态，便于单测。
//

import Foundation

/// 一次按键所处的上下文。
nonisolated struct ShortcutContext: Equatable, Sendable {
    /// 当前页面。
    var page: ShortcutAction.Page
    /// 面板里是否有文本编辑（`firstResponder is NSTextView`）。
    var isTextEditing: Bool

    init(page: ShortcutAction.Page, isTextEditing: Bool = false) {
        self.page = page
        self.isTextEditing = isTextEditing
    }
}

/// 按键解析：把「按键 + 上下文」映射到动作。
nonisolated enum ShortcutResolver {
    /// 解析一个按键组合。
    ///
    /// 返回 nil 表示**不消费**这个按键（交给界面与菜单）。规则按顺序：
    /// 1. 只考虑面板内作用域、且生效页面包含当前页面的动作（全局动作由 Carbon 负责，
    ///    这里永不匹配——否则同一次按键会被处理两遍）。
    /// 2. 输入框聚焦时只放行 `worksWhileTextEditing` 的动作（返回/收起、批准）：聊天输入框
    ///    就在同一个面板里，`⌘⌫`、`↑/↓`、`↩` 必须让位给文本编辑。
    /// 3. 同一按键被多个动作绑定时（旧版本遗留的冲突数据），取 `allCases` 声明顺序第一个。
    /// 4. 未绑定（`.unbound`）的动作永不匹配。
    static func action(
        for chord: KeyChord,
        bindings: [ShortcutAction: ShortcutBinding],
        context: ShortcutContext
    ) -> ShortcutAction? {
        for action in ShortcutAction.allCases where action.scope == .panel {
            guard action.pages.contains(context.page) else { continue }
            guard case .chord(let bound) = bindings[action], bound == chord else { continue }
            if context.isTextEditing, !action.worksWhileTextEditing { continue }
            return action
        }
        return nil
    }
}

/// 键盘动作作用到哪一行会话。
nonisolated enum ShortcutTargeting {
    /// 打开对话这类动作的目标：显式选中优先；没有选中（或选中的会话已经不在列表里）时
    /// 取排序第一行——按键总要做点看得见的事。
    static func selectionTarget(in ordered: [SessionState], selected: SessionKey?) -> SessionState?
    {
        if let selected, let match = ordered.first(where: { $0.sessionKey == selected }) {
            return match
        }
        return ordered.first
    }

    /// 批准/拒绝的目标：选中的那一行若正在待批就用它；否则取排序最靠前的待批行
    /// （与列表里最靠上的那张待批卡片一致）；没有任何待批时返回 nil。
    static func approvalTarget(in ordered: [SessionState], selected: SessionKey?) -> SessionState? {
        if let selected, let match = ordered.first(where: { $0.sessionKey == selected }),
            match.phase.isWaitingForApproval
        {
            return match
        }
        return ordered.first { $0.phase.isWaitingForApproval }
    }
}
