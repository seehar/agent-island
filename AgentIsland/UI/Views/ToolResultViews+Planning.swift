//
//  ToolResultViews+Planning.swift
//  AgentIsland
//
//  TodoWrite / Task / ExitPlanMode 结果视图（计划与任务类工具）。
//

import SwiftUI

// MARK: - TodoWrite Result View

struct TodoWriteResultContent: View {
    let result: TodoWriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(result.newTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    // Status icon
                    Image(systemName: todoIcon(for: todo.status))
                        .appFont(10)
                        .foregroundColor(todoColor(for: todo.status))
                        .frame(width: 12)

                    Text(todo.content)
                        .appFont(11)
                        .foregroundColor(
                            todo.status == "completed"
                                ? AppPalette.tertiaryText : AppPalette.primaryText
                        )
                        .strikethrough(todo.status == "completed")
                        .lineLimit(2)
                }
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": return AppPalette.success
        case "in_progress": return AppPalette.warning
        default: return AppPalette.tertiaryText
        }
    }
}

// MARK: - Task Result View

struct TaskResultContent: View {
    let result: TaskResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status and stats
            HStack(spacing: 8) {
                Text(result.status.capitalized)
                    .appFont(11, weight: .medium)
                    .foregroundColor(statusColor)

                if let duration = result.totalDurationMs {
                    Text("\(formatDuration(duration))")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.tertiaryText)
                }

                if let tools = result.totalToolUseCount {
                    Text(l10n.t("%lld tools", tools))
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.tertiaryText)
                }
            }

            // Content summary
            if !result.content.isEmpty {
                Text(result.content.prefix(200) + (result.content.count > 200 ? "..." : ""))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(5)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case "completed": return AppPalette.success
        case "in_progress": return AppPalette.warning
        case "failed", "error": return AppPalette.danger
        default: return AppPalette.secondaryText
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60000 {
            return l10n.t("%lldm %llds", ms / 60000, (ms % 60000) / 1000)
        } else if ms >= 1000 {
            return l10n.t("%llds", ms / 1000)
        }
        return l10n.t("%lldms", ms)
    }
}

// MARK: - ExitPlanMode Result View

struct ExitPlanModeResultContent: View {
    let result: ExitPlanModeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = result.filePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .appFont(10)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .appFont(11, design: .monospaced)
                }
                .foregroundColor(AppPalette.secondaryText)
            }

            if let plan = result.plan, !plan.isEmpty {
                Text(plan.prefix(200) + (plan.count > 200 ? "..." : ""))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(6)
            }
        }
    }
}
