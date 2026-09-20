//
//  ClaudeSessionMonitor.swift
//  AgentIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Start periodic status rechecking
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }

        // 扫描各 Agent 的记录目录，补上应用启动前就在跑的会话
        AgentSessionDiscovery.shared.start()

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    let key = event.sessionKey
                    let transcriptPath = event.sessionFile
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            key: key,
                            cwd: event.cwd,
                            transcriptPath: transcriptPath
                        )
                    }
                }

                if event.status == "ended" {
                    let key = event.sessionKey
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(key: key)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(key: event.sessionKey)
                }

                // 工具结束即撤卡：成功走 `PostToolUse`，被拒绝 / 中止走
                // `PostToolUseFailure`（`ask` 放弃作答是原生取消语义，扩展侧只报后者，
                // 并带上同一个 `tool_use_id`）。两种终态都按 tool_use_id 收敛——只认
                // 成功那条会让失败分支的 pending 一直挂到 TTL 到期。Claude 本来也会发
                // `PostToolUseFailure`，因此这里的既有语义不变。
                if (event.event == "PostToolUse" || event.event == "PostToolUseFailure"),
                    let toolUseId = event.toolUseId
                {
                    HookSocketServer.shared.cancelPendingPermission(
                        key: event.sessionKey, toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { key, toolUseId in
                // 失败回调按待批条目自带的会话键归属，不再假设是 Claude
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(key: key, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        AgentSessionDiscovery.shared.stop()
        HookSocketServer.shared.stop()
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(key: SessionKey) {
        Task {
            guard let session = await SessionStore.shared.session(for: key),
                  let permission = session.activePermission else {
                return
            }

            // 只有能回传决定的 Agent 才需要应答 hook
            if key.agent.approval.canDecideRemotely {
                HookSocketServer.shared.respondToPermission(
                    key: key,
                    toolUseId: permission.toolUseId,
                    decision: "allow"
                )
            }

            await SessionStore.shared.process(
                .permissionApproved(key: key, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(key: SessionKey, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: key),
                  let permission = session.activePermission else {
                return
            }

            if key.agent.approval.canDecideRemotely {
                HookSocketServer.shared.respondToPermission(
                    key: key,
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )
            }

            await SessionStore.shared.process(
                .permissionDenied(key: key, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// 待批卡片的展示档位（危险命令 / 闸门降级 / 让位）；没有待批时返回 nil。
    func approvalDisplay(for key: SessionKey) -> PendingApprovalDisplay? {
        HookSocketServer.shared.pendingApprovalDisplay(key: key)
    }

    /// 待批工具若是 `ask`（交互式提问），返回它的问题集；其余情况返回 nil。
    /// 与 `approvalDisplay` 同形：视图在「每次会话发布都重查」的既有路径里取用，
    /// 不另开轮询。
    func pendingAsk(for key: SessionKey) -> AskPayload? {
        HookSocketServer.shared.pendingAsk(key: key)
    }

    /// 在刘海上作答：把「问题 id → 选中的 label（自由文本为输入原文）」回传给该
    /// Agent。没有作答任何一题时按放弃处理（`AskAnswerBuilder` 折成 deny），与
    /// 既有的拒绝路径同一套语义。
    ///
    /// 无论写回 socket 是否成功都推进本地状态——与 `approvePermission` /
    /// `denyPermission` 一致：本地状态不能吊在「对端还活着」上，否则会话会一直
    /// 停在等待态。
    func answerPermission(key: SessionKey, answers: [String: [String]]) {
        Task {
            guard let session = await SessionStore.shared.session(for: key),
                  let permission = session.activePermission else {
                return
            }

            let response = AskAnswerBuilder.response(answers: answers)

            if key.agent.approval.canDecideRemotely {
                HookSocketServer.shared.respondToPermission(
                    key: key,
                    toolUseId: permission.toolUseId,
                    decision: response.decision,
                    answers: response.answers,
                    reason: response.reason
                )
            }

            if response.decision == AskAnswerBuilder.decisionAnswer {
                await SessionStore.shared.process(
                    .permissionApproved(key: key, toolUseId: permission.toolUseId)
                )
            } else {
                await SessionStore.shared.process(
                    .permissionDenied(key: key, toolUseId: permission.toolUseId, reason: nil)
                )
            }
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(key: SessionKey) {
        Task {
            await SessionStore.shared.process(.sessionEnded(key: key))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(key: SessionKey, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(key: key, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(key: SessionKey) {
        Task {
            await SessionStore.shared.process(.interruptDetected(key: key))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(key: key)
        }
    }
}
