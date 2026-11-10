//
//  AgentConfigMerger.swift
//  AgentIsland
//
//  「配置文件型」Agent 的合并与摘除 —— 本文件是 `AgentConfigMerger` 的**主文件**：JSON 事件表
//  （claude / nested / flat / traeIDE / copilot）、Codex 的 `[features] hooks` 开关、Cline 的
//  每事件可执行文件，以及各格式**共用**的行 / 标量工具。
//
//  按格式族拆出的行手术在邻近的扩展文件里（`PBXFileSystemSynchronizedRootGroup` 自动收录）：
//    - `AgentConfigMerger+Kimi.swift`      Kimi 的 TOML 数组表（`[[hooks]]`）
//    - `AgentConfigMerger+TraeCLI.swift`   TraeCli 的 YAML 托管块
//    - `AgentConfigMerger+Hermes.swift`    Hermes 的 YAML `hooks:` 映射（每事件一行内联条目）
//
//  这里全是**纯函数**：只吃字符串与字典、只吐字符串与字典，不碰文件系统、不看时钟，
//  于是「安装写进去什么」「卸载能不能把别人的内容原样留下」都能在临时目录里逐字节验证。
//  落点解析、存在性闸门、备份与原子写入在 `AgentConfigInstaller`。
//
//  安全口径（与 `HookSettingsMerger` 同款）：读不懂的 JSON 一律**不可写**；摘除只摘含本
//  应用脚本路径的条目（判据 `HookInstaller.isOwnHookCommand`）；某个事件被摘空就删掉该
//  事件键，事件表全空就删掉顶层键 —— 不给用户留 `"hooks": {}` 这样的空壳。
//
//  两种写入口径（别混）：JSON 事件表是**整体重写**（落盘用 `.prettyPrinted + .sortedKeys`，
//  键序与空白会变、内容不变）；kimi / traecli / hermes / cline 是**行手术**（注释、键序、
//  行尾风格与尾部空白都原样保留），所以「卸载后逐字节还原」只对后几种成立。
//
//  形状的事实来源是 CodeIsland 的 `ConfigInstaller`（同生态里已支持这些工具的刘海应用），
//  每个写入器都注明了对应的行号，便于日后按上游变化复核。
//

import Foundation

