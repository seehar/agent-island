//
//  ChatSendRouteTests.swift
//  AgentIslandTests
//
//  写通道判据：tmux 优先、Paseo 兜底，两者可同时存在（Paseo 的终端可能就跑在 tmux 里）。
//  聊天页的「输入框是否可用」、发送、中断三处共用这一份口径——判错的表现是
//  「按钮可点但发不出去」，或者 Paseo 会话被误置灰。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("聊天写通道")
struct ChatSendRouteTests {
    private func session(
        isInTmux: Bool = false, tty: String? = nil, paseoTerminalId: String? = nil
    ) -> SessionState {
        var state = SessionState(agent: .claudeCode, sessionId: "route", cwd: "/tmp")
        state.isInTmux = isInTmux
        state.tty = tty
        state.paseoTerminalId = paseoTerminalId
        return state
    }

    @Test("tmux 会话：tty 就是 pane 依据")
    func tmuxSessionUsesTTY() {
        let route = ChatSendRoute(session: session(isInTmux: true, tty: "ttys001"))
        #expect(route.tmuxTTY == "ttys001")
        #expect(route.paseoTerminalId == nil)
        #expect(route.isAvailable)
    }

    @Test("不在 tmux 里时即便有 tty 也不能走 tmux")
    func ttyWithoutTmuxIsNotUsable() {
        let route = ChatSendRoute(session: session(isInTmux: false, tty: "ttys001"))
        #expect(route.tmuxTTY == nil)
        #expect(!route.isAvailable)
    }

    @Test("Paseo 会话：没有 tty 也能发")
    func paseoSessionUsesTerminalID() {
        let route = ChatSendRoute(session: session(paseoTerminalId: "term-9"))
        #expect(route.tmuxTTY == nil)
        #expect(route.paseoTerminalId == "term-9")
        #expect(route.isAvailable)
    }

    @Test("两者都有时两路都留着（发送失败要能落到 Paseo）")
    func bothChannelsCoexist() {
        let route = ChatSendRoute(
            session: session(isInTmux: true, tty: "ttys002", paseoTerminalId: "term-1"))
        #expect(route.tmuxTTY == "ttys002")
        #expect(route.paseoTerminalId == "term-1")
    }

    @Test("空串按「没有」处理：集成上报空环境变量不等于可用")
    func emptyStringsAreAbsent() {
        let route = ChatSendRoute(session: session(isInTmux: true, tty: "", paseoTerminalId: ""))
        #expect(route.tmuxTTY == nil)
        #expect(route.paseoTerminalId == nil)
        #expect(!route.isAvailable)
    }

    @Test("都没有时不可用")
    func unavailableWhenNothingReported() {
        #expect(!ChatSendRoute(session: session()).isAvailable)
        #expect(!ChatSendRoute(tmuxTTY: nil, paseoTerminalId: nil).isAvailable)
    }
}
