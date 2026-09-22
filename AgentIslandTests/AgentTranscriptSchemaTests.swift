//
//  AgentTranscriptSchemaTests.swift
//  AgentIslandTests
//
//  各 Agent 记录解析器（schema）的行为：用内联构造的小记录驱动**真实**实现，
//  不读用户动辄几个 GB 的记录库。钉住四件事：
//    · 各格式的消息 / 工具结果 / 活动事件被正确产出（含各家的字段差异：毫秒时间戳、
//      input_text 块、type+payload 事件、role 顶层键……）；
//    · 增量读取不重复产出，文件被截断 / 重写时从头重来；
//    · 只有记录里真有 token 字段的 Agent 才产出用量（其余宁可没有，也不能编）；
//    · 注册表覆盖全部有记录的 Agent，没有记录的走空解析器。
//

import Foundation
import Testing

@testable import AgentIsland

// MARK: - 夹具

/// 让真实 schema 去读指定文件的适配器：只替换「记录文件在哪」，
/// 其余（增量循环、半行处理、记录翻译）全部走生产实现。
nonisolated final class SchemaFileAdapter: JSONLTranscriptSchema {
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

/// Cline 的记录文件由 Provider 决定，这里用子类把文件固定到临时目录。
nonisolated final class TempFileClineSchema: ClineTranscriptSchema {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    override func transcriptFile(sessionId: String, cwd: String) -> URL? { fileURL }
}

/// 一个临时记录文件 + 一份解析状态。
struct SchemaFixture {
    let directory: URL
    let file: URL
    let schema: JSONLTranscriptSchema
    var state = TranscriptParseState()

    /// 取某个 Agent 的 JSONL 记录解析器（走生产注册表，顺带验证注册表本身）。
    static func jsonl(agent: AgentKind, contents: String) throws -> SchemaFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)

        guard
            let inner = AgentTranscriptSchemaRegistry.schema(for: agent) as? JSONLTranscriptSchema
        else {
            throw SchemaFixtureError.notJSONL(agent)
        }
        return SchemaFixture(
            directory: directory, file: file,
            schema: SchemaFileAdapter(fileURL: file, inner: inner))
    }

    /// 临时目录 + 一个文件（供非 JSONL 的 schema 自用）。
    static func scratch() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("session.jsonl"))
    }

    mutating func read() -> TranscriptReadResult {
        schema.read(sessionId: "test-session", cwd: "/tmp/island-schema-tests", state: &state)
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

enum SchemaFixtureError: Error {
    case notJSONL(AgentKind)
}

// MARK: - 用例

@Suite("各 Agent 的记录解析")
struct AgentTranscriptSchemaTests {

    // MARK: 夹具内容

    /// Qoder / Factory：与 Claude 完全同格式的记录。
    private var claudeFamilyLines: String {
        #"""
        {"uuid":"u1","type":"user","sessionId":"s1","cwd":"/tmp/q","message":{"role":"user","content":[{"type":"text","text":"把首页改成深色"}]}}
        {"uuid":"a1","type":"assistant","parentUuid":"u1","message":{"role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":7,"cache_creation_input_tokens":3},"content":[{"type":"text","text":"先看首页文件"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/q/Home.vue"}}]}}
        {"uuid":"u2","type":"user","toolName":"Read","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file body"}]}}

        """#
    }

    /// CodeBuddy：`type:"message"` + 顶层 `role` + `input_text` 块 + 毫秒 epoch。
    private var codeBuddyLines: String {
        #"""
        {"id":"c1","timestamp":1782725749544,"type":"message","role":"user","content":[{"type":"input_text","text":"帮我加个按钮"}],"providerData":{},"sessionId":"s1","cwd":"/tmp/cb"}
        {"id":"c2","timestamp":1782725749600,"type":"message","role":"user","content":[{"type":"input_text","text":"<system-reminder data-role=\"command-caveat\">Caveat: injected</system-reminder>"}],"providerData":{"skipRun":true},"sessionId":"s1","cwd":"/tmp/cb"}
        {"id":"c3","timestamp":1782725750000,"type":"message","role":"assistant","content":[{"type":"text","text":"已加好"},{"type":"tool_use","id":"t9","name":"Edit","input":{"file_path":"/tmp/cb/App.vue"}}],"sessionId":"s1","cwd":"/tmp/cb"}
        {"id":"c4","timestamp":1782725750500,"type":"message","role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"ok"}],"sessionId":"s1","cwd":"/tmp/cb"}
        {"id":"c5","timestamp":1782725750600,"type":"file-history-snapshot","cwd":"/tmp/cb"}

        """#
    }

    /// Codex：同一条消息在 `response_item` 与 `event_msg` 里各写一遍。
    private var codexLines: String {
        #"""
        {"timestamp":"2026-06-15T03:52:02.206Z","type":"session_meta","payload":{"id":"019ec968","cwd":"/tmp/cx","model_provider":"newapi"}}
        {"timestamp":"2026-06-15T03:52:02.209Z","type":"turn_context","payload":{"turn_id":"t-1","cwd":"/tmp/cx","model":"gpt-5.5"}}
        {"timestamp":"2026-06-15T03:52:02.209Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/cx"}]}}
        {"timestamp":"2026-06-15T03:52:02.209Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"把前端换成 shadcn-vue"}]}}
        {"timestamp":"2026-06-15T03:52:02.211Z","type":"event_msg","payload":{"type":"user_message","message":"把前端换成 shadcn-vue","images":[]}}
        {"timestamp":"2026-06-15T03:52:09.590Z","type":"event_msg","payload":{"type":"agent_message","message":"先读项目约定","phase":"commentary"}}
        {"timestamp":"2026-06-15T03:52:09.656Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls -la\"}","call_id":"call_1"}}
        {"timestamp":"2026-06-15T03:52:10.279Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"total 0"}}
        {"timestamp":"2026-06-15T03:52:10.280Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":59555,"cached_input_tokens":30976,"output_tokens":636},"last_token_usage":{"input_tokens":31877,"cached_input_tokens":27520,"output_tokens":350,"reasoning_output_tokens":0,"total_tokens":38456},"model_context_window":258400}}}
        {"timestamp":"2026-06-15T03:55:13.999Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t-1","last_agent_message":"完成"}}

        """#
    }

    /// Gemini：首行是头部记录（没有 `type`），其后每行一条消息。
    private var geminiLines: String {
        #"""
        {"sessionId":"gem-a","projectHash":"8a5edab","startTime":"2026-06-03T07:46:25.124Z","lastUpdated":"2026-06-03T07:46:25.124Z","kind":"main"}
        {"id":"m1","timestamp":"2026-06-03T07:46:30.000Z","type":"user","content":[{"text":"看下这个函数"}]}
        {"id":"m2","timestamp":"2026-06-03T07:46:35.000Z","type":"gemini","content":[{"text":"我先读文件"},{"functionCall":{"name":"read_file","args":{"path":"/tmp/g/a.ts"}}}],"model":"gemini-2.5-pro"}
        {"id":"m3","timestamp":"2026-06-03T07:46:36.000Z","type":"gemini","content":[{"functionResponse":{"name":"read_file","output":"export const a = 1"}}]}
        {"id":"m4","timestamp":"2026-06-03T07:46:37.000Z","type":"info","content":[{"text":"模型重试中"}]}

        """#
    }

    /// Cursor：顶层 `role`，文本外面包着 `<timestamp>` / `<user_query>`。
    private var cursorLines: String {
        #"""
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Monday</timestamp>\n<user_query>\n改成两列布局\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"改好了"},{"type":"tool_use","id":"ct1","name":"edit_file","input":{"path":"/tmp/c/Layout.vue"}}]}}

        """#
    }

    /// Copilot：`user.message_rendered` 是渲染后的提示词，不能当成用户输入。
    private var copilotLines: String {
        #"""
        {"type":"partition.created","data":{"conversationId":"p1"},"id":"e0","timestamp":"2026-04-25T09:12:00.000Z","parentId":null}
        {"type":"user.message","data":{"content":"帮我抽帧","turnId":"t1"},"id":"e1","timestamp":"2026-04-25T09:12:04.959Z","parentId":null}
        {"type":"user.message_rendered","data":{"renderedMessage":"<context>渲染后的提示词</context>","turnId":"t1"},"id":"e2","timestamp":"2026-04-25T09:12:04.960Z","parentId":null}
        {"type":"assistant.message","data":{"content":"","text":"","messageId":"t1","thinking":"…"},"id":"e3","timestamp":"2026-04-25T09:12:05.000Z","parentId":null}
        {"type":"assistant.message","data":{"content":"我来跑一下","text":"我来跑一下","messageId":"t1"},"id":"e4","timestamp":"2026-04-25T09:12:06.000Z","parentId":null}
        {"type":"tool.execution_start","data":{"toolCallId":"call_1","toolName":"list_dir","arguments":{"path":"/tmp/cp"}},"id":"e5","timestamp":"2026-04-25T09:12:10.440Z","parentId":null}
        {"type":"tool.execution_complete","data":{"toolCallId":"call_1","success":true,"result":{"result":[{"type":"text","value":".git/\nREADME.md"}]}},"id":"e6","timestamp":"2026-04-25T09:12:11.000Z","parentId":null}
        {"type":"assistant.turn_end","data":{"turnId":"t1","status":"success","turnStatus":"success"},"id":"e7","timestamp":"2026-04-25T09:12:12.000Z","parentId":null}

        """#
    }

    /// Kimi：一轮由多行拼成（turn.prompt → content.part… → turn.end）。
    private var kimiLines: String {
        #"""
        {"type":"turn.prompt","input":[{"type":"text","text":"第一问"}]}
        {"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"第一答"}}}
        {"type":"turn.end"}
        {"type":"turn.prompt","input":[{"type":"text","text":"第二问"}]}
        {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"第二问"}]}}

        """#
    }

    /// Grok：`type` 为 user/assistant 的行，正文在 `message.content`。
    private var grokLines: String {
        #"""
        {"type":"user","message":{"content":[{"type":"text","text":"写个测试"}]}}
        {"type":"assistant","message":{"content":"已经写好"}}

        """#
    }

    // MARK: Claude 系

    @Test("Claude 系（Qoder）复用 Claude 解析：消息、工具结果、用量都一致")
    func claudeFamilyReusesClaudeParsing() throws {
        for agent in [AgentKind.qoder, .factory] {
            var fixture = try SchemaFixture.jsonl(agent: agent, contents: claudeFamilyLines)
            defer { fixture.cleanup() }

            let result = fixture.read()
            #expect(result.newMessages.count == 2)
            #expect(fixture.state.firstUserMessage == "把首页改成深色")
            #expect(
                result.activity.contains(
                    .toolStarted(id: "t1", name: "Read", input: ["file_path": "/tmp/q/Home.vue"])))
            #expect(result.activity.contains(.toolFinished(id: "t1", name: "Read", isError: false)))
            #expect(fixture.state.completedToolIds.contains("t1"))
            #expect(fixture.state.toolResults["t1"]?.content == "file body")
            // 用量与 Claude 同口径：四路 token 都累加。
            #expect(fixture.state.usage.inputTokens == 10)
            #expect(fixture.state.usage.outputTokens == 4)
            #expect(fixture.state.usage.cacheReadTokens == 7)
            #expect(fixture.state.usage.cacheCreationTokens == 3)
        }
    }

    @Test("CodeBuddy：毫秒时间戳、input_text 块照常产出，注入行被跳过")
    func codeBuddyParsesItsOwnEnvelope() throws {
        var fixture = try SchemaFixture.jsonl(agent: .codeBuddy, contents: codeBuddyLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        // 用户气泡 + 助手气泡；`<system-reminder>` 注入行与 `file-history-snapshot` 不算。
        #expect(result.newMessages.count == 2)
        #expect(result.newMessages.first?.role == .user)
        #expect(result.newMessages.first?.timestamp == Date(timeIntervalSince1970: 1782725749.544))
        #expect(result.newMessages.last?.role == .assistant)
        #expect(result.activity.contains(.promptSubmitted(text: "帮我加个按钮")))
        #expect(
            result.activity.contains(
                .toolStarted(id: "t9", name: "Edit", input: ["file_path": "/tmp/cb/App.vue"])))
        #expect(result.activity.contains(.toolFinished(id: "t9", name: "Edit", isError: false)))
        #expect(fixture.state.toolResults["t9"]?.content == "ok")
    }

    // MARK: Codex

    @Test("Codex：同一条消息写两遍只产出一次，工具与终态事件齐全")
    func codexDeduplicatesMirroredRecords() throws {
        var fixture = try SchemaFixture.jsonl(agent: .codex, contents: codexLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        // 用户 1 条（response_item 与 event_msg 各一遍）、助手 1 条（agent_message 与
        // response_item 各一遍）；AGENTS.md 注入行不算。
        #expect(result.newMessages.count == 2)
        #expect(result.newMessages.map(\.role) == [.user, .assistant])
        #expect(result.activity.contains(.promptSubmitted(text: "把前端换成 shadcn-vue")))
        #expect(
            result.activity.contains(
                .toolStarted(
                    id: "call_1", name: "exec_command", input: ["cmd": "ls -la"])))
        #expect(result.activity.contains(.toolFinished(id: "call_1", name: "exec_command", isError: false)))
        #expect(fixture.state.toolResults["call_1"]?.content == "total 0")
        #expect(result.activity.contains(.turnFinished))
    }

    @Test("Codex：token 用 last_token_usage（不是累计值），输入扣掉缓存读")
    func codexUsesLastTokenUsage() throws {
        var fixture = try SchemaFixture.jsonl(agent: .codex, contents: codexLines)
        defer { fixture.cleanup() }

        _ = fixture.read()
        // last_token_usage: input 31877（含 cached 27520）→ 非缓存输入 4357。
        #expect(fixture.state.usage.inputTokens == 4357)
        #expect(fixture.state.usage.cacheReadTokens == 27520)
        #expect(fixture.state.usage.outputTokens == 350)
        #expect(fixture.state.usage.cacheCreationTokens == 0)
        // 整会话累计值 59555 不能进来（否则一次调用被算成整会话）。
        #expect(fixture.state.usage.inputTokens != 59555)
    }

    // MARK: Gemini / Cursor / Copilot

    @Test("Gemini：头部行不算消息，功能调用产出工具事件，info 行跳过")
    func geminiParsesHeaderAndMessages() throws {
        var fixture = try SchemaFixture.jsonl(agent: .gemini, contents: geminiLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        // 三条消息行里：用户一条、含 functionCall 的助手一条；只有 functionResponse
        // 的那条不产出气泡（它是工具结果），`info` 行整条跳过。
        #expect(result.newMessages.count == 2)
        #expect(result.newMessages.first?.role == .user)
        #expect(result.newMessages.first?.textContent == "看下这个函数")
        #expect(result.activity.contains(.promptSubmitted(text: "看下这个函数")))
        #expect(result.activity.contains { if case .toolStarted(_, let name, _) = $0 { return name == "read_file" }; return false })
        #expect(result.activity.contains { if case .toolFinished(_, let name, _) = $0 { return name == "read_file" }; return false })
        #expect(fixture.state.completedToolIds.count == 1)
        // `info` 行（CLI 提示）不产出内容。
        #expect(!result.newMessages.contains { $0.textContent.contains("模型重试中") })
    }

    @Test("Cursor：剥掉 timestamp/user_query 包装，工具调用照常上报")
    func cursorStripsWrappers() throws {
        var fixture = try SchemaFixture.jsonl(agent: .cursor, contents: cursorLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.count == 2)
        #expect(result.newMessages.first?.textContent == "改成两列布局")
        #expect(result.activity.contains(.promptSubmitted(text: "改成两列布局")))
        #expect(
            result.activity.contains(
                .toolStarted(id: "ct1", name: "edit_file", input: ["path": "/tmp/c/Layout.vue"])))
    }

    @Test("Copilot：message_rendered 不算用户消息，空助手消息不产出气泡")
    func copilotIgnoresRenderedPrompt() throws {
        var fixture = try SchemaFixture.jsonl(agent: .copilot, contents: copilotLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        // 用户 1 条（rendered 那条忽略）+ 助手 1 条（content/text 都空的那条忽略）。
        #expect(result.newMessages.count == 2)
        #expect(result.newMessages.map(\.role) == [.user, .assistant])
        #expect(result.newMessages.first?.textContent == "帮我抽帧")
        #expect(!result.newMessages.contains { $0.textContent.contains("渲染后的提示词") })
        #expect(
            result.activity.contains(
                .toolStarted(id: "call_1", name: "list_dir", input: ["path": "/tmp/cp"])))
        #expect(fixture.state.toolResults["call_1"]?.content == ".git/\nREADME.md")
        #expect(result.activity.contains(.turnFinished))
    }

    // MARK: Kimi / Grok

    @Test("Kimi：一轮由多行拼成，助手文本在轮次收尾时产出")
    func kimiAssemblesTurns() throws {
        var fixture = try SchemaFixture.jsonl(agent: .kimi, contents: kimiLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        // 用户两轮各一条；第一轮的助手文本在 `turn.end` 时产出，第二轮的还没收尾。
        #expect(result.newMessages.count == 3)
        #expect(result.newMessages.map(\.role) == [.user, .assistant, .user])
        #expect(result.newMessages[1].textContent == "第一答")
        #expect(result.activity.contains(.promptSubmitted(text: "第一问")))
        #expect(result.activity.contains(.promptSubmitted(text: "第二问")))

        // 第二轮补上内容并收尾后，助手文本才产出（且只一次）。
        try fixture.append(
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"第二答"}}}"#
                + "\n" + #"{"type":"turn.end"}"# + "\n")
        let finished = fixture.read()
        #expect(finished.newMessages.map(\.role) == [.assistant])
        #expect(finished.newMessages.first?.textContent == "第二答")
        #expect(fixture.read().newMessages.isEmpty)
    }

    @Test("Grok：用户行产出气泡与提交事件，字符串正文照常解析")
    func grokParsesRows() throws {
        var fixture = try SchemaFixture.jsonl(agent: .grok, contents: grokLines)
        defer { fixture.cleanup() }

        let result = fixture.read()
        #expect(result.newMessages.count == 2)
        #expect(result.newMessages.map(\.role) == [.user, .assistant])
        #expect(result.newMessages.last?.textContent == "已经写好")
        #expect(result.activity.contains(.promptSubmitted(text: "写个测试")))
    }

    // MARK: Cline（整文档 JSON）

    @Test("Cline：整文档 JSON 按条数增量，重写时重置并重放")
    func clineIncrementalAndReset() throws {
        let scratch = try SchemaFixture.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let schema = TempFileClineSchema(fileURL: scratch.file)

        let first = #"[{"role":"user","content":"第一问"},{"role":"assistant","content":[{"type":"text","text":"第一答"}]}]"#
        try first.write(to: scratch.file, atomically: true, encoding: .utf8)

        var state = TranscriptParseState()
        let initial = schema.read(sessionId: "s1", cwd: "/tmp/cl", state: &state)
        #expect(initial.newMessages.count == 2)
        #expect(initial.isNewContent)

        // 追加一条：只产出新增的那条，不重复前两条。
        let appended =
            #"[{"role":"user","content":"第一问"},{"role":"assistant","content":[{"type":"text","text":"第一答"}]},{"role":"user","content":"第二问"}]"#
        try appended.write(to: scratch.file, atomically: true, encoding: .utf8)
        let incremental = schema.read(sessionId: "s1", cwd: "/tmp/cl", state: &state)
        #expect(incremental.newMessages.count == 1)
        #expect(incremental.newMessages.first?.textContent == "第二问")
        #expect(!incremental.resetDetected)

        // 重写成更短的内容：整源重置并重放。
        let rewritten = #"[{"role":"user","content":"重写后的问题"}]"#
        try rewritten.write(to: scratch.file, atomically: true, encoding: .utf8)
        let afterRewrite = schema.read(sessionId: "s1", cwd: "/tmp/cl", state: &state)
        #expect(afterRewrite.resetDetected)
        #expect(afterRewrite.newMessages.count == 1)
        #expect(afterRewrite.newMessages.first?.textContent == "重写后的问题")
        #expect(state.messages.count == 1)
    }

    // MARK: 增量与重写（JSONL）

    @Test("JSONL：追加只产出新内容，文件被截断时从头重来")
    func jsonlIncrementalAndTruncate() throws {
        var fixture = try SchemaFixture.jsonl(agent: .codex, contents: codexLines)
        defer { fixture.cleanup() }

        let initial = fixture.read()
        #expect(initial.newMessages.count == 2)
        #expect(fixture.read().newMessages.isEmpty)

        try fixture.append(
            #"{"timestamp":"2026-06-15T03:56:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"再改一处"}}"#
                + "\n")
        let appended = fixture.read()
        #expect(appended.newMessages.count == 1)
        #expect(appended.newMessages.first?.textContent == "再改一处")

        // 截断（整体重写变小）：从头重读，内容重新产出。
        try fixture.overwrite(
            #"{"timestamp":"2026-06-15T03:57:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"只剩这句"}}"#
                + "\n")
        let truncated = fixture.read()
        #expect(truncated.newMessages.count == 1)
        #expect(truncated.newMessages.first?.textContent == "只剩这句")
    }

    // MARK: 注册表

    @Test("注册表覆盖全部有记录的 Agent，没有记录的走空解析器")
    func registryCoversRecordBearingAgents() {
        // 没有可解析记录的三个：Trae / Trae CLI 不落盘，DSH 的记录是 zstd 压缩。
        let withoutRecords: Set<AgentKind> = [.trae, .traeCli, .deepSeekHarness]

        for kind in AgentKind.allCases {
            let schema = AgentTranscriptSchemaRegistry.schema(for: kind)
            // 认错 Agent 会让记录按别的布局去读，因此每个 schema 都要自报本家。
            #expect(schema.agent == kind)
            if withoutRecords.contains(kind) {
                #expect(schema is EmptyTranscriptSchema)
                #expect(schema.transcriptFile(sessionId: "s", cwd: "/tmp") == nil)
            } else {
                // 新增 Agent 忘了注册时会掉进空解析器，这条断言就是那道门。
                #expect(!(schema is EmptyTranscriptSchema))
            }
        }
    }

    @Test("没有记录可解析的 Agent 读记录不产出任何内容，也不崩")
    func emptySchemaProducesNothing() {
        for kind in [AgentKind.trae, .traeCli, .deepSeekHarness] {
            var state = TranscriptParseState()
            let schema = AgentTranscriptSchemaRegistry.schema(for: kind)
            let result = schema.read(sessionId: "s", cwd: "/tmp", state: &state)
            #expect(result.newMessages.isEmpty)
            #expect(result.activity.isEmpty)
            #expect(!result.isNewContent)
        }
    }
}

@Suite("各 Agent 的用量抽取")
struct AgentTranscriptUsageScannerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }()

    private func fixtureFile(_ lines: String, name: String = "session.jsonl") throws -> (
        directory: URL, file: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try lines.write(to: file, atomically: true, encoding: .utf8)
        return (directory, file)
    }

    @Test("Codex：token 归到 turn_context 记下的模型，工具调用单独成行")
    func codexTokensCarryModel() throws {
        let lines = #"""
        {"timestamp":"2026-06-15T03:52:02.209Z","type":"turn_context","payload":{"turn_id":"t-1","model":"gpt-5.5"}}
        {"timestamp":"2026-06-15T03:52:10.280Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":31877,"cached_input_tokens":27520,"output_tokens":350}}}}
        {"timestamp":"2026-06-15T03:52:10.281Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"call_1"}}

        """#
        let scratch = try fixtureFile(lines)
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let source = UsageSourceFile(
            path: scratch.file.path, agent: .codex, sessionId: "019ec968")
        let first = TranscriptUsageScanner.read(
            source: source, previous: nil, calendar: calendar)

        let tokens = try #require(first.deltas.first { $0.tool == "" })
        #expect(tokens.model == "gpt-5.5")
        #expect(tokens.input == 4357)
        #expect(tokens.cacheRead == 27520)
        #expect(tokens.output == 350)
        let calls = try #require(first.deltas.first { $0.tool != "" })
        #expect(calls.tool == "exec_command")
        #expect(calls.calls == 1)
        // 工具行不带模型（模型榜只按 token 行拆）。
        #expect(calls.model == "")

        // 下一批文件里只有 token 行、没有 turn_context：模型要从进度里带过来
        // （文件更短，会走「整源重放」，模型仍然取上一次记住的那个）。
        try #"{"timestamp":"2026-06-15T03:53:10.280Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5}}}}"#
            .appending("\n")
            .write(to: scratch.file, atomically: true, encoding: .utf8)

        let second = TranscriptUsageScanner.read(
            source: source, previous: first.state, calendar: calendar)
        let nextTokens = try #require(second.deltas.first { $0.tool == "" })
        #expect(nextTokens.model == "gpt-5.5")
        #expect(nextTokens.input == 100)
    }

    @Test("没有 token 字段的 Agent 不产出 token（Copilot 只留下工具行）")
    func copilotProducesToolRowsOnly() throws {
        let lines = #"""
        {"type":"user.message","data":{"content":"帮我抽帧"},"id":"e1","timestamp":"2026-04-25T09:12:04.959Z","parentId":null}
        {"type":"tool.execution_start","data":{"toolCallId":"call_1","toolName":"list_dir","arguments":{}},"id":"e5","timestamp":"2026-04-25T09:12:10.440Z","parentId":null}

        """#
        let scratch = try fixtureFile(lines)
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let result = TranscriptUsageScanner.read(
            source: UsageSourceFile(path: scratch.file.path, agent: .copilot, sessionId: "s1"),
            previous: nil, calendar: calendar)

        // 本机 9 个事件文件里没有任何 token 字段 ⇒ 一条 token 行都不该有。
        #expect(result.deltas.allSatisfy { $0.tool != "" })
        #expect(result.deltas.allSatisfy { $0.input == 0 && $0.output == 0 && $0.cacheRead == 0 })
        #expect(result.deltas.contains { $0.tool == "list_dir" && $0.calls == 1 })
    }

    @Test("无法核对 token 字段的 Agent（Gemini / Kimi / Grok）一条用量都不产出")
    func agentsWithoutVerifiedTokensProduceNoUsage() throws {
        let fixtures: [(AgentKind, String)] = [
            (.gemini, #"{"id":"m2","type":"gemini","content":[{"text":"答"}],"model":"gemini-2.5-pro","tokens":{"input":1,"output":1}}"#),
            (.kimi, #"{"type":"turn.prompt","input":[{"type":"text","text":"问"}]}"#),
            (.grok, #"{"type":"assistant","message":{"content":"答"}}"#),
        ]

        for (agent, line) in fixtures {
            let scratch = try fixtureFile(line + "\n\n")
            defer { try? FileManager.default.removeItem(at: scratch.directory) }

            let result = TranscriptUsageScanner.read(
                source: UsageSourceFile(path: scratch.file.path, agent: agent, sessionId: "s1"),
                previous: nil, calendar: calendar)
            #expect(result.deltas.isEmpty, "\(agent.rawValue) 不该产出用量")
        }
    }
}