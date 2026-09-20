//
//  HookSettingsMerger.swift
//  AgentIsland
//
//  写回 ~/.claude/settings.json 前需要动脑的三步：判断文件能不能安全改写、摘掉本应用
//  在旧版本里留下的 hook 条目、把当前该注册的事件补进去。这三步都是纯函数，抽出来
//  是为了能脱离文件系统与进程单测——这段逻辑过去会在「读不到／读不懂」时把配置退回
//  空字典后照样写回，等于一次启动就清空用户的整份 Claude Code 配置。
//

import Foundation

/// settings.json 的读回结果。
///
/// 「读不到」与「读不懂」必须与「文件不存在」分开：前者一律**不可写**，
/// 只有后者（或确认读到的是字典）才允许改写。
nonisolated enum HookSettingsLoad {
    /// 文件不存在：可以新建。
    case absent
    /// 已读到且顶层是字典：在它之上合并。
    case dictionary([String: Any])
    /// 文件存在但读不出来（权限、IO）。
    case unreadable
    /// 已读到但不是合法 JSON 对象，或顶层不是字典（顶层是数组、带注释等）。
    case malformed

    /// 不能安全写入的原因；nil 表示可以写。
    ///
    /// 文案是给日志用的自查信息，不出现在界面上（界面上「未安装」由集成状态表达）。
    var refusalReason: String? {
        switch self {
        case .absent, .dictionary: return nil
        case .unreadable: return "文件存在但读不到内容"
        case .malformed: return "内容不是合法的 JSON 对象"
        }
    }

    /// 可以安全写入时拿到的原始配置（不存在的文件按空配置处理）。
    var settings: [String: Any] {
        switch self {
        case .dictionary(let settings): return settings
        case .absent, .unreadable, .malformed: return [:]
        }
    }
}

nonisolated enum HookSettingsMerger {
    // MARK: - 读

    /// 判断 settings.json 能不能安全改写。
    ///
    /// - Parameters:
    ///   - data: 文件内容；`nil` 表示读取失败（`fileExists` 为 false 时也传 nil）。
    ///   - fileExists: 文件是否存在。
    static func load(data: Data?, fileExists: Bool) -> HookSettingsLoad {
        guard fileExists else { return .absent }
        guard let data else { return .unreadable }
        // 只有空白的文件等同「没有配置」，可以按新建处理
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard data.contains(where: { !whitespace.contains($0) }) else { return .absent }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else { return .malformed }
            return .dictionary(dictionary)
        } catch {
            return .malformed
        }
    }

    // MARK: - 改

    /// 摘掉本应用在所有事件上留下的 hook 条目。
    ///
    /// 要覆盖的场合比想的多：旧版本注册过的事件可能已经不存在于当前 Claude Code
    /// （留在配置里会被判为非法键），因此这里对**所有**事件都清一遍，而不只是清理
    /// 本次要注册的那几个。
    ///
    /// - Parameter isOwnCommand: 判定某个 hook 命令是否属于本应用（由调用方注入，
    ///   测试可以传桩函数）。
    static func strippingOwnHooks(
        from settings: [String: Any],
        isOwnCommand: (String) -> Bool
    ) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return settings }

        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                cleaned[event] = value
                continue
            }
            let kept = entries.compactMap { entry in
                removingOwnHooks(from: entry, isOwnCommand: isOwnCommand)
            }
            if !kept.isEmpty {
                cleaned[event] = kept
            }
        }

        var result = settings
        if cleaned.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = cleaned
        }
        return result
    }

    /// 把本次要注册的事件追加进去（同名事件追加在已有条目之后）。
    static func appending(
        hookEvents: [(event: String, entries: [[String: Any]])],
        to settings: [String: Any]
    ) -> [String: Any] {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, entries) in hookEvents {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + entries
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    // MARK: - 私有

    /// 摘掉单个 hook 条目里的本应用 hook；条目里没有别的 hook 时整条丢弃。
    private static func removingOwnHooks(
        from entry: [String: Any],
        isOwnCommand: (String) -> Bool
    ) -> [String: Any]? {
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }

        let kept = entryHooks.filter { hook in
            let command = hook["command"] as? String ?? ""
            return !isOwnCommand(command)
        }
        guard !kept.isEmpty else { return nil }

        var updated = entry
        updated["hooks"] = kept
        return updated
    }
}
