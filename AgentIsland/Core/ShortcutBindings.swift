//
//  ShortcutBindings.swift
//  AgentIsland
//
//  快捷键绑定表：偏好域持久化 + 变更发布。
//

import Combine
import Foundation

/// 一个动作的绑定：某个组合，或显式「未绑定」（录制时按 ⌫ 清空）。
nonisolated enum ShortcutBinding: Codable, Equatable, Sendable {
    case chord(KeyChord)
    case unbound
}

/// 绑定表。
///
/// 形状与 `BehaviorPreferences` 里的 `BoolPreference` 一致（@MainActor ObservableObject +
/// 可注入 UserDefaults），键前缀 `shortcut.`。**键缺失 = 默认值**：`resetToDefaults()` 是
/// 删键而不是写入默认值，否则以后改默认值就落不到老用户身上。
@MainActor
final class ShortcutBindings: ObservableObject {
    /// 偏好域键前缀。
    static let keyPrefix = "shortcut."

    static let shared = ShortcutBindings()

    /// 当前绑定表：每个动作都有且只有一条（用户录制值或默认值）。
    @Published private(set) var bindings: [ShortcutAction: ShortcutBinding]

    private let defaults: UserDefaults

    /// 默认读写标准偏好域；测试传独立域，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(defaults: defaults)
    }

    /// 动作当前的组合；未绑定（用户按 ⌫ 清空过）返回 nil。
    func chord(for action: ShortcutAction) -> KeyChord? {
        guard case .chord(let chord) = bindings[action] else { return nil }
        return chord
    }

    /// 写入一个录制结果。
    func set(_ chord: KeyChord, for action: ShortcutAction) {
        store(.chord(chord), for: action)
    }

    /// 清空绑定：该动作在键盘上不可用。
    func clear(_ action: ShortcutAction) {
        store(.unbound, for: action)
    }

    /// 恢复全部默认（删掉所有 `shortcut.*` 键）。
    func resetToDefaults() {
        for action in ShortcutAction.allCases {
            defaults.removeObject(forKey: Self.key(for: action))
        }
        bindings = Self.load(defaults: defaults)
    }

    /// 与 `chord` 相同、且生效页面相交的另一个动作；没有冲突返回 nil。
    ///
    /// 页面不相交时允许共存：「重新统计」只在统计页、「打开对话」只在列表页，绑同一个
    /// 按键互不影响。全局动作按「每页都算」声明（见 `ShortcutAction.pages`），因此它与
    /// 面板内动作抢同一个组合也算冲突——Carbon 热键会先把组合吃掉。
    ///
    /// 返回的是 `allCases` 声明顺序里第一个冲突项：与解析器的优先级一致，提示里说的那个
    /// 动作就是实际会赢的那个。
    func conflict(for chord: KeyChord, excluding action: ShortcutAction) -> ShortcutAction? {
        for other in ShortcutAction.allCases where other != action {
            guard case .chord(let otherChord) = bindings[other] else { continue }
            if otherChord == chord, !other.pages.isDisjoint(with: action.pages) { return other }
        }
        return nil
    }

    // MARK: - 读写

    private static func key(for action: ShortcutAction) -> String {
        keyPrefix + action.rawValue
    }

    private func store(_ binding: ShortcutBinding, for action: ShortcutAction) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: Self.key(for: action))
        bindings[action] = binding
    }

    /// 读全表：缺键 / 解不出来（旧版本写坏的值、已删除的动作）一律回默认值。
    private static func load(defaults: UserDefaults) -> [ShortcutAction: ShortcutBinding] {
        var result: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            if let data = defaults.data(forKey: key(for: action)),
                let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data)
            {
                result[action] = decoded
            } else {
                result[action] = .chord(action.defaultChord)
            }
        }
        return result
    }
}
