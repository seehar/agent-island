//
//  TmuxPaneListTests.swift
//  AgentIslandTests
//
//  `tmux list-panes` 解析的契约。四个用途（按 tty 发消息、按 pid 判祖辈、按 cwd 找 pane、
//  按 pid 切 pane）共用这一份解析，失配的表现是「点了没反应」——没有报错，所以判据要钉住。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("tmux pane 列表解析")
struct TmuxPaneListTests {
    private let output = """
        main:0.0 /dev/ttys001
        main:0.1 /dev/ttys002
        work:2.3 /dev/ttys007

        """

    @Test("按行解析出目标与值")
    func parsesEntries() {
        let entries = TmuxPaneList.entries(output)
        #expect(entries.count == 3)
        #expect(entries[1].target == TmuxTarget(session: "main", window: "0", pane: "1"))
        #expect(entries[1].value == "/dev/ttys002")
        #expect(entries[2].target.targetString == "work:2.3")
    }

    @Test("按 tty 找 pane：/dev/ 前缀两侧互通")
    func matchesTTYWithEitherPrefix() {
        #expect(TmuxPaneList.target(forTTY: "ttys002", in: output)?.targetString == "main:0.1")
        #expect(
            TmuxPaneList.target(forTTY: "/dev/ttys007", in: output)?.targetString == "work:2.3")
    }

    @Test("没有匹配或 tty 为空时返回 nil")
    func missesReturnNil() {
        #expect(TmuxPaneList.target(forTTY: "ttys999", in: output) == nil)
        #expect(TmuxPaneList.target(forTTY: "", in: output) == nil)
        #expect(TmuxPaneList.target(forTTY: "ttys001", in: "") == nil)
    }

    @Test("解析不出的行直接跳过，不影响其它行")
    func skipsMalformedLines() {
        let messy = """
            % a banner line
            main:0.0
            not-a-target /dev/ttys003
            main:0.2 /dev/ttys003

            """
        let entries = TmuxPaneList.entries(messy)
        #expect(entries.map(\.value) == ["/dev/ttys003"])
        #expect(TmuxPaneList.target(forTTY: "ttys003", in: messy)?.targetString == "main:0.2")
    }

    @Test("自定义分隔符（YabaiController 用 | 拼模板）")
    func customSeparator() {
        let piped = "main:1.0|4242"
        let entries = TmuxPaneList.entries(piped, separator: "|")
        #expect(entries.first?.target.targetString == "main:1.0")
        #expect(entries.first?.value == "4242")
    }

    @Test("值里的空格保留（按 cwd 找 pane 时路径可能带空格）")
    func keepsSpacesInValue() {
        let entries = TmuxPaneList.entries("main:0.0 /Users/me/My Project")
        #expect(entries.first?.value == "/Users/me/My Project")
    }
}
