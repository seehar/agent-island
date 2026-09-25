//
//  AgentConfigMerger.swift
//  AgentIsland
//
//  「配置文件型」Agent 的合并与摘除：JSON 事件表（claude / nested / flat / traeIDE /
//  copilot）、Kimi 的 TOML 数组表、TraeCli 的 YAML 托管块、Hermes 的 YAML `hooks:` 映射
//  （每事件一行内联条目）、Codex 的 `[features] hooks` 开关、Cline 的每事件可执行文件。
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

    // MARK: - Hermes（YAML 行手术）

    /// Hermes 的顶层 `hooks:` 是**映射**（事件名 → 条目列表），新建映射键时的缩进。
    ///
    /// 缩进 2 是 YAML 里最常见的写法；文件里已有映射键时沿用它的缩进 —— 同一个映射里混
    /// 缩进会让整个文件解析失败（PyYAML / Psych 都报错）。
    private static let defaultHermesKeyIndent = 2

    /// `hooks:` 行内写了这些值与「没写」等价：可以就地换成裸键，由我们的映射键承载条目。
    private static let emptyHermesInlineValues: Set<String> = ["[]", "{}", "null", "~"]

    /// Hermes 行手术的结果。
    enum HermesMerge {
        /// 合并后的新文本。
        case merged(String)
        /// 拒绝写入：这份文件的 `hooks:` 结构行手术保不住，`reason` 写进日志。
        case refused(String)
    }

    /// 把托管条目合并进 Hermes 的 `config.yaml`（`$HERMES_HOME/config.yaml`，缺省 `~/.hermes`）。
    ///
    /// 形状（事实来源：CodeIsland `mergeHermesHooks`，ConfigInstaller.swift:2186-2224）：
    ///
    /// ```yaml
    /// hooks:
    ///   pre_tool_call: [{command: '<python> <脚本> --source hermes --event pre_tool_call', timeout: 5}]
    /// ```
    ///
    /// 每个事件写**一行内联流式序列**（而不是块序列）：行手术与幂等卸载都只需按行处理，
    /// 不必记账嵌套缩进，删掉一行就等于删掉一个条目。Hermes 自己按「`hooks[事件]` 是列表、
    /// 列表项是 `{command, timeout}` 映射」解析（`agent/shell_hooks.py` 的
    /// `_parse_hooks_block`），行内写法与块写法对它完全等价。
    ///
    /// 按 `hooks:` 在文件里的四种形态分别处理：
    ///   - 没有 `hooks:` 键：在正文之后、尾部空白之前新建 `hooks:` + 我们的事件行；
    ///   - `hooks:` 行内是空值（`[]` / `{}` / `null` / `~`）：就地换成裸键再插事件行；
    ///   - `hooks:` 下是映射：事件键不存在就补一行；键在、行内值为空就换掉那一行；键在、
    ///     行内是别人的非空列表就在同一行的 `]` 前追加我们那条（同一行的字符串编辑，安全）；
    ///   - `hooks:` 下是块序列（`- …`）或事件键下已有块子行：**拒绝写入**。
    ///
    /// **保不住就拒绝写入**（`.refused`）：块序列结构里按行删一条会留下孤立的续行
    /// （`timeout:` 之类），写出解析不了的 YAML —— 那比这次没装上糟糕得多（用户看到的是
    /// 「已安装」，Hermes 却读不了配置）。与 traecli 同一套纪律：本模块没有 YAML 依赖，
    /// 也不该为了装一条 hook 把用户的文件重新序列化一遍（注释与键序必须原样保留）。
    ///
    /// 运维事实（本机实测）：Hermes 的 shell hook 要用户先在 `~/.hermes/shell-hooks-allowlist.json`
    /// 里按 `(event, command)` **精确字符串**授权后才会执行；未授权时非 TTY 路径直接跳过，
    /// 表现为「配置里装好了、却收不到任何事件」。命令字符串变了（换脚本）就要重新授权一次。
    ///
    /// - Parameters:
    ///   - command: 命令本体（不含 `--event`；每条事件行由这里补上自己的事件名）。
    ///   - timeout: 条目里没声明正数超时时的兜底（Hermes 缺省 60、上限 300）。
    ///   - events: 要注册的事件（名称 + 该事件写进条目的超时，秒）。
    static func mergingHermesHooks(
        into contents: String,
        command: String,
        timeout: Int,
        events: [(name: String, timeout: Int)]
    ) -> HermesMerge {
        // 先摘掉上一版留下的条目：重复安装必须字节相同，卸载才能逐字节还原
        var lines = removingHermesHooks(from: contents).components(separatedBy: "\n")
        let mapping = hermesMappingRange(in: lines)

        if let refusal = hermesStructureRefusal(
            in: lines, mapping: mapping, events: events.map(\.name)
        ) {
            return .refused(refusal)
        }

        // `hooks:` 行内写着的空值（`[]` / `{}` / `null` / `~`）与「没写」等价：就地换成裸键，
        // 否则我们的映射键会挂在 `hooks: []` 后面（那种写法 Hermes 直接解析失败）。
        if let mapping, let hooksValue = hermesHooksValue(of: lines[mapping.key]),
           hooksValue.isEmpty == false {
            guard emptyHermesInlineValues.contains(hooksValue) else {
                return .refused("hooks 的行内值是 \(hooksValue)，行手术保不住它")
            }
            lines[mapping.key] = replacingHermesValue(of: lines[mapping.key], with: "")
        }

        let keyIndent = mapping.flatMap { hermesMappingKeyIndent(in: lines, body: $0.body) }
            ?? defaultHermesKeyIndent
        let pad = String(repeating: " ", count: keyIndent)

        // YAML 单引号里 `'` 要写成 `''`（与 traecli 的托管项同一套写法）
        let quoted = command.replacingOccurrences(of: "'", with: "''")

        var newLines: [String] = []
        for event in events {
            let seconds = event.timeout > 0 ? event.timeout : timeout
            let entry = "{command: '\(quoted) --event \(event.name)', timeout: \(seconds)}"
            guard let index = hermesEventKeyIndex(
                in: lines, name: event.name, body: mapping?.body, indent: keyIndent
            ) else {
                newLines.append("\(pad)\(event.name): [\(entry)]")
                continue
            }
            let line = lines[index]
            let value = hermesInlineValue(of: line) ?? ""
            if value.isEmpty || emptyHermesInlineValues.contains(value) {
                // 键在、条目空（裸键 / `[]` / `null`）：就地换成我们这一条
                lines[index] = replacingHermesValue(of: line, with: "[\(entry)]")
                continue
            }
            guard value.hasPrefix("["), value.hasSuffix("]") else {
                return .refused("hooks.\(event.name) 的行内值是 \(value)（既不是列表也不是空值），行手术保不住它")
            }
            guard let closing = inlineSequenceClosingIndex(of: line) else {
                return .refused("hooks.\(event.name) 的行内列表找不到结尾的 `]`，行手术保不住它")
            }
            // 已有别人的条目：只在这一行里追加我们那一条（同一行的字符串编辑，安全）
            lines[index].insert(contentsOf: ", \(entry)", at: closing)
        }

        guard newLines.isEmpty == false else { return .merged(lines.joined(separator: "\n")) }
        if let mapping {
            let at = hermesMappingInsertionIndex(in: lines, body: mapping.body) ?? mapping.key + 1
            lines.insert(contentsOf: newLines, at: at)
        } else if let bodyEnd = lastNonBlankIndex(in: lines) {
            // 新建 `hooks:` 键：插在正文之后、原尾部空白之前（用户尾部字节保持原样）
            lines.insert(contentsOf: ["hooks:"] + newLines, at: bodyEnd + 1)
        } else {
            lines.insert(contentsOf: ["hooks:"] + newLines, at: 0)
        }
        return .merged(lines.joined(separator: "\n"))
    }

    /// 摘掉 `hooks:` 映射里含本应用脚本的条目（行内形式与块形式都摘），并删掉因此变空的事件键。
    ///
    /// 只动含我们脚本的那一行：别人的条目内容、注释、键序、行尾风格与尾部空白都原样保留
    /// （同一行里多个条目之间多余的空白会被归一成 `, `）；没摘到任何东西时**原样返回** ——
    /// 卸载不是一次格式化。`hooks:` 键本身留着（行手术卸载后只剩它时，
    /// `AgentConfigInstaller.isEffectivelyEmpty` 视为「这个文件已无内容」）。
    static func removingHermesHooks(from contents: String) -> String {
        guard contents.isEmpty == false else { return contents }
        let lines = contents.components(separatedBy: "\n")
        guard let mapping = hermesMappingRange(in: lines) else { return contents }

        var dropped = Set<Int>()
        var rewrites: [Int: String] = [:]
        var keysWithDroppedChildren = Set<Int>()
        var didRemove = false
        var lastKeyIndex: Int?

        var index = mapping.body.lowerBound
        while index < mapping.body.upperBound {
            let trimmed = trimmedBody(of: lines[index])
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            if trimmed.hasPrefix("- ") {
                // 块形式的条目：整项一起摘（续行一定更深），别留下孤立的 `timeout:`
                let end = hermesItemEnd(in: lines, from: index)
                let itemCommand = blockItemCommand(in: lines[index..<end])
                if itemCommand.map(HookInstaller.isOwnHookCommand) == true {
                    dropped.formUnion(index..<end)
                    // 无缩进序列的 `- ` 与键行同缩进，因此用 <=（它是该键的子行）
                    if let key = lastKeyIndex,
                       leadingSpaces(of: lines[key]) <= leadingSpaces(of: lines[index]) {
                        keysWithDroppedChildren.insert(key)
                    }
                    didRemove = true
                }
                index = end
                continue
            }
            if hermesMappingKeyName(of: lines[index]) == nil {
                index += 1
                continue
            }
            lastKeyIndex = index
            if let stripped = strippingOwnEntries(fromInlineSequence: hermesInlineValue(of: lines[index]) ?? "") {
                didRemove = true
                if stripped.isEmpty {
                    dropped.insert(index)
                } else {
                    rewrites[index] = replacingHermesValue(of: lines[index], with: stripped)
                }
            }
            index += 1
        }

        guard didRemove else { return contents }

        // 块形式的事件键：子行全被我们摘掉时连它一起删（不留 `pre_tool_call:` 这样的空壳）
        for key in keysWithDroppedChildren where dropped.contains(key) == false {
            if hermesHasDeeperLines(in: lines, key: key, ignoring: dropped) == false {
                dropped.insert(key)
            }
        }

        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() where dropped.contains(index) == false {
            kept.append(rewrites[index] ?? line)
        }
        return kept.joined(separator: "\n")
    }

    /// 文件里是否存在指向本应用脚本的托管条目（`installedFiles` 与设置页的「已装」判据）。
    ///
    /// 判据是**行级**的：`hooks:` 映射里的非注释行里出现本应用脚本名（注释里写到它不算）。
    /// 真正摘除时比这里更严 —— 逐条核对 `command` 标量（见 `strippingOwnEntries`），
    /// 因此「这里为真、卸载却不动文件」是可能的（例如别人的条目在别的键里写了我们的路径）。
    static func containsHermesHook(in contents: String) -> Bool {
        let lines = contents.components(separatedBy: "\n")
        guard let mapping = hermesMappingRange(in: lines) else { return false }
        return mapping.body.contains { index in
            trimmedBody(of: lines[index]).hasPrefix("#") == false
                && HookInstaller.isOwnHookCommand(lines[index])
        }
    }

    // MARK: - 私有：Hermes

    /// 顶层 `hooks:` 行冒号后的行内值（去掉行尾注释）；不是顶层 hooks 键时返回 nil。
    ///
    /// 与 traecli 沿用的 `topLevelHooksValue` 是同一套判据，两处差别都是**为 Hermes 定的**：
    ///   - 键名必须**恰好**是 `hooks`：Hermes 自己的 config.yaml 里就有 `hooks_auto_accept:`
    ///     这类同前缀的顶层键（本机实测），把它当成 `hooks:` 会让我们往一个布尔值下面插事件行；
    ///   - 允许键后有空白：`hooks:   `（只有空白）也是「没有条目」的写法，而
    ///     `topLevelHooksValue` 的「行尾无空白」要求会把它判成没有这个键 —— 于是我们会再
    ///     追加一个 `hooks:`，重复的顶层键会让 Hermes 读不到我们的条目。
    private static func hermesHooksValue(of line: String) -> String? {
        let raw = lineBody(of: line)
        guard raw.hasPrefix(" ") == false, raw.hasPrefix("\t") == false else { return nil }
        let body = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        guard body[body.startIndex..<colon] == "hooks" else { return nil }
        var value = String(body[body.index(after: colon)...])
        if let hash = value.range(of: "#") { value = String(value[value.startIndex..<hash.lowerBound]) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// `hooks:` 映射覆盖的行：键行下标 + 键行之后的正文区间；没有顶层 `hooks:` 键时返回 nil。
    ///
    /// 空行与注释行不结束映射（YAML 里它们不属于任何键），因此终点是「第一个非空非注释、
    /// 且缩进回到顶层」的那一行之前的全部行。
    private static func hermesMappingRange(in lines: [String]) -> (key: Int, body: Range<Int>)? {
        guard let hooksIndex = lines.firstIndex(where: { hermesHooksValue(of: $0) != nil }) else {
            return nil
        }
        let hooksIndent = leadingSpaces(of: lines[hooksIndex])
        var end = hooksIndex + 1
        while end < lines.count {
            let trimmed = trimmedBody(of: lines[end])
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                end += 1
                continue
            }
            if leadingSpaces(of: lines[end]) <= hooksIndent { break }
            end += 1
        }
        return (key: hooksIndex, body: (hooksIndex + 1)..<end)
    }

    /// 映射键行的键名（`name: …` 的 `name`，引号写法按 YAML 还原）。
    ///
    /// 顶层行（没有缩进）、块序列条目、注释行都不是映射键；缩进更深的续行（`timeout: 5`）在
    /// 这里**也会**被当成键，调用方按缩进与键名自行辨别。
    private static func hermesMappingKeyName(of line: String) -> String? {
        let body = lineBody(of: line)
        guard body != body.trimmingCharacters(in: .whitespaces) else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") == false, trimmed.hasPrefix("#") == false else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : yamlScalar(name)
    }

    /// 键行冒号后的行内值（去掉行尾注释）；不是映射键行时返回 nil，裸键返回空串。
    private static func hermesInlineValue(of line: String) -> String? {
        guard hermesMappingKeyName(of: line) != nil else { return nil }
        let body = lineBody(of: line)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        var value = String(body[body.index(after: colon)...])
        if let hash = value.range(of: "#") { value = String(value[value.startIndex..<hash.lowerBound]) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// 映射层的缩进（沿用文件自己的写法）；没有映射键时返回 nil。
    ///
    /// 取**最小**缩进而不是第一个：`hooks:` 下还可能有它自己的嵌套子键（Hermes 的
    /// `output_spill` 就是），拿更深的那个当缩进会把我们的键写进别人的段里。
    private static func hermesMappingKeyIndent(in lines: [String], body: Range<Int>) -> Int? {
        body.compactMap { index in
            hermesMappingKeyName(of: lines[index]) == nil ? nil : leadingSpaces(of: lines[index])
        }.min()
    }

    /// 映射里某个事件键的行下标（键名逐字比较，且必须落在映射层那一层）。
    private static func hermesEventKeyIndex(
        in lines: [String],
        name: String,
        body: Range<Int>?,
        indent: Int
    ) -> Int? {
        guard let body else { return nil }
        return body.first { index in
            hermesMappingKeyName(of: lines[index]) == name
                && leadingSpaces(of: lines[index]) == indent
        }
    }

    /// 往映射里补新键的插入点：映射里最后一个键行之后（尾部空行与注释留在原处）。
    private static func hermesMappingInsertionIndex(in lines: [String], body: Range<Int>) -> Int? {
        body.last { index in
            let trimmed = trimmedBody(of: lines[index])
            return trimmed.isEmpty == false && trimmed.hasPrefix("#") == false
        }.map { $0 + 1 }
    }

    /// 块序列项覆盖的行区间：到「缩进不深于该项标记」或「空行」为止。
    ///
    /// 条目的续行（`timeout:` 之类）一定比 `- ` 更深；缩进回到同一层就是下一个兄弟（键行或
    /// 下一个条目）——空行也不属于这一项（留着它，卸载才能逐字节还原）。
    private static func hermesItemEnd(in lines: [String], from start: Int) -> Int {
        let itemIndent = leadingSpaces(of: lines[start])
        var index = start + 1
        while index < lines.count {
            if trimmedBody(of: lines[index]).isEmpty { break }
            if leadingSpaces(of: lines[index]) <= itemIndent { break }
            index += 1
        }
        return index
    }

    /// 键行之后是否还有更深的行（块形式的子行）；空行不算，`ignoring` 里的行也不算。
    private static func hermesHasDeeperLines(
        in lines: [String],
        key: Int,
        ignoring dropped: Set<Int> = []
    ) -> Bool {
        let keyIndent = leadingSpaces(of: lines[key])
        var index = key + 1
        while index < lines.count {
            let trimmed = trimmedBody(of: lines[index])
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if leadingSpaces(of: lines[index]) <= keyIndent { return false }
            if dropped.contains(index) == false { return true }
            index += 1
        }
        return false
    }

    /// 结构预检：这份文件的行手术保得住吗？返回拒绝理由，nil 表示可以写。
    ///
    /// 两种保不住的结构（都在 `hooks:` 映射里）：
    ///   - 块序列条目（`- …`）：`hooks:` 下只允许「事件名 → 条目列表」的映射，条目也必须是
    ///     行内列表；按行删一个块条目会留下孤立的续行（`timeout:` 之类），写出解析不了的 YAML；
    ///   - 我们要写的事件键下已有更深的行：替换那一行会把它的子行变成孤儿。
    private static func hermesStructureRefusal(
        in lines: [String],
        mapping: (key: Int, body: Range<Int>)?,
        events: [String]
    ) -> String? {
        guard let mapping else { return nil }
        // `hooks:` 的下一行若是块序列项（YAML 的「无缩进序列」写法：`- ` 与键行同缩进），
        // 那 `hooks:` 的值是序列而不是映射 —— Hermes 读不了，我们也插不进去。
        var next = mapping.key + 1
        while next < lines.count {
            let trimmed = trimmedBody(of: lines[next])
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                next += 1
                continue
            }
            if trimmed.hasPrefix("- ") {
                return "hooks 的值是块序列（\(trimmed)），行手术保不住它"
            }
            break
        }
        for index in mapping.body {
            let trimmed = trimmedBody(of: lines[index])
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- ") {
                return "hooks 下有块序列条目（\(trimmed)），行手术保不住它"
            }
            guard let name = hermesMappingKeyName(of: lines[index]), events.contains(name) else {
                continue
            }
            if hermesHasDeeperLines(in: lines, key: index) {
                return "hooks.\(name) 下已有块子行，行手术保不住它"
            }
        }
        return nil
    }

    /// 行内流式序列 `[a, b]` 里摘掉指向本应用脚本的条目。
    ///
    /// 返回 nil 表示「这不是流式序列，或里面没有我们的条目」（调用方原样保留这一行）；
    /// 返回空串表示整条序列都是我们的（调用方连键行一起删）。
    private static func strippingOwnEntries(fromInlineSequence value: String) -> String? {
        guard let elements = inlineSequenceElements(value) else { return nil }
        let kept = elements.filter { element in
            guard let command = inlineEntryCommand(String(value[element])) else { return true }
            return HookInstaller.isOwnHookCommand(command) == false
        }
        guard kept.count < elements.count else { return nil }
        guard kept.isEmpty == false else { return "" }
        return "[" + kept.map { value[$0].trimmingCharacters(in: .whitespaces) }
            .joined(separator: ", ") + "]"
    }

    /// 行内流式元素里的命令文本（`{command: '…', timeout: 5}` 的 `command` 标量）。
    ///
    /// 判「这条是不是我们写的」**只认命令文本**（与 traecli 的 `traecliCommand` 同一套判据）：
    /// 元素的其它键里出现脚本名不算我们的条目 —— 摘错一条就是删了用户的 hook。
    /// 不是映射（Hermes 只接受映射条目）或没有 `command` 键时返回 nil，调用方原样保留。
    private static func inlineEntryCommand(_ element: String) -> String? {
        let body = element.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return nil }
        for field in body.dropFirst().dropLast().components(separatedBy: ",") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command:") else { continue }
            return yamlScalar(String(trimmed.dropFirst("command:".count)))
        }
        return nil
    }

    /// 块序列项里的命令文本（`- command: '…'` 与 `- {command: '…'}` 两种写法）。
    private static func blockItemCommand(in lines: ArraySlice<String>) -> String? {
        for line in lines {
            var trimmed = trimmedBody(of: line)
            if trimmed.hasPrefix("- ") {
                trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("{") { return inlineEntryCommand(trimmed) }
            guard trimmed.hasPrefix("command:") else { continue }
            return yamlScalar(String(trimmed.dropFirst("command:".count)))
        }
        return nil
    }

    /// 行内流式序列 `[a, b]` 的元素文本区间（顶层逗号切分；引号与嵌套括号里的逗号不算）。
    private static func inlineSequenceElements(_ value: String) -> [Range<String.Index>]? {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        var ranges: [Range<String.Index>] = []
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        let elementStart = value.index(after: value.startIndex)
        let end = value.index(before: value.endIndex)

        var index = elementStart
        var start = elementStart
        while index < end {
            let character = value[index]
            if inSingleQuote {
                // `''` 是转义后的单引号：翻转两次，净效果仍是「在引号里」
                if character == "'" { inSingleQuote = false }
            } else if inDoubleQuote {
                if character == "\"" { inDoubleQuote = false }
            } else if character == "'" {
                inSingleQuote = true
            } else if character == "\"" {
                inDoubleQuote = true
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            } else if character == ",", depth == 0 {
                ranges.append(start..<index)
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        ranges.append(start..<end)
        return ranges.filter { value[$0].trimmingCharacters(in: .whitespaces).isEmpty == false }
    }

    /// 键行里行内序列的结尾 `]`（行尾注释之前的那个），用于在同一行里追加条目。
    private static func inlineSequenceClosingIndex(of line: String) -> String.Index? {
        let body = lineBody(of: line)
        let commentStart = body.range(of: "#")?.lowerBound ?? body.endIndex
        return body[..<commentStart].lastIndex(of: "]")
    }

    /// 键行换成新值：**只换值区间**（冒号之后、行尾注释之前），缩进、键名写法（含引号）、
    /// 注释之前的空白与 CRLF 行尾都逐字节保留 —— 「卸载后逐字节还原」不受这里影响。
    private static func replacingHermesValue(of line: String, with value: String) -> String {
        let body = lineBody(of: line)
        guard let colon = body.firstIndex(of: ":") else { return line }
        let valueStart = body.index(after: colon)
        let commentStart =
            body.range(of: "#", range: valueStart..<body.endIndex)?.lowerBound ?? body.endIndex
        // 注释前原有的空白留着（`]  # 注释` 那两个空格不是我们该动的）
        let keptSpaces = String(body[valueStart..<commentStart].reversed().prefix { $0 == " " }.reversed())
        let rewritten =
            String(body[..<valueStart])
            + (value.isEmpty ? "" : " \(value)")
            + keptSpaces
            + String(body[commentStart...])
        return line.hasSuffix("\r") ? rewritten + "\r" : rewritten
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
