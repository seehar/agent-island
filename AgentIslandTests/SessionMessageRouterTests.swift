//
//  SessionMessageRouterTests.swift
//  AgentIslandTests
//
//  「tmux 优先、Paseo 兜底」这条回退顺序的行为契约。
//
//  顺序写错或提前返回的后果都在界面上：找不到 pane 时消息凭空消失、明明 tmux 写成功了
//  又往 Paseo 重复发一次。这里用假写入端把四段分支逐一钉住。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("会话写入通道")
struct SessionMessageRouterTests {
    /// 记录调用序列的假写入端：promises 决定每一步返回什么。
    private actor FakeWriter: SessionTerminalWriting {
        private(set) var calls: [String] = []
        let pane: TmuxTarget?
        let paneSendSucceeds: Bool
        let paseoSucceeds: Bool

        init(
            pane: TmuxTarget?, paneSendSucceeds: Bool = true, paseoSucceeds: Bool = true
        ) {
            self.pane = pane
            self.paneSendSucceeds = paneSendSucceeds
            self.paseoSucceeds = paseoSucceeds
        }

        func locatePane(tty: String) async -> TmuxTarget? {
            calls.append("locate:\(tty)")
            return pane
        }

        func sendToPane(_ text: String, target: TmuxTarget) async -> Bool {
            calls.append("pane.send:\(target.targetString)")
            return paneSendSucceeds
        }

        func interruptPane(_ target: TmuxTarget) async -> Bool {
            calls.append("pane.interrupt:\(target.targetString)")
            return paneSendSucceeds
        }

        func sendToPaseo(_ text: String, terminalId: String, cliPath: String?) async -> Bool {
            calls.append("paseo.send:\(terminalId)")
            return paseoSucceeds
        }

        func interruptPaseo(terminalId: String, cliPath: String?) async -> Bool {
            calls.append("paseo.interrupt:\(terminalId)")
            return paseoSucceeds
        }

        func recordedCalls() -> [String] { calls }
    }

    private let pane = TmuxTarget(session: "work", window: "1", pane: "0")

    @Test("tmux 写成功就返回，不碰 Paseo")
    func tmuxSuccessWins() async {
        let writer = FakeWriter(pane: pane)
        let router = SessionMessageRouter(
            route: ChatSendRoute(tmuxTTY: "ttys001", paseoTerminalId: "term-1"),
            paseoCliPath: nil, writer: writer)

        #expect(await router.send("hi"))
        #expect(await writer.recordedCalls() == ["locate:ttys001", "pane.send:work:1.0"])
    }

    @Test("解析不到 pane 时退到 Paseo")
    func missingPaneFallsBackToPaseo() async {
        let writer = FakeWriter(pane: nil)
        let router = SessionMessageRouter(
            route: ChatSendRoute(tmuxTTY: "ttys001", paseoTerminalId: "term-1"),
            paseoCliPath: "/opt/bin/paseo", writer: writer)

        #expect(await router.send("hi"))
        #expect(await writer.recordedCalls() == ["locate:ttys001", "paseo.send:term-1"])
    }

    @Test("pane 找到了但写入失败也要退到 Paseo（不是静默丢弃）")
    func paneSendFailureFallsBackToPaseo() async {
        let writer = FakeWriter(pane: pane, paneSendSucceeds: false)
        let router = SessionMessageRouter(
            route: ChatSendRoute(tmuxTTY: "ttys001", paseoTerminalId: "term-1"),
            paseoCliPath: nil, writer: writer)

        #expect(await router.send("hi"))
        #expect(
            await writer.recordedCalls() == [
                "locate:ttys001", "pane.send:work:1.0", "paseo.send:term-1",
            ])
    }

    @Test("两条通道都不可用时返回 false（界面据此提示失败）")
    func noUsableChannelReportsFailure() async {
        let writer = FakeWriter(pane: nil, paseoSucceeds: false)
        let router = SessionMessageRouter(
            route: ChatSendRoute(tmuxTTY: "ttys001", paseoTerminalId: nil),
            paseoCliPath: nil, writer: writer)

        #expect(!(await router.send("hi")))
        // 没有 Paseo id 就不该去碰它。
        #expect(await writer.recordedCalls() == ["locate:ttys001"])
    }

    @Test("中断与发送同源：tmux 成功即止，失败退 Paseo")
    func interruptUsesSameFallbackOrder() async {
        let okWriter = FakeWriter(pane: pane)
        let okRouter = SessionMessageRouter(
            route: ChatSendRoute(tmuxTTY: "ttys001", paseoTerminalId: "term-1"),
            paseoCliPath: nil, writer: okWriter)

        #expect(await okRouter.interrupt())
        #expect(await okWriter.recordedCalls() == ["locate:ttys001", "pane.interrupt:work:1.0"])

        let failing = FakeWriter(pane: pane, paneSendSucceeds: false)
        let fallbackRouter = SessionMessageRouter(
            route: ChatSendRoute(tmuxTTY: "ttys001", paseoTerminalId: "term-1"),
            paseoCliPath: nil, writer: failing)

        #expect(await fallbackRouter.interrupt())
        #expect(
            await failing.recordedCalls() == [
                "locate:ttys001", "pane.interrupt:work:1.0", "paseo.interrupt:term-1",
            ])
    }
}
