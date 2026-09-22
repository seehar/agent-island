//
//  SessionPhaseTests.swift
//  AgentIslandTests
//
//  相位的合法转移表与语义开关。SessionStore 收到非法转移时会「忽略」而不是崩溃，
//  因此这张表本身就是可观测行为：它决定了哪些事件会真的改变卡片状态。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("会话相位状态机")
struct SessionPhaseTests {
    private var approval: SessionPhase {
        .waitingForApproval(
            PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: Date()))
    }

    @Test("结束态是终态：转不到任何相位")
    func endedIsTerminal() {
        for phase in [SessionPhase.idle, .processing, .waitingForInput, .compacting, .ended, approval] {
            #expect(!SessionPhase.ended.canTransition(to: phase))
        }
    }

    @Test("任何相位都可以结束")
    func everyPhaseCanEnd() {
        for phase in [SessionPhase.idle, .processing, .waitingForInput, .compacting, approval] {
            #expect(phase.canTransition(to: .ended))
        }
    }

    @Test("空闲态不能直接跳到等待输入，transition 返回 nil")
    func idleCannotJumpToWaitingForInput() {
        #expect(!SessionPhase.idle.canTransition(to: .waitingForInput))
        #expect(SessionPhase.idle.transition(to: .waitingForInput) == nil)
    }

    @Test("待审批可以换成另一个待审批（多个工具同时等审批）")
    func approvalCanReplaceApproval() {
        let next = SessionPhase.waitingForApproval(
            PermissionContext(toolUseId: "t2", toolName: "Write", toolInput: nil, receivedAt: Date()))
        #expect(approval.canTransition(to: next))
    }

    @Test("处理中与压缩中的常见转移")
    func processingTransitions() {
        #expect(SessionPhase.processing.canTransition(to: .idle))
        #expect(SessionPhase.processing.canTransition(to: .waitingForInput))
        #expect(SessionPhase.compacting.canTransition(to: .processing))
        #expect(!SessionPhase.compacting.canTransition(to: .ended) == false)
    }

    @Test("相位语义：需要用户注意 / 正在活动 / 审批工具名")
    func phaseSemantics() {
        #expect(approval.needsAttention)
        #expect(SessionPhase.waitingForInput.needsAttention)
        #expect(!SessionPhase.processing.needsAttention)
        #expect(SessionPhase.processing.isActive)
        #expect(SessionPhase.compacting.isActive)
        #expect(!SessionPhase.idle.isActive)
        #expect(approval.approvalToolName == "Bash")
        #expect(SessionPhase.idle.approvalToolName == nil)
        #expect(approval.isWaitingForApproval)
        #expect(!SessionPhase.idle.isWaitingForApproval)
    }

    @Test("进程消失时的可结束判据：等用户输入的相位不标结束")
    func pausabilityWhenProcessGone() {
        #expect(SessionPhase.processing.isPausableWhenProcessGone())
        #expect(SessionPhase.compacting.isPausableWhenProcessGone())
        #expect(approval.isPausableWhenProcessGone())
        #expect(SessionPhase.ended.isPausableWhenProcessGone())
        #expect(!SessionPhase.idle.isPausableWhenProcessGone())
        #expect(!SessionPhase.waitingForInput.isPausableWhenProcessGone())
    }

    @Test("待批在手时，状态上报不许把相位从「等待审批」推回处理中")
    func pendingHoldsApprovalPhase() {
        // 闸门版集成先发闸门信封、后发 PreToolUse：那条 PreToolUse 若把相位推回 processing，
        // 卡片就消失了，而应用还攥着连接等一个点不到的决定（报障的根因）。
        #expect(
            SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .processing, hasLivePending: true))
        // 没有待批在等时，状态上报照旧生效（应用重启后丢了待批的连接也走这条）。
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .processing, hasLivePending: false))
        // 别的相位、别的目标相位都不归这条判据管。
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: .processing, next: .processing, hasLivePending: true))
        // 这三类是真实信号，照旧放行：Stop（终端已收手）、压缩活动、会话结束。
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .waitingForInput, hasLivePending: true))
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .compacting, hasLivePending: true))
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .ended, hasLivePending: true))
    }

    @Test("待批在手时，空闲上报不许把卡片抹掉")
    func pendingHoldsAgainstIdle() {
        // 「什么都没发生」的描述（发现补登的 SessionStart/idle、Claude 的 idle_prompt 通知）
        // 会把相位推回空闲 → 卡片消失而待批连接还挂着（2026-09-22 实测的报障）。
        #expect(
            SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .idle, hasLivePending: true))
        // 没有待批在等时照旧生效；当前相位不是等待审批时也不归它管。
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: approval, next: .idle, hasLivePending: false))
        #expect(
            !SessionPhase.statusUpdateBlockedByPending(
                current: .idle, next: .idle, hasLivePending: true))
    }

    @Test("审批上下文只按工具 id、工具名与到达时间比较")
    func approvalContextIdentity() {
        let receivedAt = Date()
        let first = PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: receivedAt)
        let same = PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: receivedAt)
        let other = PermissionContext(toolUseId: "t2", toolName: "Bash", toolInput: nil, receivedAt: receivedAt)

        #expect(first == same)
        #expect(first != other)
        #expect(SessionPhase.waitingForApproval(first) == SessionPhase.waitingForApproval(same))
    }
}
