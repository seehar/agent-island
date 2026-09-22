//
//  OpenCodeAskChannelTests.swift
//  AgentIslandTests
//
//  OpenCode 的交互提问（`question` 工具）走的是「作答」通道而不是「批准」通道：插件把
//  `question.asked` 报成 `ToolApproval` + `ask` 载荷，应用再按工具名把它认成交互工具。
//  本文件钉住这条接缝的两端——真机信封能解码出问题集并映射成「等待作答」相位，且没有
//  人把批准语义的工具名误认成交互工具（认错会让卡片给出对提问毫无意义的 Allow/Deny）。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("OpenCode 提问通道")
struct OpenCodeAskChannelTests {
    /// 真机抓包：opencode 1.18.32 + 插件 v3（模型 `opencode/mimo-v2.6-flash-free`）在一次
    /// `question` 工具调用里发给应用的完整上行信封，逐字取自探针 socket 的记录，只把
    /// 会话名与 requestID 换成探针值。
    private static let envelope = """
        {"session_id":"ses_probe","cwd":"/tmp","pid":1,"tty":null,"agent":"opencode",\
        "event":"ToolApproval","status":"waiting_for_approval","expects_response":true,\
        "tool":"question","tool_use_id":"que_probe",\
        "tool_input":{"questions":[{"question":"今晚吃哪种菜系？","header":"今晚菜系",\
        "options":[{"label":"川菜","description":"四川菜，麻辣鲜香"},\
        {"label":"粤菜","description":"广东菜，清淡鲜美"},\
        {"label":"日料","description":"日本料理，精致新鲜"}],"multiple":false}]},\
        "ask":{"questions":[{"id":"q0","question":"今晚吃哪种菜系？","header":"今晚菜系",\
        "options":[{"label":"川菜","description":"四川菜，麻辣鲜香"},\
        {"label":"粤菜","description":"广东菜，清淡鲜美"},\
        {"label":"日料","description":"日本料理，精致新鲜"}],"multi_select":false,"free_text":false}]}}
        """

    private func decodeEnvelope() throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(Self.envelope.utf8))
    }

    @Test("插件的提问信封：登记为待批、相位是「等待作答」、问题集完整")
    func askEnvelopeDecodes() throws {
        let event = try decodeEnvelope()

        #expect(event.agentKind == .opencode)
        // 必须登记成待批：否则刘海不会保留那条连接，答案也就回不去。
        #expect(event.expectsResponse)

        guard case .waitingForApproval(let context) = event.determinePhase() else {
            Issue.record("提问信封应映射为等待作答，实际是 \(event.determinePhase())")
            return
        }
        // 相位里带的是提问工具名——卡片据此走作答分支而不是批准分支。
        #expect(context.toolName == "question")
        #expect(context.toolUseId == "que_probe")

        let question = try #require(event.ask?.questions.first)
        #expect(question.id == "q0")
        #expect(question.question == "今晚吃哪种菜系？")
        #expect(question.header == "今晚菜系")
        #expect(question.multiSelect == false)
        #expect(question.freeText == false)
        #expect(question.options.map(\.label) == ["川菜", "粤菜", "日料"])
        #expect(question.options.first?.description == "四川菜，麻辣鲜香")
    }

    @Test("opencode：question 是交互工具，批准语义的工具名不受影响")
    func openCodeQuestionIsInteractive() {
        #expect(AgentKind.opencode.isInteractiveTool("question"))
        // 批准语义的工具名不能落进作答分支，否则 Allow/Deny 会是一副对提问无效的按钮。
        for tool in ["bash", "edit", "write", "webfetch"] {
            #expect(!AgentKind.opencode.isInteractiveTool(tool))
        }
        // 提问是各 Agent 各自的工具名：`question` 不该改变 Claude / omp 的判定。
        #expect(AgentKind.claudeCode.isInteractiveTool("AskUserQuestion"))
        #expect(!AgentKind.claudeCode.isInteractiveTool("question"))
        #expect(AgentKind.ohMyPi.isInteractiveTool("ask"))
        #expect(!AgentKind.ohMyPi.isInteractiveTool("question"))
    }
}
