//
//  CodexHooksConfig.swift
//  AgentIsland
//
//  Codex `config.toml` 前置开关（`[features] hooks = true`）所需的纯文本逻辑：认 `[features]`
//  表头与 `hooks` 键、找下一个表头、把那一行还原成安装前的原文。
//
//  为什么单独成文件：这些函数只吃 `String`、只返回 `String` / `Bool` / `Int?`，不碰安装流程
//  状态（落点解析、读写与备份仍在 `AgentConfigInstaller` 侧）。行级语义必须逐字保持：
//  `[features]` 定位、行尾注释、CRLF 与空行判定都不能动 —— 卸载靠它逐字节还原。
//

import Foundation

nonisolated enum CodexHooksConfig {
    /// 把当前的 `[features] hooks` 还原成安装前的样子（`original` = 安装前的原文）。
    ///
    /// 返回 nil 表示无需改动（当前没有可还原的那一行）。表内其它键、`[features]` 之外
    /// 的内容、注释与 CRLF 全部原样保留：这里只做**行级**替换 / 删除。
    static func restoringCodexHooksKey(from current: String, to original: String) -> String? {
        var lines = current.components(separatedBy: "\n")
        guard let featuresIndex = lines.firstIndex(where: isFeaturesTable),
            let hooksIndex = codexHooksLineIndex(in: lines, after: featuresIndex)
        else { return nil }

        // 安装前就有这个键：把用户原本那一行（值、注释）写回去
        if let originalLine = codexHooksLine(in: original) {
            guard lines[hooksIndex] != originalLine else { return nil }
            lines[hooksIndex] = originalLine
            return lines.joined(separator: "\n")
        }

        // 安装前没有这个键：删掉我们补上的那一行
        lines.remove(at: hooksIndex)
        // 表头也是我们补的、且删完表内已无内容 ⇒ 连表头一起删
        if !containsFeaturesTable(in: original) {
            let sectionEnd = nextTableIndex(in: lines, after: featuresIndex)
            if ((featuresIndex + 1)..<sectionEnd).allSatisfy({ isBlankOrComment(lines[$0]) }) {
                lines.remove(at: featuresIndex)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `[features]` 段内 `hooks` 键所在的行号。
    static func codexHooksLineIndex(in lines: [String], after featuresIndex: Int) -> Int? {
        let sectionEnd = nextTableIndex(in: lines, after: featuresIndex)
        return ((featuresIndex + 1)..<sectionEnd).first { isCodexHooksLine(lines[$0]) }
    }

    /// 文本里 `[features]` 段的 `hooks` 行原文（还原时连注释一起写回）。
    static func codexHooksLine(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let featuresIndex = lines.firstIndex(where: isFeaturesTable),
            let index = codexHooksLineIndex(in: lines, after: featuresIndex)
        else { return nil }
        return lines[index]
    }

    /// 文本里有没有 `[features]` 表。
    static func containsFeaturesTable(in text: String) -> Bool {
        text.components(separatedBy: "\n").contains(where: isFeaturesTable)
    }

    /// 这一行是不是 `[features]` 表头（允许缩进、行尾注释与 CR）。
    static func isFeaturesTable(_ line: String) -> Bool {
        tomlLineBody(line).trimmingCharacters(in: .whitespaces) == "[features]"
    }

    /// 这一行是不是 `[features]` 段里的 `hooks` 键（**值不计**：还原时要认回用户原来的值）。
    static func isCodexHooksLine(_ line: String) -> Bool {
        let parts = tomlLineBody(line)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: "=", maxSplits: 1)
        return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "hooks"
    }

    /// 下一个 TOML 表头行的行号（没有则返回行数）。
    static func nextTableIndex(in lines: [String], after index: Int) -> Int {
        ((index + 1)..<lines.count).first { isTableHeader(lines[$0]) } ?? lines.count
    }

    /// 这一行是不是 TOML 表头（`[table]` / `[[array]]`）。
    static func isTableHeader(_ line: String) -> Bool {
        let body = tomlLineBody(line).trimmingCharacters(in: .whitespaces)
        return body.count >= 2 && body.hasPrefix("[") && body.hasSuffix("]")
    }

    /// 空行或注释行（删表头前的「表内已无内容」判据）。
    static func isBlankOrComment(_ line: String) -> Bool {
        tomlLineBody(line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 去掉行尾注释与 CR 之后的那一段（TOML 的键值判断只看它）。
    static func tomlLineBody(_ line: String) -> String {
        let body = line.firstIndex(of: "#").map { String(line[..<$0]) } ?? line
        return body.replacingOccurrences(of: "\r", with: "")
    }

    /// 文本是否没有实质内容（空串 / 只有空白）。
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
