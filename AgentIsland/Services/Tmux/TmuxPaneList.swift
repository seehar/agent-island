//
//  TmuxPaneList.swift
//  AgentIsland
//
//  `tmux list-panes -a` 的输出解析：一行一条 `<session>:<window>.<pane> <值>`。
//
//  这张表有四个用途（按 tty 找 pane 发消息、按 pid 判断祖辈、按 cwd 找 pane、按 pid 切 pane），
//  原先四处各自拼格式串、各自解包。格式串与切分规则一旦不同步，失配是静默的——
//  表现为「点了没反应」或「找不到终端」，没有任何报错。这里把「怎么解」收敛成一处，
//  「跑不跑 tmux」留给调用方（`locate(tty:)` 是聊天页用的那一份）。
//

import Foundation

/// `tmux list-panes` 输出的解析与按值查找。
nonisolated enum TmuxPaneList {
    /// 一条 pane 记录：目标 + 该行剩余的字段值（目标之后的整段，值里的空格会保留）。
    struct Entry: Equatable, Sendable {
        let target: TmuxTarget
        let value: String
    }

    /// 解析 `list-panes` 输出。
    ///
    /// - Parameter separator: 目标与值之间的分隔符；缺省按第一个空格切（tmux `-F` 模板的
    ///   默认写法），传 `"|"` 可对应自己拼的模板（见 `YabaiController`）。
    ///   解析不出来的行直接跳过——`ps` 之外的进程输出里混进 banner 不该让整次查找失配。
    static func entries(_ output: String, separator: Character = " ") -> [Entry] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine -> Entry? in
            let line = String(rawLine)
            guard let index = line.firstIndex(of: separator) else { return nil }
            let targetText = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            guard !targetText.isEmpty, !value.isEmpty, let target = TmuxTarget(from: targetText)
            else { return nil }
            return Entry(target: target, value: value)
        }
    }

    /// 去掉 `tmux` 与集成上报之间不一致的 `/dev/` 前缀（`#{pane_tty}` 带前缀，集成上报的不带）。
    static func normalizedTTY(_ raw: String) -> String {
        raw.hasPrefix("/dev/") ? String(raw.dropFirst("/dev/".count)) : raw
    }

    /// 按 tty 找对应的 pane（两侧都先归一前缀）。
    static func target(forTTY tty: String, in output: String) -> TmuxTarget? {
        let wanted = normalizedTTY(tty)
        guard !wanted.isEmpty else { return nil }
        return entries(output).first { normalizedTTY($0.value) == wanted }?.target
    }

    /// 跑一次 `tmux list-panes` 并按 tty 找 pane（聊天页的发送/中断用）。
    ///
    /// 拿不到 tmux 路径、命令失败、没有匹配都返回 nil：调用方据此换一条通道或在界面上
    /// 说明失败，而不是静默什么都不做。
    static func locate(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }
        let arguments = [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}",
        ]
        guard
            let output = try? await ProcessExecutor.shared.run(tmuxPath, arguments: arguments)
        else { return nil }
        return target(forTTY: tty, in: output)
    }
}
