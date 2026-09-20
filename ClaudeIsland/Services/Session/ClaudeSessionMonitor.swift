//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
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
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                // 审批应答只来自 Claude Code 的 hook 通道
                let key = SessionKey(agent: .claudeCode, sessionId: sessionId)
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

            // 只有能回传决定的 Agent（Claude Code）才需要应答 hook
            if key.agent.supportsPermissionControl {
                HookSocketServer.shared.respondToPermission(
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

            if key.agent.supportsPermissionControl {
                HookSocketServer.shared.respondToPermission(
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
