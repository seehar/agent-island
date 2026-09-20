//
//  JSONLTranscriptTests.swift
//  AgentIslandTests
//
//  JSONL 记录读取是 Claude / pi / omp 共用的路径：字节记账、半行、坏行与重置语义
//  都在 JSONLTranscriptSchema 里，子类只翻译单条记录。这里用内联构造的小记录
//  （临时文件）驱动真实解析器，不读用户动辄几个 GB 的记录库。
//

import Foundation
import Testing

@testable import AgentIsland

/// 让真实 schema 去读指定文件的夹具：只替换「记录文件在哪」，
/// 其余（增量循环、半行处理、记录翻译）全部走生产实现。
nonisolated final class TempFileJSONLSchema: JSONLTranscriptSchema {
    private let fileURL: URL
    private let inner: JSONLTranscriptSchema

    init(fileURL: URL, inner: JSONLTranscriptSchema) {
        self.fileURL = fileURL
        self.inner = inner
        super.init()
    }

    override var agent: AgentKind { inner.agent }

    override func transcriptFile(sessionId: String, cwd: String) -> URL? { fileURL }

    override func consumeRecord(
        _ json: [String: Any],
        rawLine: String,
        state: inout TranscriptParseState,
        result: inout TranscriptReadResult
    ) {
        inner.consumeRecord(json, rawLine: rawLine, state: &state, result: &result)
    }
}

/// 一个临时记录文件 + 一份解析状态。
struct TranscriptFixture {
    let directory: URL
    let file: URL
    let schema: JSONLTranscriptSchema
    var state = TranscriptParseState()

