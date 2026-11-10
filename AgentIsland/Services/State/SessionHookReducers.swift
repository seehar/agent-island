//
//  SessionHookReducers.swift
//  AgentIsland
//
//  hook 事件的「按事件族折算」：工具跟踪、子 Agent 跟踪、子 Agent 总线事件的落点。
//  这些逻辑原先散在 SessionStore 里（actor 因此长到 1500 行），但它们**不读也不写
//  actor 的任何状态**——输入只有事件与一份 `inout SessionState`。抽成纯函数后：
//  ① SessionStore 只剩「调度 + 状态字典 + 发布」；
//  ② 这些折算可以脱离 actor 单测（构造 SessionState 直接断言）；
//  ③ 事件族的边界在文件名上可见，不再靠 1500 行里的 `// MARK:` 定位。
//

import Foundation
import os.log

nonisolated enum SessionHookReducers {
    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Session")

    static func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // 子 Agent 内部的工具不建顶层占位卡：它们会挂在父 Task 卡片下面。
                // 只对真正上报子 Agent 内部调用的 Agent 生效：其余 Agent（omp/pi/
                // opencode）在 Task 运行期间报上来的工具属于根会话本体。
                let isSubagentTool =
                    session.agent.reportsSubagentInnerTools
                    && session.subagentState.hasActiveSubagent
                    && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    let input = event.flattenedToolInput

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(
                            ToolCallItem(
                                name: toolName,
                                input: input,
                                status: .running,
                                result: nil,
                                structuredResult: nil,
                                subagentTools: [],
                                subagentRuns: []
                            )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    logger.debug(
                        "Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)"
                    )
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // 工具结束：卡片状态从「待批 / 运行中」推进到成功（在终端里批准过的也走这里）。
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                        case .toolCall(var tool) = session.chatItems[i].type,
                        tool.status == .waitingForApproval || tool.status == .running
                    {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    static func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                logger.debug(
                    "Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)"
                )
            } else if let toolName = event.tool,
                let toolUseId = event.toolUseId,
                session.agent.reportsSubagentInnerTools,
                session.subagentState.hasActiveSubagent
            {
                // 子 Agent 的内部工具开跑：挂到父 Task 的列表上并同步进卡片，
                // 界面才能实时看到（而不是等父 Agent 整个跑完才出现）。
                let input = event.flattenedToolInput
                let subagentTool = SubagentToolCall(
                    id: toolUseId,
                    name: toolName,
                    input: input,
                    status: .running,
                    timestamp: Date()
                )
                session.subagentState.addSubagentTool(subagentTool)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "PostToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent 工具返回 = 子 Agent 已结束：停止跟踪，否则父回合后续的工具
                // 会继续挂到这个已经死掉的 Task 上。
                session.subagentState.stopTask(taskToolId: toolUseId)
                logger.debug(
                    "Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolUseId = event.toolUseId,
                session.agent.reportsSubagentInnerTools,
                session.subagentState.hasActiveSubagent
            {
                // 子 Agent 的内部工具完成：更新状态并同步进卡片。
                session.subagentState.updateSubagentToolStatus(toolId: toolUseId, status: .success)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "SubagentStop":
            // SubagentStop 表示子 Agent 结束：这里只需停止跟踪——子 Agent 的工具列表
            // 由记录文件在 `processFileUpdated` 里补齐。
            logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// 处理父会话 `task:subagent:*` 总线事件（omp / pi 的子 Agent）。
    ///
    /// 相位规则：有子 Agent 在跑就把会话提到 `processing`（子 Agent 期间没有任何
    /// 父会话事件的 headless 场景尤其需要）；子 Agent 全部结束时若相位还停在
    /// `processing`，补一次收尾——根会话自身的事件会立即纠正，不会长期偏离。
    static func processSubagentBusEvent(event: HookEvent, session: inout SessionState) {
        guard let subagentId = event.subagentId else { return }

        let reported = SubagentRunStatus(wire: event.subagentStatus)
        let existing = session.subagentState.subagents[subagentId]?.status
        // 上报值不认识时沿用已知状态；首次进度事件早于生命周期事件时按「已开跑」处理。
        let status: SubagentRunStatus = reported == .unknown ? (existing ?? .running) : reported
        let now = Date()

        session.subagentState.upsertSubagent(
            id: subagentId,
            agent: event.subagentAgent ?? subagentId,
            status: status,
            currentTool: event.subagentCurrentTool,
            task: event.subagentTask,
            sessionFile: event.subagentSessionFile,
            parentToolCallId: event.parentToolCallId,
            now: now
        )

        if session.subagentState.runningSubagentCount(at: now) > 0 {
            // 同上：待批在手时，子 Agent 的进度也不许把「等待审批」拉走。
            if session.phase.canTransition(to: .processing), !event.hasLivePending {
                session.phase = .processing
            }
        } else if session.phase == .processing, session.phase.canTransition(to: .waitingForInput) {
            session.phase = .waitingForInput
        }

        syncSubagentRunsToChatItems(session: &session)
        logger.debug(
            "Subagent \(subagentId, privacy: .public) -> \(String(describing: status), privacy: .public)"
        )
    }

    /// 把子 Agent 表写进对应的 task 卡，供界面渲染。
    ///
    /// 会话里没有任何子 Agent 时直接返回：此时卡片上的子 Agent 行来自记录解析
    /// （见 `populateSubagentRunsFromTaskResults`），不能被空状态擦掉。
    static func syncSubagentRunsToChatItems(session: inout SessionState) {
        guard !session.subagentState.subagents.isEmpty else { return }
        for index in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[index].type,
                ToolCallItem.isSubagentContainerName(tool.name)
            else { continue }
            let runs = session.subagentState.subagents(forTask: session.chatItems[index].id)
            guard runs != tool.subagentRuns else { continue }
            tool.subagentRuns = runs
            session.chatItems[index] = ChatHistoryItem(
                id: session.chatItems[index].id,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )
        }
    }

    /// 把子 Agent 当前的内部工具列表写进对应 Task 卡的 `subagentTools`，供界面实时渲染。
    static func syncSubagentToolsToChatItems(session: inout SessionState) {
        for (taskToolId, context) in session.subagentState.activeTasks {
            guard !context.subagentTools.isEmpty else { continue }
            for i in 0..<session.chatItems.count {
                if session.chatItems[i].id == taskToolId,
                    case .toolCall(var tool) = session.chatItems[i].type
                {
                    tool.subagentTools = context.subagentTools
                    session.chatItems[i] = ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                    break
                }
            }
        }
    }
}
