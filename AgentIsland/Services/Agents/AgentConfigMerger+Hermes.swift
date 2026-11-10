//
//  AgentConfigMerger+Hermes.swift
//  AgentIsland
//
//  Hermes `config.yaml` 的 YAML 行手术：`hooks:` 是「事件名 → 条目列表」的**映射**，条目既有
//  行内流式（`[{...}]`）也有块形式（`- command: …`），两种都要能增量补、能摘、能判定。
//
//  原先和另外三种格式一起住在 `AgentConfigMerger`（1251 行）里，按格式族拆出后逻辑逐字节
//  未改：映射层的定位、注释与尾部空行的保留、「结构保不住就拒绝写入」的判据都与原来一致。
//  这些 helper 只被本族的三个入口调用，因此仍是 `private`（同一文件可见）——本族无法再按
//  「入口 / helper」切成两个文件而不放宽十几个 private 符号。跨族共用的行工具
//  （`lineBody` / `trimmedBody` / `leadingSpaces` / `yamlScalar`）留在主文件。
//
//  事实来源：CodeIsland 同族的 Hermes 写入器（`ConfigInstaller.swift` 行手术实现）。
//

import Foundation

nonisolated extension AgentConfigMerger {
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
            hooksValue.isEmpty == false
        {
            guard emptyHermesInlineValues.contains(hooksValue) else {
                return .refused("hooks 的行内值是 \(hooksValue)，行手术保不住它")
            }
            lines[mapping.key] = replacingHermesValue(of: lines[mapping.key], with: "")
        }

        let keyIndent =
            mapping.flatMap { hermesMappingKeyIndent(in: lines, body: $0.body) }
            ?? defaultHermesKeyIndent
        let pad = String(repeating: " ", count: keyIndent)

        // YAML 单引号里 `'` 要写成 `''`（与 traecli 的托管项同一套写法）
        let quoted = command.replacingOccurrences(of: "'", with: "''")

        var newLines: [String] = []
        for event in events {
            let seconds = event.timeout > 0 ? event.timeout : timeout
            let entry = "{command: '\(quoted) --event \(event.name)', timeout: \(seconds)}"
            guard
                let index = hermesEventKeyIndex(
                    in: lines, name: event.name, body: mapping?.body, indent: keyIndent
                )
            else {
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
                        leadingSpaces(of: lines[key]) <= leadingSpaces(of: lines[index])
                    {
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
            if let stripped = strippingOwnEntries(
                fromInlineSequence: hermesInlineValue(of: lines[index]) ?? "")
            {
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
        if let hash = value.range(of: "#") {
            value = String(value[value.startIndex..<hash.lowerBound])
        }
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
        if let hash = value.range(of: "#") {
            value = String(value[value.startIndex..<hash.lowerBound])
        }
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
        return "["
            + kept.map { value[$0].trimmingCharacters(in: .whitespaces) }
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
        let keptSpaces = String(
            body[valueStart..<commentStart].reversed().prefix { $0 == " " }.reversed())
        let rewritten =
            String(body[..<valueStart])
            + (value.isEmpty ? "" : " \(value)")
            + keptSpaces
            + String(body[commentStart...])
        return line.hasSuffix("\r") ? rewritten + "\r" : rewritten
    }
}
