//
//  ApprovalScopeEnforcementTests.swift
//  AgentIslandTests
//
//  应用侧的档位兜底判据（HookEvent.isAutoAllowedByScope）：档位外的调用由应用直接回
//  `allow`，不上卡。这里只钉判据本身——它决定「哪条许可可以不经用户点按」，因此每条
//  档位 × 档位取值 × 信封形状都要有明确结论，尤其是**不该放行**的那些。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("档位兜底：哪条待批可以不上卡")
struct ApprovalScopeEnforcementTests {
    private func gate(
        kind: String? = nil,
        event: String = "ToolApproval",
        status: String = "waiting_for_approval",
        wantsResponse: Bool? = true,
        ask: AskPayload? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: "scope-test", cwd: "/tmp/island-scope-tests", event: event, status: status,
            pid: nil, tty: nil, tool: "bash", toolInput: nil, toolUseId: "call_1",
            notificationType: nil, message: nil, agent: "omp", sessionFile: nil,
            subagentId: nil, subagentAgent: nil, subagentStatus: nil,
            subagentCurrentTool: nil, subagentTask: nil, parentToolCallId: nil,
            subagentSessionFile: nil, wantsResponse: wantsResponse, approvalKind: kind, ask: ask
        )
    }

    @Test("档位语义表：会拦的只有「都问」与「只问危险命令」两档，其余档位一律不问")
    func scopeDecisionMatrix() {
        for scope in ApprovalAskScope.allCases {
            let write = gate(kind: "write").isAutoAllowedByScope(scope)
            let exec = gate(kind: "exec").isAutoAllowedByScope(scope)
            let critical = gate(kind: "critical").isAutoAllowedByScope(scope)
            let unknown = gate(kind: nil).isAutoAllowedByScope(scope)
            // 写档与执行档同进同出：分档只影响卡片的展示强度，不影响档位的取舍。
            #expect(write == exec)
            if scope == .writesAndExec {
                #expect(write == false)
                #expect(critical == false)
                #expect(unknown == false)
            } else if scope == .criticalOnly {
                #expect(write)
                #expect(critical == false)
                #expect(unknown == false)
            } else {
                // 其余档位（当前只有「始终允许」）：一律不问。
                #expect(write)
                #expect(critical)
                #expect(unknown)
            }
        }
    }

    @Test("提问信封不放行：那是「要回答」，放行等于取消提问")
    func askPayloadNeverAutoAllowed() {
        let payload = AskPayload(questions: [AskQuestion(id: "q1", question: "Which one?")])
        for scope in ApprovalAskScope.allCases {
            #expect(gate(kind: "exec", ask: payload).isAutoAllowedByScope(scope) == false)
        }
    }

    @Test("Claude 的 PermissionRequest 不放行：档位只约定闸门类 Agent")
    func claudePermissionRequestNotAutoAllowed() {
        for scope in ApprovalAskScope.allCases {
            #expect(gate(kind: "exec", event: "PermissionRequest").isAutoAllowedByScope(scope) == false)
        }
    }

    @Test("只展示的信封不放行：没有等应答的连接，也无从「放行」")
    func displayOnlyEnvelopeNotAutoAllowed() {
        for scope in ApprovalAskScope.allCases {
            // 集成显式声明「不要求应答」（omp 自己在终端问的让位信号）。
            #expect(gate(kind: "exec", wantsResponse: false).isAutoAllowedByScope(scope) == false)
            #expect(gate(kind: "exec", wantsResponse: nil).isAutoAllowedByScope(scope) == false)
            // 状态不是等待态：与 `expectsResponse` 同一判据，不会漂移成悬挂连接。
            #expect(gate(kind: "exec", status: "running_tool").isAutoAllowedByScope(scope) == false)
        }
    }
}
