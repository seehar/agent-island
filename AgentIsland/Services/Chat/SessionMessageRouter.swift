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

/// 真正把字符串写进终端的两个动作。
///
/// 抽成协议是为了让「回退顺序」可单测：发送与中断都走「tmux pane 优先、Paseo 兜底」，
/// 这条顺序曾经出过错——返回值被丢弃时，「找不到 pane」与「写入失败」在界面上完全一样，
/// 用户看到的是消息凭空消失。生产的实现是 `LiveSessionTerminalWriter`（两个单例的薄包装）。
nonisolated protocol SessionTerminalWriting: Sendable {
    func locatePane(tty: String) async -> TmuxTarget?
    func sendToPane(_ text: String, target: TmuxTarget) async -> Bool
    func interruptPane(_ target: TmuxTarget) async -> Bool
    func sendToPaseo(_ text: String, terminalId: String, cliPath: String?) async -> Bool
    func interruptPaseo(terminalId: String, cliPath: String?) async -> Bool
}

/// 生产实现：tmux（按 tty 解析 pane）与 Paseo 托管终端。
nonisolated struct LiveSessionTerminalWriter: SessionTerminalWriting {
    func locatePane(tty: String) async -> TmuxTarget? {
        await TmuxPaneList.locate(tty: tty)
    }

    func sendToPane(_ text: String, target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(text, to: target)
    }

    func interruptPane(_ target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendInterrupt(to: target)
    }

    func sendToPaseo(_ text: String, terminalId: String, cliPath: String?) async -> Bool {
        await PaseoCli.shared.sendMessage(text, toTerminal: terminalId, cliPath: cliPath)
    }

    func interruptPaseo(terminalId: String, cliPath: String?) async -> Bool {
        await PaseoCli.shared.sendInterrupt(toTerminal: terminalId, cliPath: cliPath)
    }
}

/// 会话写入通道的分发（纯逻辑，不持有状态）。
///
/// 通道依据由调用方从会话状态解析后传入（`ChatSendRoute` + CLI 路径），这里不再自己
/// 算一遍——「能不能发」的 UI 判据与「往哪发」必须同源，两处各算会漂。
nonisolated struct SessionMessageRouter {
    /// 通道依据：tmux 的 tty / Paseo 的终端 id（见 `ChatSendRoute`）。
    let route: ChatSendRoute
    /// 集成上报的 Paseo CLI 路径；`nil` 时由 `PaseoCli` 自行搜索。
    let paseoCliPath: String?

    /// 写入端；生产用 `LiveSessionTerminalWriter`，用例注入假实现来钉回退顺序。
    private let writer: any SessionTerminalWriting

    init(
        route: ChatSendRoute, paseoCliPath: String?,
        writer: any SessionTerminalWriting = LiveSessionTerminalWriter()
    ) {
        self.route = route
        self.paseoCliPath = paseoCliPath
        self.writer = writer
    }

    /// 送一条消息：① tmux（按 tty 解析出 pane，pane 级更精确）② Paseo 托管终端。
    func send(_ text: String) async -> Bool {
        if let tty = route.tmuxTTY,
            let target = await writer.locatePane(tty: tty),
            await writer.sendToPane(text, target: target)
        {
            return true
        }

        guard let terminalId = route.paseoTerminalId else { return false }
        return await writer.sendToPaseo(text, terminalId: terminalId, cliPath: paseoCliPath)
    }

    /// 中断当前回合：两条通道与发送消息同源，tmux 侧发的是 Ctrl-C。
    func interrupt() async -> Bool {
        if let tty = route.tmuxTTY,
            let target = await writer.locatePane(tty: tty),
            await writer.interruptPane(target)
        {
            return true
        }

        guard let terminalId = route.paseoTerminalId else { return false }
        return await writer.interruptPaseo(terminalId: terminalId, cliPath: paseoCliPath)
    }
}
