//
//  ChatSendRoute.swift
//  AgentIsland
//
//  「往这个会话里写一行东西」该走哪条通道。
//
//  三处判据原先各写一遍：聊天页输入框是否可用、发送、中断。它们的口径必须完全一致，
//  否则会出现「按钮可点但发不出去」或相反。抽成纯值之后这条口径可单测。
//

import Foundation

/// 写通道：tmux 优先、Paseo 兜底。
///
/// 两者**可以同时存在**：Paseo 用 node-pty 起终端，而那个终端完全可能跑在 tmux 里。
/// 此时先试 tmux（能精确定位到 pane），失败再落到 Paseo 的终端 id。
nonisolated struct ChatSendRoute: Equatable, Sendable {
    /// tmux 侧可用的 pane 依据：会话 tty（短名，与 `tmux list-panes` 的 `#{pane_tty}` 同口径）。
    let tmuxTTY: String?
    /// Paseo 托管终端 id（集成从 `PASEO_TERMINAL_ID` 上报）。
    let paseoTerminalId: String?

    /// 有没有任何一条可用的写通道（输入框是否可用的唯一判据）。
    var isAvailable: Bool { tmuxTTY != nil || paseoTerminalId != nil }

    /// 从会话状态解析。空串按「没有」处理：集成上报的是原始环境变量，空值等于没报，
    /// 而把空串当成 tty/终端 id 会让「可点但发不出去」重新出现。
    init(session: SessionState) {
        if session.isInTmux, let tty = session.tty, !tty.isEmpty {
            tmuxTTY = tty
        } else {
            tmuxTTY = nil
        }
        if let terminalId = session.paseoTerminalId, !terminalId.isEmpty {
            paseoTerminalId = terminalId
        } else {
            paseoTerminalId = nil
        }
    }

    /// 直接给两路值（单测用；正常路径走 `init(session:)`）。
    init(tmuxTTY: String?, paseoTerminalId: String?) {
        self.tmuxTTY = tmuxTTY
        self.paseoTerminalId = paseoTerminalId
    }
}
