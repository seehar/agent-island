//
//  SessionLiveness.swift
//  AgentIsland
//
//  「处理中」相位的心跳判据：实时集成的 Stop 收不到时，相位会永远停在处理中。
//

import Foundation

/// 「处理中」相位的降级判据（纯函数，可单测）。
///
/// 相位离开 `.processing` 的唯一出口是事件（`Stop`，或下一轮的 `PreToolUse` / `SessionStart`）。
/// 可现实中 Stop 会丢：CLI 被杀、omp 把会话 `dispose` 掉、扩展在某条路径上没发——那时
/// 只要进程还活着、`kill(pid, 0)` 还能成功，这条会话就**永远**算「处理中」：
/// 关闭态徽标的分子虚高、列表里一条早就答完的会话一直转着「处理中…」。
///
/// 实测（2026-10-22）：18 条会话里 6 条的最后一轮 2~4 小时前就答完了（行里显示的就是
/// 最终答复），徽标仍报 12 个活跃，而真正在写记录的只有 3 条。
///
/// 所以补一条时间兜底：**没有任何心跳**（既没有事件、记录文件也没长）且**没有在跑的
/// 工具**时，把相位降回空闲。窗口取 20 分钟是为了容下「一口气生成二十分钟、中间不落盘」
/// 这种极端情况；真实的长工具调用由 `PreToolUse` + `ToolTracker.inProgress` 兜着，
/// 不会被误降（工具没回结果时 `inProgress` 非空）。
///
/// 降级目标是 `.idle` 而不是 `.waitingForInput`：后者语义是「这一轮答完了」，会触发
/// 完成提示音与弹跳（`NotchView.handleProcessingChange`）。心跳兜底并不能断言是正常收尾
/// （也可能进程被杀了半路），凭空响一声是更糟的谎。
nonisolated enum SessionLiveness {
    /// 「处理中」的心跳窗口（秒）：超过它没有任何心跳，就不再认为这条会话在跑。
    static let processingHeartbeatTimeout: TimeInterval = 20 * 60

    /// 该不该把 `.processing` 降回 `.idle`。
    ///
    /// `SessionState` 版本：从会话本身取相位、最后活动时间与「还有没有在跑的工具」。
    /// 生产里只走这一个入口，用例也据此覆盖「工具表非空 ⇒ 不降级」这条接线。
    static func shouldDemoteProcessing(
        session: SessionState,
        transcriptModifiedAt: Date?,
        now: Date
    ) -> Bool {
        shouldDemoteProcessing(
            phase: session.phase,
            lastActivity: session.lastActivity,
            transcriptModifiedAt: transcriptModifiedAt,
            hasRunningTool: !session.toolTracker.inProgress.isEmpty,
            now: now)
    }

    /// 判据本体（纯参数版）。
    ///
    /// - Parameters:
    ///   - phase: 当前相位（只有 `.processing` 才降）。
    ///   - lastActivity: 最后一条事件的时间。
    ///   - transcriptModifiedAt: 记录文件的 mtime（没有记录文件时为 nil）。
    ///   - hasRunningTool: 是否还有在跑的工具（`ToolTracker.inProgress` 非空）。
    ///   - now: 当前时间。
    static func shouldDemoteProcessing(
        phase: SessionPhase,
        lastActivity: Date,
        transcriptModifiedAt: Date?,
        hasRunningTool: Bool,
        now: Date
    ) -> Bool {
        guard phase == .processing else { return false }
        // 工具还没回结果：会话确实在跑（工具可能很久没有输出）。
        guard !hasRunningTool else { return false }
        // 心跳取两者较晚的那个：有记录文件的 Agent 以文件 mtime 为准，文件比事件更能
        // 证明「它还在写」；没有记录文件（结构化存储）时只剩事件时间。
        let heartbeat = max(lastActivity, transcriptModifiedAt ?? .distantPast)
        return now.timeIntervalSince(heartbeat) >= processingHeartbeatTimeout
    }
}
