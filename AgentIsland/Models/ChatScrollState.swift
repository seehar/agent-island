//
//  ChatScrollState.swift
//  AgentIsland
//
//  聊天页的「跟随到底」状态机：用户上翻回看时暂停自动滚动，期间攒下的新消息条数是
//  「回到最新」入口上的数字。
//
//  抽成纯值的原因：这三条判据都在真实使用里被踩过——流式输出时条目数不变、只有末条正文
//  在长（那也算「尾部在动」）；暂停期间的计数只在条数真的增长时才加；回到最新要同时清空
//  计数并重置基线。它们与视图无关，放这里可以直接单测。
//

import Foundation

/// 聊天页的滚动状态（`@State` 持有，视图只读它的两个派生值）。
nonisolated struct ChatScrollState: Equatable {
    /// 用户上翻回看中：不再自动跟随到底。
    private(set) var isPaused = false
    /// 暂停期间攒下的新消息条数（「回到最新」入口上的数字）。
    private(set) var newMessageCount = 0
    /// 上一次记下的历史条数：暂停期间用它算「新增了几条」。
    private var previousCount = 0

    /// 用户上翻：从此刻开始不跟随，计数基线取当前条数。
    mutating func pause(atCount count: Int) {
        isPaused = true
        previousCount = count
    }

    /// 回到最新：恢复跟随并清空计数。
    mutating func resume(atCount count: Int) {
        isPaused = false
        newMessageCount = 0
        previousCount = count
    }

    /// 历史更新后调用。返回**这次要不要滚到底**；暂停期间顺手把新增条数攒进计数。
    ///
    /// - 暂停期间只在条数增长时累加（内容变化不算「新消息」，用户回看时不该看到数字乱跳）。
    /// - 「尾部在动」包括两种情况：条目数变了，或条目数不变而末条正文变长（流式输出）。
    mutating func noteHistoryChanged(
        from old: [ChatHistoryItem], to new: [ChatHistoryItem]
    ) -> Bool {
        if isPaused && new.count > previousCount {
            newMessageCount += new.count - previousCount
            previousCount = new.count
        }

        let countChanged = new.count != old.count
        let lastItemContentChanged = new.last?.id == old.last?.id && new.last != old.last
        return MessageAutoscroll.shouldFollow(
            isAutoscrollPaused: isPaused,
            countChanged: countChanged,
            lastItemContentChanged: lastItemContentChanged)
    }
}
