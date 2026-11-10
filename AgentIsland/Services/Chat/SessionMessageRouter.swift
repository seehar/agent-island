//
//  SessionMessageRouter.swift
//  AgentIsland
//
//  把一条消息 / 一次中断送进会话所在终端：tmux pane 优先，退到 Paseo 托管终端。
//
//  这条「tmux → Paseo」的回退链原先在 `ChatView` 里为发送与中断各写了一遍，视图因此
//  既要解析通道、又要懂两条通道的差异。收口到这里后，视图只保留输入框复位与失败提示。
//

import Foundation

/// 会话写入通道的分发（纯逻辑，不持有状态）。
///
/// 通道依据由调用方从会话状态解析后传入（`ChatSendRoute` + CLI 路径），这里不再自己
/// 算一遍——「能不能发」的 UI 判据与「往哪发」必须同源，两处各算会漂。
nonisolated struct SessionMessageRouter {
    /// 通道依据：tmux 的 tty / Paseo 的终端 id（见 `ChatSendRoute`）。
    let route: ChatSendRoute
    /// 集成上报的 Paseo CLI 路径；`nil` 时由 `PaseoCli` 自行搜索。
    let paseoCliPath: String?

    init(route: ChatSendRoute, paseoCliPath: String?) {
        self.route = route
        self.paseoCliPath = paseoCliPath
    }

    /// 送一条消息：① tmux（按 tty 解析出 pane，pane 级更精确）② Paseo 托管终端。
    func send(_ text: String) async -> Bool {
        if let tty = route.tmuxTTY,
            let target = await TmuxPaneList.locate(tty: tty),
            await ToolApprovalHandler.shared.sendMessage(text, to: target)
        {
            return true
        }

        guard let terminalId = route.paseoTerminalId else { return false }
        return await PaseoCli.shared.sendMessage(
            text, toTerminal: terminalId, cliPath: paseoCliPath)
    }

    /// 中断当前回合：两条通道与发送消息同源，tmux 侧发的是 Ctrl-C。
    func interrupt() async -> Bool {
        if let tty = route.tmuxTTY,
            let target = await TmuxPaneList.locate(tty: tty),
            await ToolApprovalHandler.shared.sendInterrupt(to: target)
        {
            return true
        }

        guard let terminalId = route.paseoTerminalId else { return false }
        return await PaseoCli.shared.sendInterrupt(
            toTerminal: terminalId, cliPath: paseoCliPath)
    }
}
