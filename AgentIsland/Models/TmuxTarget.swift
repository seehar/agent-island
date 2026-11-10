//
//  TmuxTarget.swift
//  AgentIsland
//
//  Data model for tmux session/window/pane targeting
//

import Foundation

/// Represents a tmux target (session:window.pane)
///
/// `nonisolated`：它跨 actor 传递（`TmuxTargetFinder` 是 actor、聊天页在主 actor），
/// 而工程默认隔离是 MainActor —— 不标的话 `Equatable` 的一致性也会跟着被主 actor 隔离，
/// 从非隔离上下文比较就是「main actor-isolated conformance ... cannot be used」。
nonisolated struct TmuxTarget: Equatable, Sendable {
    let session: String
    let window: String
    let pane: String

    nonisolated var targetString: String {
        "\(session):\(window).\(pane)"
    }

    nonisolated init(session: String, window: String, pane: String) {
        self.session = session
        self.window = window
        self.pane = pane
    }

    /// Parse from tmux target string format "session:window.pane"
    nonisolated init?(from targetString: String) {
        let sessionSplit = targetString.split(separator: ":", maxSplits: 1)
        guard sessionSplit.count == 2 else { return nil }

        let session = String(sessionSplit[0])
        let windowPane = String(sessionSplit[1])

        let paneSplit = windowPane.split(separator: ".", maxSplits: 1)
        guard paneSplit.count == 2 else { return nil }

        self.session = session
        self.window = String(paneSplit[0])
        self.pane = String(paneSplit[1])
    }
}
