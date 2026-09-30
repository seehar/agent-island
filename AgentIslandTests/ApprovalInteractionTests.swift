//
//  ApprovalInteractionTests.swift
//  AgentIslandTests
//
//  审批与滚动交互里的纯判据。三组判据都在视图外抽成了 `nonisolated` 类型，因此可以
//  直接钉住，不必渲染 SwiftUI：
//    * 审批主按钮的形态（危险档必须与常规档不同形）；
//    * 「回到最新」入口的形态（上翻回看时不能没有入口）；
//    * 尾部跟随（流式输出时条目数不变、正文在长，也算尾部在动）。
//
//  断言的边界：`opacity(0)` 不参与命中测试这件事只能在视图里用 `.allowsHitTesting`
//  约束（`ChatApprovalBar.approveButton` / `InlineApprovalButtons`），SwiftUI 的命中
//  测试不适合放进单测，因此这里不假装覆盖它。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("审批主按钮形态")
struct ApprovalPrimaryActionTests {
    @Test("常规档：Allow + 突出样式")
    func routineStaysProminent() {
        let action = ApprovalPrimaryAction(isCritical: false)
        #expect(action == .routine)
        #expect(action.isProminent)
    }

    @Test("危险档：换成 Run anyway + 描边，不再抢主按钮位")
    func criticalDoesNotLookRoutine() {
        let action = ApprovalPrimaryAction(isCritical: true)
        #expect(action == .runAnyway)
        #expect(!action.isProminent)
    }

    @Test("两档不是同一个形态（危险命令必须有区别可辨）")
    func criticalDiffersFromRoutine() {
        let routine = ApprovalPrimaryAction(isCritical: false)
        let critical = ApprovalPrimaryAction(isCritical: true)

        #expect(routine != critical)
        #expect(routine.isProminent != critical.isProminent)
    }
}

@Suite("回到最新入口")
struct LatestJumpIndicatorTests {
    @Test("停在底部时不给入口")
    func hiddenWhileFollowing() {
        #expect(
            LatestJumpIndicator.resolve(isAutoscrollPaused: false, newMessageCount: 0) == .hidden)
        #expect(
            LatestJumpIndicator.resolve(isAutoscrollPaused: false, newMessageCount: 5) == .hidden)
    }

    @Test("上翻且没有新消息：只剩箭头——入口不能因为「没有新消息」而消失")
    func chevronOnlyWhenPausedWithoutNewMessages() {
        #expect(
            LatestJumpIndicator.resolve(isAutoscrollPaused: true, newMessageCount: 0)
                == .chevronOnly)
    }

    @Test("上翻且来了新消息：箭头 + 条数")
    func countWhenPausedWithNewMessages() {
        #expect(
            LatestJumpIndicator.resolve(isAutoscrollPaused: true, newMessageCount: 3) == .count(3))
    }
}

@Suite("审批输入块高度")
struct ApprovalDetailLayoutTests {
    @Test("一行短路径就是一行高，不会撑出一片空白")
    func shortInputIsOneLine() {
        #expect(
            ApprovalDetailLayout.height(for: "/tmp/a.swift") == ApprovalDetailLayout.lineHeight)
    }

    @Test("多行命令按行数增长（未到上限前不跳档）")
    func multilineGrowsByLineHeight() {
        #expect(
            ApprovalDetailLayout.height(for: "a\nb\nc") == ApprovalDetailLayout.lineHeight * 3)
    }

    @Test("超长输入封顶在工具输出同一档上限")
    func longInputIsCapped() {
        let long = Array(repeating: "make gate", count: 200).joined(separator: "\n")

        #expect(ApprovalDetailLayout.height(for: long) == ToolOutputWindow.expandedMaxHeight)
    }
}

@Suite("对话滚动跟随")
struct MessageAutoscrollTests {
    @Test("来了新条目：跟到底部")
    func followsOnNewItem() {
        #expect(
            MessageAutoscroll.shouldFollow(
                isAutoscrollPaused: false, countChanged: true, lastItemContentChanged: false))
    }

    @Test("流式输出（只有末条正文在长）：也要跟到底部")
    func followsStreamingTail() {
        #expect(
            MessageAutoscroll.shouldFollow(
                isAutoscrollPaused: false, countChanged: false, lastItemContentChanged: true))
    }

    @Test("什么都没变：不打扰视口")
    func staysWhenNothingMoved() {
        #expect(
            !MessageAutoscroll.shouldFollow(
                isAutoscrollPaused: false, countChanged: false, lastItemContentChanged: false))
    }

    @Test("上翻回看期间一律不跟（两种触发都不算）")
    func neverFollowsWhilePaused() {
        #expect(
            !MessageAutoscroll.shouldFollow(
                isAutoscrollPaused: true, countChanged: true, lastItemContentChanged: true))
    }
}