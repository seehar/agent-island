//
//  ToolCompletionResultTests.swift
//  AgentIslandTests
//
//  工具行最终显示「成功 / 失败 / 被中断」与哪段文本，全部由这里归一。
//  被中断的调用不能回显内容——那是用户自己打断的半截输出。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("工具结果归一")
struct ToolCompletionResultTests {
    @Test("被用户中断的结果只标中断，不回显内容")
    func interruptedHidesContent() {
        let payload = ToolResultPayload(
            content: "Interrupted by user", stdout: "半截输出", stderr: nil, isError: true)
        #expect(payload.isInterrupted)

        let result = ToolCompletionResult.from(parserResult: payload, structuredResult: nil)
        #expect(result.status == ToolStatus.interrupted)
        #expect(result.result == nil)
    }

    @Test("stdout 优先于 content 作为回显")
    func stdoutWinsOverContent() {
        let payload = ToolResultPayload(content: "文本", stdout: "标准输出", stderr: nil, isError: false)
        let result = ToolCompletionResult.from(parserResult: payload, structuredResult: nil)
        #expect(result.status == ToolStatus.success)
        #expect(result.result == "标准输出")
    }

    @Test("没有 stdout/stderr 时回退到 content")
    func contentIsFallback() {
        let payload = ToolResultPayload(content: "只有内容", stdout: nil, stderr: "", isError: false)
        #expect(ToolCompletionResult.from(parserResult: payload, structuredResult: nil).result == "只有内容")
    }

    @Test("失败的调用标记为错误并把 stderr 回显出来")
    func errorPayloadIsMarkedError() {
        let payload = ToolResultPayload(content: nil, stdout: nil, stderr: "命令失败", isError: true)
        let result = ToolCompletionResult.from(parserResult: payload, structuredResult: nil)
        #expect(result.status == ToolStatus.error)
        #expect(result.result == "命令失败")
    }

    @Test("没有解析结果时按成功处理且无回显")
    func missingPayloadIsSuccessWithoutText() {
        let result = ToolCompletionResult.from(parserResult: nil, structuredResult: nil)
        #expect(result.status == ToolStatus.success)
        #expect(result.result == nil)
        #expect(result.structuredResult == nil)
    }

    @Test("用户拒绝（user doesn't want to proceed）按中断处理")
    func refusalCountsAsInterrupted() {
        let payload = ToolResultPayload(
            content: "The user doesn't want to proceed with this tool use.", stdout: nil, stderr: nil,
            isError: true)
        #expect(payload.isInterrupted)
        #expect(
            ToolCompletionResult.from(parserResult: payload, structuredResult: nil).status
                == ToolStatus.interrupted)
    }
}