    static func create(agent: AgentKind, contents: String) throws -> TranscriptFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let base: JSONLTranscriptSchema =
            agent == .claudeCode ? ClaudeTranscriptSchema() : PiTranscriptSchema(kind: agent)
        return TranscriptFixture(
            directory: directory, file: file,
            schema: TempFileJSONLSchema(fileURL: file, inner: base))
    }

    mutating func read() -> TranscriptReadResult {
        schema.read(sessionId: "test-session", cwd: "/tmp/island-transcript-tests", state: &state)
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func overwrite(_ text: String) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("JSONL 增量解析")
struct JSONLTranscriptTests {
    /// 第一条解析出的气泡里的文本。
    private func firstText(_ result: TranscriptReadResult) -> String? {
        guard let message = result.newMessages.first else { return nil }
        for block in message.content {
            if case .text(let text) = block { return text }
        }
        return nil
    }

    private func piUserLine(id: String, text: String) -> String {
        #"{"type":"message","id":"\#(id)","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
            + "\n"
    }

    private var piAssistantToolLine: String {
        #"{"type":"message","id":"m2","message":{"role":"assistant","content":[{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"ls -la"}}]}}"#
            + "\n"
    }

    @Test("末尾未写完的行不消费，补齐换行后才解析")
    func partialTrailingLineIsDeferred() throws {
        let firstLine = piUserLine(id: "m1", text: "第一行")
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: firstLine + #"{"type":"mess"#)
        defer { fixture.cleanup() }

        let initial = fixture.read()
        #expect(initial.newMessages.count == 1)
        #expect(fixture.state.offset == UInt64(firstLine.utf8.count))

        // 半行还没有换行符：这次读取不该产出任何内容
        #expect(fixture.read().newMessages.isEmpty)

        try fixture.append(
            #"age","id":"m2","message":{"role":"user","content":[{"type":"text","text":"第二行"}]}}"# + "\n")
        let completed = fixture.read()
        #expect(completed.newMessages.count == 1)
        #expect(firstText(completed) == "第二行")
    }

    @Test("坏行被跳过，前后的行照常解析")
    func brokenLineIsSkipped() throws {
        let contents =
            piUserLine(id: "m1", text: "甲") + "这不是 JSON\n" + #"{"type":"message","# + "\n"
            + piUserLine(id: "m2", text: "乙")
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: contents)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.count == 2)
        #expect(firstText(result) == "甲")
        #expect(fixture.state.messages.count == 2)
    }

    @Test("空行只推进偏移，不产出内容")
    func blankLinesProduceNothing() throws {
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: "\n\n\n")
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.isEmpty)
        #expect(result.activity.isEmpty)
        #expect(fixture.state.offset == 3)
    }

    @Test("末尾没有换行的整行不消费")
    func lineWithoutNewlineIsNotConsumed() throws {
        let line = String(piUserLine(id: "m1", text: "等等").dropLast())
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: line)
        defer { fixture.cleanup() }

        #expect(fixture.read().newMessages.isEmpty)
        #expect(fixture.state.offset == 0)

        try fixture.append("\n")
        #expect(fixture.read().newMessages.count == 1)
    }

    @Test("增量读取只产出新增部分")
    func incrementalReadOnlyYieldsNewMessages() throws {
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: piUserLine(id: "m1", text: "甲"))
        defer { fixture.cleanup() }

        #expect(fixture.read().newMessages.count == 1)

        try fixture.append(piUserLine(id: "m2", text: "乙"))
        let second = fixture.read()
        #expect(second.newMessages.count == 1)
        #expect(firstText(second) == "乙")
        #expect(fixture.state.messages.count == 2)
    }

    @Test("文件被整体重写变短时从头重读")
    func shrunkFileIsRereadFromStart() throws {
        let longLine = piUserLine(id: "m1", text: String(repeating: "旧的", count: 60))
        var fixture = try TranscriptFixture.create(
            agent: .ohMyPi, contents: longLine + piUserLine(id: "m2", text: "旧二"))
        defer { fixture.cleanup() }

        #expect(fixture.read().newMessages.count == 2)

        try fixture.overwrite(piUserLine(id: "m3", text: "新"))
        let afterRewrite = fixture.read()
        #expect(afterRewrite.newMessages.count == 1)
        #expect(firstText(afterRewrite) == "新")
        #expect(fixture.state.messages.count == 1)
    }

    @Test("首次读取就遇到重置：清空内容但不置 pending")
    func resetOnFirstReadClearsContent() throws {
        var fixture = try TranscriptFixture.create(
            agent: .ohMyPi,
            contents: piUserLine(id: "m1", text: "甲") + #"{"type":"reset_boundary"}"# + "\n")
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.resetDetected)
        #expect(result.activity.contains(.sessionReset))
        #expect(fixture.state.resetPending == false)
        #expect(fixture.state.messages.isEmpty)
    }

    @Test("增量读取遇到重置：清空已累积内容并置 pending")
    func resetDuringIncrementalReadSetsPending() throws {
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: piUserLine(id: "m1", text: "甲"))
        defer { fixture.cleanup() }

        #expect(fixture.read().newMessages.count == 1)

        try fixture.append(#"{"type":"reset_boundary"}"# + "\n")
        let result = fixture.read()
        #expect(result.resetDetected)
        #expect(fixture.state.resetPending)
        #expect(fixture.state.messages.isEmpty)
    }

    @Test("pi 的用户消息、工具调用、工具结果翻译成三类事件")
    func piRecordKindsBecomeActivity() throws {
        let toolResultLine =
            #"{"type":"message","id":"m3","message":{"role":"toolResult","toolCallId":"t1","toolName":"bash","content":[{"type":"text","text":"ok"}]}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(
            agent: .ohMyPi,
            contents: piUserLine(id: "m1", text: "跑个命令") + piAssistantToolLine + toolResultLine)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(
            result.activity == [
                .promptSubmitted(text: "跑个命令"),
                .toolStarted(id: "t1", name: "bash", input: ["command": "ls -la"]),
                .toolFinished(id: "t1", name: "bash", isError: false),
            ])
        // 工具结果不产生气泡：只有用户与助手两条
        #expect(result.newMessages.count == 2)
        #expect(fixture.state.completedToolIds == ["t1"])
        #expect(fixture.state.lastToolName == "bash")
        #expect(fixture.state.lastMessageRole == "tool")
    }

    @Test("标记为 agent 续写的用户消息不算用户提交")
    func agentAttributedMessageIsNotPromptSubmission() throws {
        let contents =
            #"{"type":"message","id":"m1","message":{"role":"user","attribution":"agent","content":[{"type":"text","text":"继续"}]}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: contents)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.activity.isEmpty)
        #expect(result.newMessages.count == 1)
    }

    @Test("工具结果缺少工具名时按未知工具处理且不崩")
    func unnamedToolResultDoesNotCrash() throws {
        let contents =
            #"{"type":"message","id":"m1","message":{"role":"toolResult","toolCallId":"ghost","isError":true,"content":[{"type":"text","text":"boom"}]}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(agent: .ohMyPi, contents: contents)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.activity == [.toolFinished(id: "ghost", name: nil, isError: true)])
        #expect(fixture.state.toolResults["ghost"]?.isError == true)
        #expect(fixture.state.completedToolIds == ["ghost"])
    }

    @Test("Claude 的斜杠命令回显不产出气泡与事件")
    func claudeInjectedTextIsIgnored() throws {
        let contents =
            #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"<command-name>/help</command-name>"}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(agent: .claudeCode, contents: contents)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.isEmpty)
        #expect(result.activity.isEmpty)
        #expect(fixture.state.firstUserMessage == nil)
    }

    @Test("Claude 的用户与助手消息产出气泡，工具调用产出开始事件")
    func claudeMessagesBecomeBubbles() throws {
        let contents =
            #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"你好"}]}}"#
            + "\n"
            + #"{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"在的"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(agent: .claudeCode, contents: contents)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.count == 2)
        #expect(
            result.activity == [
                .promptSubmitted(text: "你好"),
                .toolStarted(id: "t1", name: "Bash", input: ["command": "ls"]),
            ])
        #expect(fixture.state.firstUserMessage == "你好")
        #expect(fixture.state.lastToolName == "Bash")
        #expect(fixture.state.lastMessageRole == "tool")
    }

    @Test("Claude 的工具结果行登记完成状态与内容")
    func claudeToolResultIsRegistered() throws {
        let contents =
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
            + "\n"
            + #"{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done","is_error":false}]}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(agent: .claudeCode, contents: contents)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.count == 1)
        #expect(
            result.activity == [
                .toolStarted(id: "t1", name: "Bash", input: ["command": "ls"]),
                .toolFinished(id: "t1", name: "Bash", isError: false),
            ])
        #expect(fixture.state.completedToolIds == ["t1"])
        #expect(fixture.state.toolResults["t1"]?.content == "done")
    }

    @Test("Claude 的 /clear 行触发重置并清空已累积内容")
    func claudeClearResetsConversation() throws {
        let firstLine =
            #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"你好"}]}}"#
            + "\n"
        var fixture = try TranscriptFixture.create(agent: .claudeCode, contents: firstLine)
        defer { fixture.cleanup() }

        #expect(fixture.read().newMessages.count == 1)

        try fixture.append(
            #"{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
                + "\n")
        let result = fixture.read()
        #expect(result.resetDetected)
        #expect(fixture.state.resetPending)
        #expect(fixture.state.messages.isEmpty)
        #expect(result.activity == [.sessionReset])
    }
}
