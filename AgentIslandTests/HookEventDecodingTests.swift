//
//  HookEventDecodingTests.swift
//  AgentIslandTests
//
//  `HookEvent` 的两条守护——都是这两轮改动建立/依赖的字段面：
//
//  1. `expectsResponse` 判定矩阵：它决定「谁会被登记成待批」，判错会让卡片凭空出现
//     （只展示的集成被误登记）或永不出现（真待批被当成只展示）；
//  2. 新字段解码 + **老信封兼容**：老集成不带 `expects_response` / `approval_kind` /
//     `degradation` / `gate_enabled` / `omp_owns_approval` / `ask` 时必须照样解码成功，
//     并退回「普通档 + 不登记 + 无提问」的缺省语义。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("HookEvent.expectsResponse 判定矩阵")
struct HookEventExpectsResponseTests {
    /// 用 JSON 构造事件：socket 上就是这么到达的，顺带覆盖解码路径。
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    private func envelope(
        event: String, status: String, extraKeys: String = ""
    ) -> String {
        """
        {"session_id": "expects-test", "cwd": "/tmp", "event": "\(event)", \
        "status": "\(status)"\(extraKeys)}
        """
    }

    @Test("Claude 旧契约：PermissionRequest + waiting_for_approval 要回传（逐字不变）")
    func permissionRequestExpectsResponse() throws {
        let event = try decode(envelope(event: "PermissionRequest", status: "waiting_for_approval"))
        #expect(event.expectsResponse)
    }

    @Test("PermissionRequest 不在等待态时不登记")
    func permissionRequestOtherStatusDoesNotExpect() throws {
        let event = try decode(envelope(event: "PermissionRequest", status: "processing"))
        #expect(!event.expectsResponse)
    }

    @Test("omp/pi 新契约：ToolApproval + expects_response 要回传")
    func toolApprovalWithFlagExpectsResponse() throws {
        let event = try decode(
            envelope(
                event: "ToolApproval", status: "waiting_for_approval",
                extraKeys: #", "tool": "bash", "expects_response": true"#))
        #expect(event.expectsResponse)
    }

    @Test("只展示的集成：ToolApproval 不带 expects_response 一律不登记")
    func toolApprovalWithoutFlagDoesNotExpect() throws {
        let event = try decode(
            envelope(
                event: "ToolApproval", status: "waiting_for_approval",
                extraKeys: #", "tool": "bash", "omp_owns_approval": true"#))
        #expect(!event.expectsResponse)
    }

    @Test("ToolApproval 带 expects_response 但不在等待态：不登记")
    func toolApprovalWrongStatusDoesNotExpect() throws {
        let event = try decode(
            envelope(
                event: "ToolApproval", status: "processing",
                extraKeys: #", "expects_response": true"#))
        #expect(!event.expectsResponse)
    }

    @Test("其它事件一律不回传（PostToolUse / Stop / Notification）")
    func otherEventsDoNotExpectResponse() throws {
        for event in ["PostToolUse", "PostToolUseFailure", "Stop", "Notification", "SessionEnd"] {
            let decoded = try decode(
                envelope(event: event, status: "waiting_for_approval", extraKeys: #", "expects_response": true"#))
            #expect(!decoded.expectsResponse, "\(event) 不该被登记成待批")
        }
    }

    @Test("内存构造（不走 JSON）时缺省同样不登记")
    func memberwiseDefaultDoesNotExpect() {
        let event = HookEvent(
            sessionId: "expects-test", cwd: "/tmp", event: "ToolApproval", status: "waiting_for_approval",
            pid: nil, tty: nil, tool: "bash", toolInput: nil, toolUseId: "t1",
            notificationType: nil, message: nil)
        #expect(!event.expectsResponse)
        #expect(!event.withToolUseId("t2").expectsResponse)
    }
}

@Suite("HookEvent 新字段解码与老信封兼容")
struct HookEventDecodingTests {
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test("完整信封：展示档位与 ask 负载逐个落位")
    func fullEnvelopeDecodesEveryField() throws {
        let event = try decode(
            """
            {
              "session_id": "decode-full", "cwd": "/tmp/work", "event": "ToolApproval",
              "status": "waiting_for_approval", "pid": 42, "tty": "/dev/ttys001",
              "tool": "ask", "tool_use_id": "call_1", "agent": "omp",
              "expects_response": true, "approval_kind": "critical",
              "degradation": "strict", "gate_enabled": false, "omp_owns_approval": true,
              "ask": {"questions": [
                {"id": "q1", "question": "选哪个？", "header": "方案",
                 "multi_select": false, "free_text": true,
                 "options": [{"label": "A", "description": "第一个"}, {"label": "B"}]}
              ]}
            }
            """)

        #expect(event.wantsResponse == true)
        #expect(event.approvalKind == "critical")
        #expect(event.degradation == "strict")
        #expect(event.gateEnabled == false)
        #expect(event.ompOwnsApproval == true)
        #expect(event.expectsResponse)
        #expect(event.agentKind == .ohMyPi)

        // 展示档位的派生语义
        #expect(event.isCriticalApproval)
        #expect(event.isGateDegraded)

        // ask 负载
        let ask = event.ask
        #expect(ask?.questions.count == 1)
        let question = ask?.questions.first
        #expect(question?.id == "q1")
        #expect(question?.question == "选哪个？")
        #expect(question?.header == "方案")
        #expect(question?.multiSelect == false)
        #expect(question?.freeText == true)
        #expect(question?.options.count == 2)
        #expect(question?.options.first?.label == "A")
        #expect(question?.options.first?.description == "第一个")
        #expect(question?.options.last?.description == nil)
    }

    @Test("ask 缺省值：multi_select / free_text 缺省按 false，options 缺省空数组")
    func askQuestionDefaultsAreTolerant() throws {
        let event = try decode(
            """
            {"session_id": "decode-defaults", "cwd": "/tmp", "event": "ToolApproval",
             "status": "waiting_for_approval", "expects_response": true,
             "ask": {"questions": [{"id": "q1", "question": "只能打字？"}]}}
            """)
        let question = event.ask?.questions.first
        #expect(question?.multiSelect == false)
        #expect(question?.freeText == false)
        #expect(question?.options.isEmpty == true)
        #expect(question?.header == nil)
    }

    @Test("老信封（完全没有新键）解码不失败，且语义退回缺省")
    func legacyEnvelopeStaysCompatible() throws {
        let event = try decode(
            """
            {"session_id": "decode-legacy", "cwd": "/tmp", "event": "PermissionRequest",
             "status": "waiting_for_approval", "tool": "Bash", "tool_use_id": "toolu_1"}
            """)

        #expect(event.wantsResponse == nil)
        #expect(event.approvalKind == nil)
        #expect(event.degradation == nil)
        #expect(event.gateEnabled == nil)
        #expect(event.ompOwnsApproval == nil)
        #expect(event.ask == nil)
        #expect(event.agent == nil)
        #expect(event.agentKind == .claudeCode)
        #expect(!event.isCriticalApproval)
        #expect(!event.isGateDegraded)
        // 老 Claude 契约照旧登记
        #expect(event.expectsResponse)
    }

    @Test("未知键不影响解码（集成先于应用升级时不炸）")
    func unknownKeysAreIgnored() throws {
        let event = try decode(
            """
            {"session_id": "decode-unknown", "cwd": "/tmp", "event": "ToolApproval",
             "status": "waiting_for_approval", "expects_response": true,
             "future_field": {"nested": [1, 2, 3]}, "another_one": "x"}
            """)
        #expect(event.expectsResponse)
        #expect(event.ask == nil)
    }
}
