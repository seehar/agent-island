//
//  SessionPhaseHelpers.swift
//  AgentIsland
//
//  Helper functions for session phase display
//

import SwiftUI

struct SessionPhaseHelpers {
    private static let l10n = LocalizationManager.shared

    /// Get color for session phase
    static func phaseColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .processing:
            return TerminalColors.cyan
        case .compacting:
            return TerminalColors.magenta
        case .idle, .ended:
            return TerminalColors.dim
        }
    }

    /// 取得会话阶段对应的展示文案
    static func phaseDescription(for phase: SessionPhase) -> String {
        switch phase {
        case .waitingForApproval(let ctx):
            return l10n.t("Waiting for approval: %@", ctx.toolName)
        case .waitingForInput:
            return l10n.t("Ready for input")
        case .processing:
            return l10n.t("Processing...")
        case .compacting:
            return l10n.t("Compacting context...")
        case .idle:
            return l10n.t("Idle")
        case .ended:
            return l10n.t("Ended")
        }
    }

    /// 格式化“多久以前”的文案
    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return l10n.t("now") }
        if seconds < 60 { return l10n.t("%llds", seconds) }
        if seconds < 3600 { return l10n.t("%lldm", seconds / 60) }
        if seconds < 86400 { return l10n.t("%lldh", seconds / 3600) }
        return l10n.t("%lldd", seconds / 86400)
    }
}
