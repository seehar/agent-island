//
//  ToolResultViews+Diff.swift
//  AgentIsland
//
//  差异（diff）渲染：DiffView / DiffLineView / SimpleDiffView。
//

import SwiftUI

struct DiffView: View {
    let patches: [PatchHunk]
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(patches.prefix(3).enumerated()), id: \.offset) { _, patch in
                VStack(alignment: .leading, spacing: 1) {
                    // Hunk header
                    Text(
                        "@@ -\(patch.oldStart),\(patch.oldLines) +\(patch.newStart),\(patch.newLines) @@"
                    )
                    .appFont(10, design: .monospaced)
                    .foregroundColor(.cyan.opacity(0.7))

                    // Lines
                    ForEach(Array(patch.lines.prefix(10).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }

                    if patch.lines.count > 10 {
                        Text(l10n.t("... (%lld more lines)", patch.lines.count - 10))
                            .appFont(10, design: .monospaced)
                            .foregroundColor(AppPalette.subtleText)
                    }
                }
            }

            if patches.count > 3 {
                Text(l10n.t("... and %lld more hunks", patches.count - 3))
                    .appFont(10)
                    .foregroundColor(AppPalette.subtleText)
            }
        }
    }
}

struct DiffLineView: View {
    let line: String

    private var lineType: DiffLineType {
        if line.hasPrefix("+") {
            return .added
        } else if line.hasPrefix("-") {
            return .removed
        }
        return .context
    }

    var body: some View {
        Text(line)
            .appFont(11, design: .monospaced)
            .foregroundColor(lineType.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(lineType.backgroundColor)
    }
}

private enum DiffLineType {
    case added
    case removed
    case context

    var textColor: Color {
        switch self {
        case .added: return AppPalette.success
        case .removed: return AppPalette.danger
        case .context: return AppPalette.secondaryText
        }
    }

    var backgroundColor: Color {
        switch self {
        case .added: return AppPalette.success.opacity(0.15)
        case .removed: return AppPalette.danger.opacity(0.15)
        case .context: return .clear
        }
    }
}

struct SimpleDiffView: View {
    let oldString: String
    let newString: String
    var filename: String? = nil

    /// Compute diff using LCS algorithm
    private var diffLines: [DiffLine] {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")

        // Compute LCS to find matching lines
        let lcs = computeLCS(oldLines, newLines)

        var result: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            // Limit output
            if result.count >= 12 { break }

            let lcsLine = lcsIdx < lcs.count ? lcs[lcsIdx] : nil

            if oldIdx < oldLines.count && (lcsLine == nil || oldLines[oldIdx] != lcsLine) {
                // Line in old but not in LCS - removed
                result.append(
                    DiffLine(text: oldLines[oldIdx], type: .removed, lineNumber: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < newLines.count && (lcsLine == nil || newLines[newIdx] != lcsLine) {
                // Line in new but not in LCS - added
                result.append(
                    DiffLine(text: newLines[newIdx], type: .added, lineNumber: newIdx + 1))
                newIdx += 1
            } else {
                // Matching line in LCS - skip (context)
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            }
        }

        return result
    }

    /// Compute Longest Common Subsequence of two string arrays
    private func computeLCS(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count

        // DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var lcs: [String] = []
        var i = m
        var j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs.reversed()
    }

    private var hasMoreChanges: Bool {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")
        let lcs = computeLCS(oldLines, newLines)
        let totalChanges = (oldLines.count - lcs.count) + (newLines.count - lcs.count)
        return totalChanges > 12
    }

    /// Whether there are lines before the first diff line
    private var hasLinesBefore: Bool {
        guard let firstLine = diffLines.first else { return false }
        return firstLine.lineNumber > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            if let name = filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .appFont(10)
                        .foregroundColor(AppPalette.tertiaryText)
                    Text(name)
                        .appFont(11, weight: .medium, design: .monospaced)
                        .foregroundColor(AppPalette.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppPalette.cardFill)
                .clipShape(
                    RoundedCorner(
                        radius: AppRadius.control,
                        corners: [.topLeft, .topRight] as RoundedCorner.RectCorner))
            }

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(AppPalette.cardFill)
                    .clipShape(
                        RoundedCorner(
                            radius: AppRadius.control,
                            corners: filename == nil
                                ? [.topLeft, .topRight] as RoundedCorner.RectCorner
                                : [] as RoundedCorner.RectCorner))
            }

            // Diff lines
            ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                let isFirst = index == 0 && filename == nil && !hasLinesBefore
                let isLast = index == diffLines.count - 1 && !hasMoreChanges
                DiffLineView(
                    line: line.text,
                    type: line.type,
                    lineNumber: line.lineNumber,
                    isFirst: isFirst,
                    isLast: isLast
                )
            }

            // Bottom overflow indicator
            if hasMoreChanges {
                Text("...")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(AppPalette.cardFill)
                    .clipShape(
                        RoundedCorner(
                            radius: AppRadius.control,
                            corners: [.bottomLeft, .bottomRight] as RoundedCorner.RectCorner))
            }
        }
    }

    private struct DiffLine {
        let text: String
        let type: DiffLineType
        let lineNumber: Int
    }

    private struct DiffLineView: View {
        let line: String
        let type: DiffLineType
        let lineNumber: Int
        let isFirst: Bool
        let isLast: Bool

        private var corners: RoundedCorner.RectCorner {
            if isFirst && isLast {
                return .allCorners
            } else if isFirst {
                return [.topLeft, .topRight]
            } else if isLast {
                return [.bottomLeft, .bottomRight]
            }
            return []
        }

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .appFont(10, design: .monospaced)
                    .foregroundColor(type.textColor.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 4)

                // +/- indicator
                Text(type == .added ? "+" : "-")
                    .appFont(11, weight: .medium, design: .monospaced)
                    .foregroundColor(type.textColor)
                    .frame(width: 14)

                // Line content
                Text(line.isEmpty ? " " : line)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(type.textColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(type.backgroundColor)
            .clipShape(RoundedCorner(radius: AppRadius.control, corners: corners))
        }
    }
}
