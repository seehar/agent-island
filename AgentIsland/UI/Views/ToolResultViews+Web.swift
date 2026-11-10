//
//  ToolResultViews+Web.swift
//  AgentIsland
//
//  WebFetch / WebSearch / AskUserQuestion / MCP 结果视图。
//

import SwiftUI

// MARK: - WebFetch Result View

struct WebFetchResultContent: View {
    let result: WebFetchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // URL and status
            HStack(spacing: 6) {
                Text("\(result.code)")
                    .appFont(10, weight: .medium, design: .monospaced)
                    .foregroundColor(result.code < 400 ? AppPalette.success : AppPalette.danger)

                Text(truncateUrl(result.url))
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(1)
            }

            // Result summary
            if !result.result.isEmpty {
                Text(result.result.prefix(300) + (result.result.count > 300 ? "..." : ""))
                    .appFont(11)
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(8)
            }
        }
    }

    private func truncateUrl(_ url: String) -> String {
        if url.count > 50 {
            return String(url.prefix(47)) + "..."
        }
        return url
    }
}

// MARK: - WebSearch Result View

struct WebSearchResultContent: View {
    let result: WebSearchResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.results.isEmpty {
                Text(l10n.t("No results found"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
            } else {
                ForEach(Array(result.results.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .appFont(11, weight: .medium)
                            .foregroundColor(.blue.opacity(0.8))
                            .lineLimit(1)

                        if !item.snippet.isEmpty {
                            Text(item.snippet)
                                .appFont(10)
                                .foregroundColor(AppPalette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }

                if result.results.count > 5 {
                    Text(l10n.t("... and %lld more results", result.results.count - 5))
                        .appFont(10)
                        .foregroundColor(AppPalette.subtleText)
                }
            }
        }
    }
}

// MARK: - AskUserQuestion Result View

struct AskUserQuestionResultContent: View {
    let result: AskUserQuestionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    // Question
                    Text(question.question)
                        .appFont(11)
                        .foregroundColor(AppPalette.secondaryText)

                    // Answer
                    if let answer = result.answers["\(index)"] {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .appFont(9)
                            Text(answer)
                                .appFont(11, weight: .medium)
                        }
                        .foregroundColor(AppPalette.success)
                    }
                }
            }
        }
    }
}

// MARK: - MCP Result View

struct MCPResultContent: View {
    let result: MCPResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Server and tool info (formatted as Title Case)
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece")
                    .appFont(10)
                Text(
                    "\(MCPToolFormatter.toTitleCase(result.serverName)) - \(MCPToolFormatter.toTitleCase(result.toolName))"
                )
                .appFont(10, design: .monospaced)
            }
            .foregroundColor(.purple.opacity(0.7))

            // Raw result (formatted as key-value pairs)
            ForEach(Array(result.rawResult.prefix(5)), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.tertiaryText)
                    Text("\(String(describing: value).prefix(100))")
                        .appFont(10, design: .monospaced)
                        .foregroundColor(AppPalette.secondaryText)
                        .lineLimit(2)
                }
            }
        }
    }
}
