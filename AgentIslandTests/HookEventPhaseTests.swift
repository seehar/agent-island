//
//  HookEventPhaseTests.swift
//  AgentIslandTests
//
//  实时事件到会话相位的映射，以及 HookEvent 自身的字段语义。这一层决定「卡片显示
//  什么状态」，且完全由字段决定。Models/SessionEvent.swift 属并行会话的未提交改动，
//  本文件只读、只断言当前行为。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("HookEvent 阶段映射")
struct HookEventPhaseTests {
    private func hook(
        _ event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil,
        notificationType: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: "phase-test", cwd: "/tmp/island-phase-tests", event: event, status: status,
            pid: nil, tty: nil, tool: tool, toolInput: nil, toolUseId: toolUseId,
            notificationType: notificationType, message: nil)
    }

    private func approvalToolName(_ phase: SessionPhase) -> String? {
        if case .waitingForApproval(let context) = phase { return context.toolName }
        return nil
    }

    @Test("压缩事件优先于审批与状态：一律映射为压缩中")
    func preCompactAlwaysWins() {
        #expect(hook("PreCompact", status: "waiting_for_input").determinePhase() == SessionPhase.compacting)
        #expect(
            hook("PreCompact", status: "waiting_for_approval", tool: "Bash", toolUseId: "t1")
                .determinePhase() == SessionPhase.compacting)
    }

    @Test("权限请求映射为待审批并带上工具上下文")
    func permissionRequestMapsToApproval() {
        let event = hook("PermissionRequest", status: "waiting_for_approval", tool: "Bash", toolUseId: "t1")
        #expect(event.expectsResponse)

        let phase = event.determinePhase()
        guard case .waitingForApproval(let context) = phase else {
            Issue.record("权限请求应映射为待审批，实际是 \(phase)")
            return
        }
        #expect(context.toolName == "Bash")
        #expect(context.toolUseId == "t1")
    }

    @Test("权限请求缺少工具名时不进入待审批，也不崩")
    func permissionRequestWithoutToolFallsThrough() {
        let event = hook("PermissionRequest", status: "waiting_for_approval")
        // expectsResponse 仍为真（socket 层据此登记待答复请求），但相位判定拿不到工具名
        #expect(event.expectsResponse)
        #expect(event.determinePhase() == SessionPhase.idle)
    }

    @Test("来自 pi/omp/opencode 的审批事件用占位工具名兜底")
    func toolApprovalUsesPlaceholderName() {
        #expect(
            approvalToolName(hook("ToolApproval", status: "waiting_for_approval").determinePhase()) == "Tool")
        #expect(
            approvalToolName(
                hook("ToolApproval", status: "waiting_for_approval", tool: "bash").determinePhase()) == "bash")
    }

    @Test("idle_prompt 通知映射为空闲，且优先于 status")
    func idlePromptNotificationWins() {
        #expect(
            hook("Notification", status: "waiting_for_input", notificationType: "idle_prompt")
                .determinePhase() == SessionPhase.idle)
        #expect(
            hook("Notification", status: "waiting_for_input", notificationType: "other")
                .determinePhase() == SessionPhase.waitingForInput)
    }

    @Test("运行中的三种状态都映射为处理中")
    func runningStatusesMapToProcessing() {
        for status in ["running_tool", "processing", "starting"] {
            #expect(hook("PreToolUse", status: status).determinePhase() == SessionPhase.processing)
        }
    }

    @Test("等待输入状态映射为等待输入")
    func waitingForInputStatusMaps() {
        #expect(hook("Stop", status: "waiting_for_input").determinePhase() == SessionPhase.waitingForInput)
    }

    @Test("未知事件与未知状态映射为空闲且不崩")
    func unknownEventAndStatusFallBackToIdle() {
        #expect(hook("SomeFutureEvent", status: "").determinePhase() == SessionPhase.idle)
        #expect(hook("", status: "waiting_for_approval").determinePhase() == SessionPhase.idle)
    }

    @Test("最小事件能解码，缺省字段按 Claude 处理")
    func minimalEventDecodesAsClaude() throws {
        let json = #"{"session_id":"s1","cwd":"/tmp/x","event":"Stop","status":"waiting_for_input"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

        #expect(event.sessionId == "s1")
        #expect(event.pid == nil)
        #expect(event.tty == nil)
        #expect(event.tool == nil)
        #expect(event.notificationType == nil)
        #expect(event.agentKind == AgentKind.claudeCode)
        #expect(event.sessionKey == SessionKey(agent: .claudeCode, sessionId: "s1"))
        #expect(event.determinePhase() == SessionPhase.waitingForInput)
    }

    @Test("协议里不认识的 agent 取值也按 Claude 处理")
    func unknownAgentFallsBackToClaude() {
        let event = HookEvent(
            sessionId: "s2", cwd: "/tmp/x", event: "Stop", status: "waiting_for_input", pid: nil,
            tty: nil, tool: nil, toolInput: nil, toolUseId: nil, notificationType: nil, message: nil,
            agent: "some-future-agent", sessionFile: nil)
        #expect(event.agentKind == AgentKind.claudeCode)
    }

    @Test("只有会改变记录的事件才触发记录同步")
    func shouldSyncFileWhitelist() {
        for name in [
            "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "ToolApproval", "Stop",
        ] {
            #expect(hook(name, status: "processing").shouldSyncFile, "\(name) 应触发记录同步")
        }
        for name in ["SessionStart", "Notification", "PreCompact"] {
            #expect(!hook(name, status: "processing").shouldSyncFile, "\(name) 不该触发记录同步")
        }
    }

    @Test("只有工具相关事件算工具事件")
    func isToolEventWhitelist() {
        for name in ["PreToolUse", "PostToolUse", "PermissionRequest", "ToolApproval"] {
            #expect(hook(name, status: "processing").isToolEvent, "\(name) 应算工具事件")
        }
        for name in ["Notification", "Stop", "SessionStart"] {
            #expect(!hook(name, status: "processing").isToolEvent, "\(name) 不该算工具事件")
        }
    }
}
