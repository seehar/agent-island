//
//  AgentConfigMerger.swift
//  AgentIsland
//
//  「配置文件型」Agent 的合并与摘除：JSON 事件表（claude / nested / flat / traeIDE /
//  copilot）、Kimi 的 TOML 数组表、TraeCli 的 YAML 托管块、Codex 的 `[features] hooks`
//  开关、Cline 的每事件可执行文件。
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
//  键序与空白会变、内容不变）；kimi / traecli / cline 是**行手术**（注释、键序、行尾风格与
//  尾部空白都原样保留），所以「卸载后逐字节还原」只对后三种成立。
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
        case .kimi, .traecli, .cline:
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

    // MARK: - Kimi（TOML 数组表）

    /// Kimi 要求 `matcher` 的只有工具事件，其余事件没有 matcher 概念。
    /// 事实来源：CodeIsland `installKimiHooks`（ConfigInstaller.swift:2581-2586）。
    private static let kimiMatcherEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
    ]

    /// 本应用注释掉的 legacy 标量 `hooks = …` 行的标记：卸载时按它复原。
    ///
    /// TOML 里 `hooks = …` 与 `[[hooks]]` 数组表互斥，两者并存会让 kimi 直接解析失败，
    /// 所以安装时先注释掉、卸载时再放回去，而不是把它删掉（那是用户的内容）。
    static let kimiLegacyScalarMarker = "# [AgentIsland] 与 TOML 数组表冲突，安装时注释、卸载时复原"

    /// 把托管块追加进 TOML 文本：先摘掉上次留下的托管块与注释行，再追加本次的块。
    ///
    /// 块是按**行**插在「正文」与「原文件尾部空白」之间的：用户文件结尾有没有换行、有几个
    /// 空行都逐字节留着（`removingKimiHooks` 摘的正是我们插入的那一段），否则卸载会把用户的
    /// 文件尾部改样 —— 装一次、卸一次必须回到原样。
    ///
    /// 事实来源：CodeIsland `installKimiHooks`（ConfigInstaller.swift:2554-2597）。
    static func mergingKimiHooks(
        into contents: String,
        hooks: [(event: String, command: String, timeout: Int)]
    ) -> String {
        let text = commentingLegacyKimiScalar(in: removingKimiHooks(from: contents))
        var lines = text.components(separatedBy: "\n")
        let blockLines = hooks
            .map { kimiBlock(event: $0.event, command: $0.command, timeout: $0.timeout) }
            .joined(separator: "\n\n")
            .components(separatedBy: "\n")

        if let bodyEnd = lastNonBlankIndex(in: lines) {
            // 分隔空行 + 托管块：这一段会被 `removingKimiHooks` 整段摘掉，不在其中留任何我们的痕迹
            lines.insert(contentsOf: [""] + blockLines, at: bodyEnd + 1)
        } else {
            lines.insert(contentsOf: blockLines, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// 摘掉托管区（一个分隔空行 + 全部 `[[hooks]]` 块），并复原本应用注释掉的 legacy 标量行。
    ///
    /// 用户的尾部空白、行尾风格、注释与键序一个字节都不动；没摘到任何东西（也没有我们留下的
    /// 标记）时**原样返回** —— 卸载不是一次格式化。
    static func removingKimiHooks(from contents: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        let hasMarker = lines.contains {
            $0.trimmingCharacters(in: .whitespaces) == kimiLegacyScalarMarker
        }
        let ranges = ownKimiBlockRanges(in: lines)
        guard !ranges.isEmpty || hasMarker else { return contents }

        var kept = lines
        if let region = ranges.first, let lastRegion = ranges.last {
            // 托管块前面那个空行是我们写的分隔行，一起摘掉；用户的尾部空白留在原地
            let lower = region.lowerBound
            let start = (lower > 0 && isBlank(lines[lower - 1])) ? lower - 1 : lower
            kept = Array(lines[0..<start]) + Array(lines[lastRegion.upperBound...])
        }
        return restoringKimiLegacyScalar(in: kept).joined(separator: "\n")
    }

    /// 每个事件是否都能在 TOML 里找到指向本应用脚本的块。
    static func containsAllKimiHooks(_ events: [String], in contents: String) -> Bool {
        events.allSatisfy { containsKimiHook(event: $0, in: contents) }
    }

    /// 某个事件是否存在指向本应用脚本的 `[[hooks]]` 块。
    static func containsKimiHook(event: String, in contents: String) -> Bool {
        kimiBlocks(in: contents).contains { block in
            guard containsOwnCommand(block) else { return false }
            return block.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("event = ") else { return false }
                return tomlStringValue(String(trimmed.dropFirst("event = ".count))) == event
            }
        }
    }

    /// 配置里是否至少有一块是本次写入的（`installedFiles` 用）。
    static func containsAnyKimiHook(in contents: String) -> Bool {
        kimiBlocks(in: contents).contains(where: containsOwnCommand)
    }

    // MARK: - TraeCli（YAML 行手术）

    /// 托管列表项的默认缩进（文件里已有列表项时沿用它的缩进，见 `traecliLayout`）。
    private static let defaultTraecliItemIndent = 2

    /// `hooks:` 行内写了这些值与「没写」等价：可以就地换成裸键，由托管块承载列表。
    private static let emptyTraecliInlineValues: Set<String> = ["[]", "{}", "null", "~"]

    /// TraeCli 行手术的结果。
    enum TraecliMerge {
        /// 合并后的新文本。
        case merged(String)
        /// 拒绝写入：这份文件的 `hooks:` 结构行手术保不住，`reason` 写进日志。
        case refused(String)
    }

    /// 把托管列表项合并进 `traecli.yaml`。
    ///
    /// **保不住就拒绝写入**（`.refused`）：写出「两种缩进混在同一个序列里」的 YAML 会直接
    /// 解析失败，那比这次没装上糟糕得多（用户看到的是「已安装」，工具却读不了配置）。
    ///
    /// 用行手术而不是 YAML 往返：用户文件里的注释与键序必须原样保留（本模块没有 YAML 依赖，
    /// 也不该为了装一条 hook 把用户的文件重新序列化一遍）。
    ///
    /// 事实来源：CodeIsland `renderManagedTraecliHooksText` + `trySurgicalMergeTraecliHooks`
    /// （ConfigInstaller.swift:1665-1680、2069-2115）。
    static func mergingTraecliHooks(
        into contents: String,
        command: String,
        timeout: Int,
        events: [String]
    ) -> TraecliMerge {
        let cleaned = removingTraecliHooks(from: contents)
        var lines = cleaned.components(separatedBy: "\n")

        let itemIndent: Int
        switch traecliLayout(in: lines) {
        case .absent:
            itemIndent = defaultTraecliItemIndent
        case .empty(let keyIndent):
            itemIndent = keyIndent + defaultTraecliItemIndent
        case .items(let indent):
            itemIndent = indent
        case .mapping:
            return .refused("hooks 下的内容是映射（不是列表），行手术保不住它")
        }

        let block = traecliBlock(
            command: command,
            timeout: timeout,
            events: events,
            itemIndent: itemIndent
        )

        if let hooksIndex = lines.firstIndex(where: { topLevelHooksValue(of: $0) != nil }) {
            let value = topLevelHooksValue(of: lines[hooksIndex]) ?? ""
            if !value.isEmpty {
                guard emptyTraecliInlineValues.contains(value) else {
                    return .refused("hooks 的行内值是 \(value)，行手术保不住它")
                }
                lines[hooksIndex] = "hooks:"
            }
            lines.insert(contentsOf: block, at: hooksIndex + 1)
        } else if let bodyEnd = lastNonBlankIndex(in: lines) {
            // 新建 hooks 键：插在正文之后、原尾部空白之前（用户尾部字节保持原样）
            lines.insert(contentsOf: [""] + ["hooks:"] + block, at: bodyEnd + 1)
        } else {
            lines.insert(contentsOf: ["hooks:"] + block, at: 0)
        }
        return .merged(lines.joined(separator: "\n"))
    }

    /// 摘掉含本应用脚本的托管列表项（只删那一项的行，别人的项、注释与键序都不动）。
    static func removingTraecliHooks(from contents: String) -> String {
        guard !contents.isEmpty else { return contents }
        let lines = contents.components(separatedBy: "\n")
        var kept: [String] = []
        var didRemove = false
        var index = 0

        while index < lines.count {
            guard isTraecliListItemStart(trimmedBody(of: lines[index])) else {
                kept.append(lines[index])
                index += 1
                continue
            }
            let end = traecliItemEnd(in: lines, from: index)
            if let command = traecliCommand(in: lines[index..<end]),
               HookInstaller.isOwnHookCommand(command) {
                didRemove = true
                index = end
                continue
            }
            kept.append(contentsOf: lines[index..<end])
            index = end
        }

        return didRemove ? kept.joined(separator: "\n") : contents
    }

    /// 文件里是否存在指向本应用脚本的托管列表项。
    static func containsTraecliHook(in contents: String) -> Bool {
        let lines = contents.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard isTraecliListItemStart(trimmedBody(of: lines[index])) else {
                index += 1
                continue
            }
            let end = traecliItemEnd(in: lines, from: index)
            if let command = traecliCommand(in: lines[index..<end]),
               HookInstaller.isOwnHookCommand(command) {
                return true
            }
            index = end
        }
        return false
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
        guard let featuresIndex = lines.firstIndex(where: { isTomlTable($0, named: "features") }) else {
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
            .first(where: { isTomlKey(lines[$0], named: "hooks") }) {
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

    // MARK: - 私有：JSON 事件表

    /// 取命令文本的判断入口（Kimi 的块、TOML 里都按命令文本认自己的条目）。
    private static func containsOwnCommand(_ lines: [String]) -> Bool {
        lines.contains { HookInstaller.isOwnHookCommand($0) }
    }

    // MARK: - 私有：Kimi

    /// 一个事件的 `[[hooks]]` 块（TOML 基本字符串里的反斜杠与引号要转义）。
    private static func kimiBlock(event: String, command: String, timeout: Int) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var lines = [
            "[[hooks]]",
            "event = \"\(event)\"",
            "command = \"\(escaped)\"",
            "timeout = \(timeout)",
        ]
        if kimiMatcherEvents.contains(event) {
            lines.append("matcher = \".*\"")
        }
        return lines.joined(separator: "\n")
    }

    /// 块体的一行：非空、且不是新的表头。块之间才有一个空行，块体内部没有。
    private static func isKimiBlockBody(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("[")
    }

    /// 从 `[[hooks]]` 行起、到块体结束（空行或下一个表头）为止。
    private static func kimiBlockEnd(in lines: [String], from start: Int) -> Int {
        var index = start + 1
        while index < lines.count, isKimiBlockBody(lines[index]) { index += 1 }
        return index
    }

    /// 本应用写入的 `[[hooks]]` 块的行区间。
    private static func ownKimiBlockRanges(in lines: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces) == "[[hooks]]" else {
                index += 1
                continue
            }
            let end = kimiBlockEnd(in: lines, from: index)
            if HookInstaller.isOwnHookCommand(lines[index..<end].joined(separator: "\n")) {
                ranges.append(index..<end)
            }
            index = end
        }
        return ranges
    }

    /// 把文本切成 `[[hooks]]` 块（表头行含在内）。
    private static func kimiBlocks(in contents: String) -> [[String]] {
        let lines = contents.components(separatedBy: "\n")
        var blocks: [[String]] = []
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces) == "[[hooks]]" else {
                index += 1
                continue
            }
            let end = kimiBlockEnd(in: lines, from: index)
            blocks.append(Array(lines[index..<end]))
            index = end
        }
        return blocks
    }

    /// 把 legacy 标量 `hooks = …` 注释掉。
    ///
    /// 只在**第一个表头之前**动手：TOML 要求根键写在首个表头之前，表内的同名键既不会与
    /// `[[hooks]]` 冲突，也不该被我们改（用「行首无缩进」判根级在 TOML 里是错的 —— 表内键
    /// 同样在列 0）。
    private static func commentingLegacyKimiScalar(in contents: String) -> String {
        var seenTableHeader = false
        return contents.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                seenTableHeader = true
                return line
            }
            guard !seenTableHeader, leadingSpaces(of: line) == 0,
                  trimmed.hasPrefix("hooks =") else { return line }
            return "\(kimiLegacyScalarMarker)\n# \(line)"
        }.joined(separator: "\n")
    }

    /// 复原本应用注释掉的 legacy 标量行（只认紧跟标记行、且内容确实是一行根级 `hooks = …` 的）。
    private static func restoringKimiLegacyScalar(in lines: [String]) -> [String] {
        var restored: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == kimiLegacyScalarMarker,
               index + 1 < lines.count {
                let next = lines[index + 1]
                let content = next.hasPrefix("# ") ? String(next.dropFirst(2)) : ""
                if !content.isEmpty, leadingSpaces(of: content) == 0,
                   content.trimmingCharacters(in: .whitespaces).hasPrefix("hooks =") {
                    restored.append(content)
                    index += 2
                    continue
                }
            }
            restored.append(line)
            index += 1
        }
        return restored
    }

    private static func tomlStringValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // MARK: - 私有：TraeCli

    /// 托管列表项的行（`matchers` 列出全部事件，超时取事件表里的最大值）。
    private static func traecliBlock(
        command: String,
        timeout: Int,
        events: [String],
        itemIndent: Int
    ) -> [String] {
        let pad = String(repeating: " ", count: itemIndent)
        let childPad = pad + "  "
        let escaped = command.replacingOccurrences(of: "'", with: "''")
        var lines = [
            "\(pad)- type: command",
            "\(childPad)command: '\(escaped)'",
            "\(childPad)timeout: '\(timeout)s'",
            "\(childPad)matchers:",
        ]
        lines.append(contentsOf: events.map { "\(childPad)  - event: \($0)" })
        return lines
    }

    /// YAML 列表项起始行：`- type: command`（允许行尾注释）。
    private static func isTraecliListItemStart(_ trimmed: String) -> Bool {
        let prefix = "- type: command"
        guard trimmed.hasPrefix(prefix) else { return false }
        let rest = trimmed.dropFirst(prefix.count)
        guard let next = rest.first else { return true }
        return next == " " || next == "\t" || next == "#"
    }

    /// 一个列表项覆盖的行区间：到「更浅的非空行」或「空行」为止（空行不属于该项，
    /// 留下来才能保证卸载后逐字节还原）。
    private static func traecliItemEnd(in lines: [String], from start: Int) -> Int {
        let indent = leadingSpaces(of: lines[start])
        var index = start + 1
        while index < lines.count {
            let trimmed = trimmedBody(of: lines[index])
            if trimmed.isEmpty { break }
            let nextIndent = leadingSpaces(of: lines[index])
            if nextIndent < indent { break }
            if nextIndent == indent, trimmed.hasPrefix("- ") { break }
            index += 1
        }
        return index
    }

    /// 项里的 `command:` 值（YAML 单/双引号都按自己那套还原）。
    private static func traecliCommand(in lines: ArraySlice<String>) -> String? {
        for line in lines {
            let trimmed = trimmedBody(of: line)
            guard trimmed.hasPrefix("command:") else { continue }
            return yamlScalar(String(trimmed.dropFirst("command:".count)))
        }
        return nil
    }

    /// `hooks:` 下的结构：决定托管项能落在哪个缩进（或根本不能写）。
    private enum TraecliLayout {
        /// 文件里没有 `hooks:` 键。
        case absent
        /// `hooks:` 下什么都没有：按「键缩进 + 2」写（YAML 的标准写法，一定合法）。
        case empty(keyIndent: Int)
        /// `hooks:` 下已有块序列：沿用它的缩进。
        case items(indent: Int)
        /// `hooks:` 下的内容不是序列（是映射）。
        case mapping
    }

    /// 探测 `hooks:` 下的结构。
    ///
    /// 列表项的缩进必须**沿用文件自己的写法**：YAML 允许 `- type: …` 与 `hooks:` 同列
    /// （列 0，最常见写法），也允许缩进；同一个序列里混两种缩进会直接解析失败
    /// （PyYAML / Psych 都报错），写出去就等于把用户的配置写坏。
    private static func traecliLayout(in lines: [String]) -> TraecliLayout {
        guard let hooksIndex = lines.firstIndex(where: { topLevelHooksValue(of: $0) != nil }) else {
            return .absent
        }
        let hooksIndent = leadingSpaces(of: lines[hooksIndex])
        var index = hooksIndex + 1
        while index < lines.count {
            let trimmed = trimmedBody(of: lines[index])
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            let indent = leadingSpaces(of: lines[index])
            if trimmed.hasPrefix("- "), indent >= hooksIndent { return .items(indent: indent) }
            if indent <= hooksIndent { return .empty(keyIndent: hooksIndent) }
            return .mapping
        }
        return .empty(keyIndent: hooksIndent)
    }

    /// 顶层 `hooks:` 行冒号后的值（去掉行尾注释）；不是顶层 hooks 键时返回 nil。
    private static func topLevelHooksValue(of line: String) -> String? {
        let body = lineBody(of: line)
        guard body == body.trimmingCharacters(in: .whitespaces) else { return nil }
        guard body.hasPrefix("hooks:") else { return nil }
        var value = String(body.dropFirst("hooks:".count))
        if let hash = value.range(of: "#") { value = String(value[value.startIndex..<hash.lowerBound]) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// 简单 YAML 标量（单引号里的 `''` 是转义后的单引号）。
    private static func yamlScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - 私有：TOML / 行工具

    /// 表头行是否为 `[name]`（允许行尾注释）。
    private static func isTomlTable(_ line: String, named name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return false }
        guard let closing = trimmed.firstIndex(of: "]") else { return false }
        guard String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing]) == name else {
            return false
        }
        let rest = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.hasPrefix("#")
    }

    /// 键行是否为 `name = …`（`name_x` 这类前缀相同的不算）。
    private static func isTomlKey(_ line: String, named name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(name) else { return false }
        let rest = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
    }

    /// 键行的值是否为 `true`（行尾注释不算）。
    private static func isTomlBooleanTrue(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        var value = String(line[line.index(after: equals)...])
        if let hash = value.range(of: "#") { value = String(value[value.startIndex..<hash.lowerBound]) }
        return value.trimmingCharacters(in: .whitespaces) == "true"
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

    /// 行是否为空行（只含空白）。
    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 最后一个非空行的下标；全是空行时返回 nil。
    private static func lastNonBlankIndex(in lines: [String]) -> Int? {
        lines.lastIndex { !isBlank($0) }
    }

    /// 行内容（CRLF 文件里把行尾的 `\r` 摘掉再比较；别人的行尾我们不改）。
    private static func lineBody(of line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// 行内容（去掉行尾 `\r` 与首尾空白）。
    private static func trimmedBody(of line: String) -> String {
        lineBody(of: line).trimmingCharacters(in: .whitespaces)
    }

    /// 行首空格数。
    private static func leadingSpaces(of line: String) -> Int {
        lineBody(of: line).prefix { $0 == " " }.count
    }
}
