//
//  AgentConfigMerger+Kimi.swift
//  AgentIsland
//
//  Kimi 的 `config.toml` 行手术：往 `[[hooks]]` 数组表里补托管块、摘掉上次留下的托管块、
//  判定每个事件是否有指向本应用脚本的块。
//
//  原先和另外三种格式一起住在 `AgentConfigMerger`（1251 行）里，按格式族拆出后逻辑逐字节
//  未改：`[[hooks]]` 的分块口径、TOML 基本字符串的转义、legacy 标量 `hooks = …` 的注释与
//  复原都保持原样。跨族共用的行工具（`lineBody` / `trimmedBody` …）留在主文件。
//
//  形状的事实来源：CodeIsland `installKimiHooks`（ConfigInstaller.swift:2554-2597）。
//

import Foundation

nonisolated extension AgentConfigMerger {
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
        let blockLines =
            hooks
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

    // MARK: - 私有：命令文本判定

    /// 取命令文本的判断入口（Kimi 的块、TOML 里都按命令文本认自己的条目）。
    private static func containsOwnCommand(_ lines: [String]) -> Bool {
        lines.contains { HookInstaller.isOwnHookCommand($0) }
    }

    // MARK: - 私有：Kimi

    /// 一个事件的 `[[hooks]]` 块（TOML 基本字符串里的反斜杠与引号要转义）。
    private static func kimiBlock(event: String, command: String, timeout: Int) -> String {
        let escaped =
            command
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
                trimmed.hasPrefix("hooks =")
            else { return line }
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
                index + 1 < lines.count
            {
                let next = lines[index + 1]
                let content = next.hasPrefix("# ") ? String(next.dropFirst(2)) : ""
                if !content.isEmpty, leadingSpaces(of: content) == 0,
                    content.trimmingCharacters(in: .whitespaces).hasPrefix("hooks =")
                {
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
}
