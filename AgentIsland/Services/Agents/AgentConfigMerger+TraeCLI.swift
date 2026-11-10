//
//  AgentConfigMerger+TraeCLI.swift
//  AgentIsland
//
//  TraeCli `traecli.yaml` 的 YAML 行手术：把托管列表项写进 `hooks:`、摘掉含本应用脚本的项、
//  判定文件里是否已有我们的项。
//
//  原先和另外三种格式一起住在 `AgentConfigMerger`（1251 行）里，按格式族拆出后逻辑逐字节
//  未改：`hooks:` 的结构判定（缺失 / 空值 / 列表 / 映射）、列表项的行区间、引号还原都与
//  原来一致；「保不住结构就拒绝写入」的口径也没动。跨族共用的行工具留在主文件。
//
//  事实来源：CodeIsland `renderManagedTraecliHooksText` + `trySurgicalMergeTraecliHooks`
//  （ConfigInstaller.swift:1665-1680、2069-2115）。
//

import Foundation

nonisolated extension AgentConfigMerger {
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
                HookInstaller.isOwnHookCommand(command)
            {
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
                HookInstaller.isOwnHookCommand(command)
            {
                return true
            }
            index = end
        }
        return false
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
        if let hash = value.range(of: "#") {
            value = String(value[value.startIndex..<hash.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
