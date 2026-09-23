//
//  ShortcutRecorder.swift
//  AgentIsland
//
//  录制一次按键的判定表：纯函数，控制器只负责把事件拆成入参与落库。
//

import Foundation

/// 录制模式下的按键判定。
///
/// 抽成纯函数是为了让「按 Esc 取消、裸 ⌫ 清空、可打印键必须带修饰键、全局组合必须带 ⌥/⌃、
/// 冲突拒收」这套规则可单测——它是录制功能里唯一容易写错的部分，而实机验证要靠点界面。
nonisolated enum ShortcutRecorder {
    /// 判定结果。
    enum Outcome: Equatable {
        /// Esc：退出录制，不改绑定。
        case cancel
        /// 裸 ⌫：清空这个动作的绑定（该动作在键盘上不可用）。
        case unbind
        /// 拒收，保持录制并给出原因。
        case reject(Rejection)
        /// 接受，写入绑定。
        case bind(KeyChord)
    }

    /// 拒收原因（视图负责翻成文案）。
    enum Rejection: Equatable {
        /// 不受支持的键（F 键、多媒体键等）。
        case unsupportedKey
        /// 可打印字符没带修饰键。
        case needsModifier
        /// 全局组合必须带 ⌥ 或 ⌃。
        case globalNeedsOptionOrControl
        /// 已被另一个动作占用。
        case conflicting(ShortcutAction)
    }

    /// Esc / ⌫ 的虚拟键码（与 `KeyChord` 的键码表同一套）。
    private static let escapeKeyCode: UInt16 = 53
    private static let deleteKeyCode: UInt16 = 51

    /// 判定一次按键。
    ///
    /// - Parameters:
    ///   - keyCode: 事件的虚拟键码。
    ///   - modifiers: 事件的修饰键（只含四个标准修饰键）。
    ///   - chord: `KeyChord.from(event)`；nil 表示这个键码不受支持。
    ///   - action: 正在录制的动作。
    ///   - conflict: 该组合已被哪个动作占用（没有则 nil）。
    static func outcome(
        keyCode: UInt16,
        modifiers: KeyChord.Modifier,
        chord: KeyChord?,
        action: ShortcutAction,
        conflict: ShortcutAction?
    ) -> Outcome {
        // Esc 取消：录制期间 Esc 一律是「退出录制」，不参与绑定（否则没法取消）。
        if keyCode == escapeKeyCode {
            return .cancel
        }
        // 裸 ⌫ 清空绑定：带修饰键的 ⌫（如 ⌘⌫）是正常组合，要能录进来。
        if keyCode == deleteKeyCode, modifiers.isEmpty {
            return .unbind
        }
        guard let chord else { return .reject(.unsupportedKey) }
        guard chord.isRecordable else { return .reject(.needsModifier) }
        if action.allowsGlobalBinding,
            modifiers.intersection([.option, .control]).isEmpty
        {
            // 全局热键会被系统吞掉：不加这条，把「唤出」绑成 ⌘C 就等于全系统失去复制。
            return .reject(.globalNeedsOptionOrControl)
        }
        if let conflict {
            return .reject(.conflicting(conflict))
        }
        return .bind(chord)
    }
}
