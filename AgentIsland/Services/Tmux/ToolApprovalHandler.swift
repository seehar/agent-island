//
//  ToolApprovalHandler.swift
//  AgentIsland
//
//  Sends keystrokes into a session's tmux pane (messaging and interrupt)
//

import Foundation
import os.log

/// Sends keystrokes into a session's tmux pane.
///
/// 审批**不走这里**：允许/拒绝是应用的 socket 回写（`HookSocketServer.respondToPermission`），
/// 因此对非 tmux 的用户同样有效。这个 actor 只剩「用户主动往会话里打字」这一条路径：
/// 发一条消息、以及中断正在跑的回合（Ctrl-C）。
actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    /// Logger for tool approval (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Approval")

    private init() {}

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: message, pressEnter: true)
    }

    /// 中断该会话正在跑的这一回合：往 pane 里发一个 Ctrl-C。
    ///
    /// 用键名（`C-c`）而不是字节，见 `sendKeys` 的 `literal` 参数；不发 Enter。
    func sendInterrupt(to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "C-c", pressEnter: false, literal: false)
    }

    // MARK: - Private Methods

    /// - Parameters:
    ///   - literal: `-l` 让文本按字面发送（消息内容必须如此，否则 `C-c` 这类键名会被当文本）。
    ///     中断走 `false`，tmux 才会把 `C-c` 解释成控制键。
    private func sendKeys(
        to target: TmuxTarget, keys: String, pressEnter: Bool, literal: Bool = true
    ) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // tmux send-keys needs literal text and Enter as separate arguments
        // Use -l flag to send keys literally (prevents interpreting special chars)
        let targetStr = target.targetString
        var textArgs = ["send-keys", "-t", targetStr]
        if literal {
            textArgs.append("-l")
        }
        textArgs.append(keys)

        do {
            Self.logger.debug("Sending keys to \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            // Send Enter as a separate command if needed
            if pressEnter {
                Self.logger.debug("Sending Enter key")
                let enterArgs = ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
