//
//  AnyCodable.swift
//  AgentIsland
//
//  JSON 值类型擦除包装：集成上报的 `tool_input` 是任意 JSON（字符串/数字/布尔/数组/字典），
//  各 Agent 的形状还不一样。它原先定义在 `Services/Hooks/HookSocketServer.swift` 里，
//  而使用方是 `Models/SessionPhase.swift`（`PermissionContext.toolInput`）——模型层因此
//  反过来依赖传输层。把这个类型放进 Models，依赖方向恢复成 Services → Models。
//

import Foundation

/// 擦除类型的 JSON 值包装，用于解码混合类型的 JSON 对象。
nonisolated struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }

    /// 文本值（只认 `String`）。
    ///
    /// 与 `scalarString` 分开是刻意的：审批摘要的取值逻辑一直只认字符串
    /// （数字键不该抢在真正的命令/路径前面被当成摘要），拍平工具入参时则要把
    /// 数字与布尔也变成字符串。两个语义混成一个会改变既有展示行为。
    var text: String? { value as? String }

    /// 标量值的字符串形态（`String` / `Int` / `Double` / `Bool`），其余返回 nil。
    var scalarString: String? {
        switch value {
        case let string as String: return string
        case let int as Int: return String(int)
        case let double as Double: return String(double)
        case let bool as Bool: return bool ? "true" : "false"
        default: return nil
        }
    }
}
