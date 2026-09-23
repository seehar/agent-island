//
//  KeyChord.swift
//  AgentIsland
//
//  一个按键组合（虚拟键码 + 修饰键）：快捷键的匹配与持久化单位。
//

import AppKit
import Carbon.HIToolbox

/// 一个按键组合。
///
/// 键码是**物理位置码**（与 `NSEvent.keyCode`、Carbon 同一套），因此与键盘布局无关；
/// 展示字形按 ANSI 主键区解析（非 ANSI 布局下字母可能显示成相邻键，这是已知取舍——
/// 存储与匹配都不看布局，只有显示受它影响）。存储用 JSON（⌥⌘I = `{"keyCode":34,"modifiers":3}`）。
nonisolated struct KeyChord: Codable, Equatable, Hashable, Sendable {
    /// 修饰键集合。只有四个标准修饰键参与匹配：capsLock / fn / numericPad 一律忽略，
    /// 否则打开大写锁定就会让所有快捷键失效。
    nonisolated struct Modifier: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int

        static let command = Modifier(rawValue: 1 << 0)
        static let option = Modifier(rawValue: 1 << 1)
        static let control = Modifier(rawValue: 1 << 2)
        static let shift = Modifier(rawValue: 1 << 3)

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// 从事件取参与的修饰键。
        init(_ flags: NSEvent.ModifierFlags) {
            var modifiers: Modifier = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            self = modifiers
        }

        /// 展示前缀，顺序固定 ⌃⌥⇧⌘（与系统「键盘快捷键」面板一致）。
        var displayPrefix: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }

        /// Carbon 注册用的位组合（直接引用 Carbon 的常量，不写魔数）。
        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            return flags
        }

        // 存储成裸整数而不是 `{"rawValue":3}`：绑定表在偏好域里要能一眼读懂。
        init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let keyCode: UInt16
    let modifiers: Modifier

    init(keyCode: UInt16, modifiers: Modifier = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 从事件取组合；不受支持的键码（F 键、多媒体键、数字小键盘等）返回 nil。
    static func from(_ event: NSEvent) -> KeyChord? {
        guard isSupportedKeyCode(event.keyCode) else { return nil }
        return KeyChord(keyCode: event.keyCode, modifiers: Modifier(event.modifierFlags))
    }

    /// 是否可录制成绑定：可打印字符必须带修饰键。
    ///
    /// 面板持有键盘焦点时，聊天输入框就在同一个面板里——一个裸字母会吃掉那里的打字，
    /// 因此这类组合一律拒收（⎋ / ↩ / ↑ 这些非可打印键不受限制）。
    var isRecordable: Bool {
        if modifiers.isEmpty, Self.printableLabels[keyCode] != nil { return false }
        return true
    }

    /// 展示串：修饰键前缀 + 主键字形。
    var displayLabel: String {
        let key = Self.specialLabels[keyCode] ?? Self.printableLabels[keyCode] ?? "?"
        return modifiers.displayPrefix + key
    }

    // MARK: - 键码表

    /// 特殊键的字形（与系统「键盘快捷键」面板同一套符号）。
    private static let specialLabels: [UInt16: String] = [
        53: "⎋", 36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// ANSI 主键区的可打印键（键码 → 展示字符）。标点与数字小键盘不收录——它们本来就
    /// 不被支持，录不进来也就不会显示错。
    private static let printableLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// 受支持的键码 = 特殊键或可打印键。
    private static func isSupportedKeyCode(_ keyCode: UInt16) -> Bool {
        specialLabels[keyCode] != nil || printableLabels[keyCode] != nil
    }
}