nonisolated enum AgentConfigMerger {
    // MARK: - 判定

    /// 一个条目里所有可能承载命令的字段。
    ///
    /// 各格式把命令放在不同键上（`command` / `bash` / 内层 `hooks[].command`），
    /// 「这条是不是我们写的」只认命令文本，因此先把候选全取出来。
    static func commandStrings(in entry: [String: Any]) -> [String] {
        var commands: [String] = []
        if let command = entry["command"] as? String { commands.append(command) }
        if let bash = entry["bash"] as? String { commands.append(bash) }
        if let hooks = entry["hooks"] as? [[String: Any]] {
            commands.append(contentsOf: hooks.compactMap { $0["command"] as? String })
        }
        return commands
    }

    /// 条目是否由本应用写入（新旧脚本名都算，见 `HookInstaller.isOwnHookCommand`）。
    static func entryContainsOwnCommand(_ entry: [String: Any]) -> Bool {
        commandStrings(in: entry).contains(where: HookInstaller.isOwnHookCommand)
    }

    // MARK: - JSON 事件表

    /// 事件表格式的条目形状。
    ///
    /// 事实来源：CodeIsland `installExternalHooks` 的 `switch cli.format`
    /// （ConfigInstaller.swift:1544-1569：claude 1545 / nested 1549 / flat 1554 /
    /// traeIDE 1556 / traecli 1563 / copilot 1566）。
    ///
    /// `timeout` 逐字写 `AgentHookEvent.timeout`：Gemini 的那几个事件本身就按毫秒声明
    /// （见 `AgentHookSpec.timeoutsInMilliseconds`），不做秒→毫秒换算 —— 换算会把
    /// 86400000 变成 24 小时。`.flat` 的条目没有超时键（上游形状如此）。
    /// `.hermes` 也不是事件表：它的 `hooks:` 是「事件名 → 条目列表」的**映射**，由
    /// `AgentConfigInstaller.writeHermesTable` 走 YAML 行手术（见 `mergingHermesHooks`）。
    static func eventTableEntry(
        format: AgentHookFormat,
        command: String,
        timeout: Int
    ) -> [String: Any]? {
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        switch format {
        case .claude:
            return ["matcher": "*", "hooks": [handler]]
        case .nested:
            return ["hooks": [handler]]
        case .flat:
            return ["command": command]
        case .traeIDE:
            return ["matcher": "*", "loop_limit": 5, "hooks": [handler]]
        case .copilot:
            return ["type": "command", "bash": command, "timeoutSec": timeout]
        case .kimi, .traecli, .cline, .hermes:
            return nil
        }
    }

    /// 摘掉本应用留在事件表里的条目。
    ///
    /// 遍历**所有**事件键（不只本次要注册的那几个）：旧版本注册过的事件可能已被工具废弃，
    /// 留在配置里会被判为非法键。某个事件的条目被摘空就删掉该事件键；整张表空了就删掉
    /// 顶层键。
    static func strippingOwnEntries(from root: [String: Any], configKey: String) -> [String: Any] {
        guard let table = root[configKey] as? [String: Any] else { return root }

        var cleaned: [String: Any] = [:]
        for (event, value) in table {
            guard let entries = value as? [[String: Any]] else {
                cleaned[event] = value
                continue
            }
            let kept = entries.filter { !entryContainsOwnCommand($0) }
            if !kept.isEmpty { cleaned[event] = kept }
        }

        var result = root
        if cleaned.isEmpty {
            result.removeValue(forKey: configKey)
        } else {
            result[configKey] = cleaned
        }
        return result
    }

    /// 把本次要注册的事件条目补进去；同名事件已有别人的条目时追加在其后。
    static func appendingOwnEntries(
        _ entries: [(event: String, entry: [String: Any])],
        to root: [String: Any],
        configKey: String
    ) -> [String: Any] {
        var table = root[configKey] as? [String: Any] ?? [:]
        for (event, entry) in entries {
            var existing = table[event] as? [[String: Any]] ?? []
            existing.append(entry)
            table[event] = existing
        }
        var result = root
        result[configKey] = table
        return result
    }

    /// 该 Agent 的全部事件是否都能在事件表里找到指向本应用脚本的条目。
    static func containsAllOwnEvents(
        _ events: [String],
        in root: [String: Any],
        configKey: String
    ) -> Bool {
        guard let table = root[configKey] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let entries = table[event] as? [[String: Any]] else { return false }
            return entries.contains(where: entryContainsOwnCommand)
        }
    }

    /// 事件表里是否至少有本应用的一条条目（`installedFiles` 判定「这个文件真的是我们写的」）。
    static func containsAnyOwnEntry(in root: [String: Any], configKey: String) -> Bool {
        guard let table = root[configKey] as? [String: Any] else { return false }
        return table.values.contains { value in
            (value as? [[String: Any]])?.contains(where: entryContainsOwnCommand) ?? false
        }
    }

    // MARK: - Codex（`[features] hooks`）

    /// 在 TOML 文本的 `[features]` 段里把 `hooks` 设为 true。
    ///
    /// 返回 `nil` 表示无需改动（已经是 `true`），否则返回要写回的新文本。
    /// 事实来源：CodeIsland `enableCodexHooksConfig`（ConfigInstaller.swift:2491-2547）；
    /// 唯一差别是它用整文件的 `hooks = …` 正则，会被别的表里的同名键误导，这里只认
    /// `[features]` 段内的那个键。
    static func enablingCodexHooks(in contents: String) -> String? {
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "[features]\nhooks = true\n"
        }

        let lines = contents.components(separatedBy: "\n")
        guard let featuresIndex = lines.firstIndex(where: { isTomlTable($0, named: "features") })
        else {
            var appended = lines
            if let last = appended.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                appended.append("")
            }
            appended.append("[features]")
            appended.append("hooks = true")
            return appended.joined(separator: "\n")
        }

        var updated = lines
        let sectionEnd = nextTomlTableIndex(in: lines, after: featuresIndex)
        if let hooksIndex = ((featuresIndex + 1)..<sectionEnd)
            .first(where: { isTomlKey(lines[$0], named: "hooks") })
        {
            guard !isTomlBooleanTrue(lines[hooksIndex]) else { return nil }
            let comment = trailingComment(of: lines[hooksIndex])
            updated[hooksIndex] = "hooks = true" + (comment.map { " \($0)" } ?? "")
            return updated.joined(separator: "\n")
        }

        updated.insert("hooks = true", at: featuresIndex + 1)
        return updated.joined(separator: "\n")
    }

    // MARK: - Cline（每事件可执行文件）

    /// Cline 的每事件脚本：Cline 要求 hook **立刻**在 stdout 上给出合法 JSON，
    /// 所以先把 stdin 转给本应用（后台、不等结果），随即输出 `{"cancel":false}`。
    ///
    /// 事实来源：CodeIsland `clineHookScript` 字面量与 `installClineHooks`
    /// （ConfigInstaller.swift:2769-2774、2777-2790）。
    static func clineHookScript(event: String, command: String) -> String {
        """
        #!/bin/bash
        # AgentIsland \(event) hook —— 本文件由应用生成，重新安装会覆盖。
        INPUT=$(cat)
        printf '%s' "$INPUT" | \(command) >/dev/null 2>&1 &
        printf '{"cancel":false}'\n
        """
    }

    /// shell 单引号转义：脚本里要把命令原样拼成一行，路径可能含空格。
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 私有：YAML 标量（TraeCli / Hermes 共用）

    /// 简单 YAML 标量（单引号里的 `''` 是转义后的单引号）。
    static func yamlScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - 私有：TOML（Codex）

    /// 表头行是否为 `[name]`（允许行尾注释）。
    ///
    /// 行文本是**按 `\n` 切**出来的，CRLF 文件的行尾因此还挂着 `\r`；而 `\r` 属于
    /// `.newlines` 不属于 `.whitespaces`，用后者去修剪会认不出 `[features]\r` —— 安装侧
    /// 于是往里再补一个同名表（TOML 重复表 = 整个 config.toml 解析失败），卸载侧却认得出来
    /// 而 no-op。两侧判据必须同源：一律按 `whitespacesAndNewlines` 修剪。
    private static func isTomlTable(_ line: String, named name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return false }
        guard let closing = trimmed.firstIndex(of: "]") else { return false }
        guard String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing]) == name else {
            return false
        }
        let rest = trimmed[trimmed.index(after: closing)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || rest.hasPrefix("#")
    }

    /// 键行是否为 `name = …`（`name_x` 这类前缀相同的不算）。修剪口径同 `isTomlTable`。
    private static func isTomlKey(_ line: String, named name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(name) else { return false }
        let rest = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.hasPrefix("=")
    }

    /// 键行的值是否为 `true`（行尾注释不算）。修剪口径同 `isTomlTable`（CRLF 的值尾有 `\r`）。
    private static func isTomlBooleanTrue(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        var value = String(line[line.index(after: equals)...])
        if let hash = value.range(of: "#") {
            value = String(value[value.startIndex..<hash.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// 行尾注释（`#` 之后的部分，含 `#`）；没有则 nil。
    private static func trailingComment(of line: String) -> String? {
        guard let hash = line.range(of: "#") else { return nil }
        let comment = String(line[hash.lowerBound...]).trimmingCharacters(in: .whitespaces)
        return comment.isEmpty ? nil : comment
    }

    /// 下一个表头行的下标（`[features]` 段的终点）。
    private static func nextTomlTableIndex(in lines: [String], after start: Int) -> Int {
        var index = start + 1
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") { return index }
            index += 1
        }
        return lines.count
    }

    // MARK: - 私有：共用的行工具（Kimi / TraeCli / Hermes）

    /// 行是否为空行（只含空白）。
    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 最后一个非空行的下标；全是空行时返回 nil。
    static func lastNonBlankIndex(in lines: [String]) -> Int? {
        lines.lastIndex { !isBlank($0) }
    }

    /// 行内容（CRLF 文件里把行尾的 `\r` 摘掉再比较；别人的行尾我们不改）。
    static func lineBody(of line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// 行内容（去掉行尾 `\r` 与首尾空白）。
    static func trimmedBody(of line: String) -> String {
        lineBody(of: line).trimmingCharacters(in: .whitespaces)
    }

    /// 行首空格数。
    static func leadingSpaces(of line: String) -> Int {
        lineBody(of: line).prefix { $0 == " " }.count
    }
}
