//
//  SubagentToolStatusTextTests.swift
//  AgentIslandTests
//
//  子代理工具行的状态文案回归：这里原本把「运行中」与「完成 / 失败 / 等待」写成
//  同一句 `ToolStatusDisplay.running(...)`，于是子工具跑完后整行仍显示「Running…」。
//  用例钉的是「非运行态不再是运行中文案」这条不变量，不比对具体译文——文案跟随
//  应用内选定的语言，比对译文会把语言偏好带进断言。
//

import Testing

@testable import AgentIsland

@Suite("子代理工具行的状态文案")
struct SubagentToolStatusTextTests {
    private let toolName = "Read"
    private let input = ["file_path": "/tmp/example.txt"]

    private func display(for status: ToolStatus) -> ToolStatusDisplay {
        SubagentToolStatusText.display(for: status, name: toolName, input: input)
    }

    private func text(for status: ToolStatus) -> String {
        display(for: status).text
    }

    @Test("只有运行中才是运行中文案：完成 / 失败 / 中断都不再显示它")
    func onlyRunningUsesRunningText() {
        let running = text(for: .running)

        #expect(text(for: .success) != running)
        #expect(text(for: .error) != running)
        #expect(text(for: .interrupted) != running)
    }

    @Test("完成与失败是两条不同文案，且都不再标为运行中")
    func completedAndFailedDiffer() {
        #expect(text(for: .success) != text(for: .error))

        #expect(!display(for: .success).isRunning)
        #expect(!display(for: .error).isRunning)
        #expect(!display(for: .interrupted).isRunning)
        #expect(display(for: .running).isRunning)
        #expect(display(for: .waitingForApproval).isRunning)
    }

    @Test("等待批准有自己的文案（改造前落进了运行中那一支）")
    func waitingForApprovalHasItsOwnText() {
        #expect(text(for: .waitingForApproval) != text(for: .running))
    }
}