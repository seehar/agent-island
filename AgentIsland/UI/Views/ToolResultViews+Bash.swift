//
//  ToolResultViews+Bash.swift
//  AgentIsland
//
//  Bash / BashOutput / KillShell / Grep / Glob 结果视图。
//

import SwiftUI

// MARK: - Bash Result View

struct BashResultContent: View {
    let result: BashResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background task indicator
            if let bgId = result.backgroundTaskId {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .appFont(10)
                    Text(l10n.t("Background task: %@", bgId))
                        .appFont(10, design: .monospaced)
                }
                .foregroundColor(.blue.opacity(0.7))
            }

            // Return code interpretation
            if let interpretation = result.returnCodeInterpretation {
                Text(interpretation)
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
            }

            // Stdout
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 15)
            }

            // Stderr (shown in red)
            if !result.stderr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("stderr:"))
                        .appFont(10, weight: .medium)
                        .foregroundColor(AppPalette.danger)
                    // 与 stdout 同一条路径：stderr 才是编译报错/栈这类真正要看全、要拷走的长文本
                    // （改动前这里硬封 10 行，且没有展开与复制入口）。
                    GenericTextContent(text: result.stderr, color: AppPalette.danger)
                }
            }

            // Empty state
            if !result.hasOutput && result.backgroundTaskId == nil
                && result.returnCodeInterpretation == nil
            {
                Text(l10n.t("(No content)"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
            }
        }
    }
}

// MARK: - Grep Result View

struct GrepResultContent: View {
    let result: GrepResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.mode {
            case .filesWithMatches:
                // Show file list
                if result.filenames.isEmpty {
                    Text(l10n.t("No matches found"))
                        .appFont(11, design: .monospaced)
                        .foregroundColor(AppPalette.subtleText)
                } else {
                    FileListView(files: result.filenames, limit: 10)
                }

            case .content:
                // Show matching content
                if let content = result.content, !content.isEmpty {
                    CodePreview(content: content, maxLines: 15)
                } else {
                    Text(l10n.t("No matches found"))
                        .appFont(11, design: .monospaced)
                        .foregroundColor(AppPalette.subtleText)
                }

            case .count:
                Text(l10n.t("%lld files with matches", result.numFiles))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)
            }
        }
    }
}

// MARK: - Glob Result View

struct GlobResultContent: View {
    let result: GlobResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.filenames.isEmpty {
                Text(l10n.t("No files found"))
                    .appFont(11, design: .monospaced)
                    .foregroundColor(AppPalette.subtleText)
            } else {
                FileListView(files: result.filenames, limit: 10)

                if result.truncated {
                    Text(l10n.t("... and more (truncated)"))
                        .appFont(10)
                        .foregroundColor(AppPalette.subtleText)
                }
            }
        }
    }
}

// MARK: - BashOutput Result View

struct BashOutputResultContent: View {
    let result: BashOutputResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack(spacing: 6) {
                Text(l10n.t("Status: %@", result.status))
                    .appFont(10, design: .monospaced)
                    .foregroundColor(AppPalette.secondaryText)

                if let exitCode = result.exitCode {
                    Text(l10n.t("Exit: %lld", exitCode))
                        .appFont(10, design: .monospaced)
                        .foregroundColor(exitCode == 0 ? AppPalette.success : AppPalette.danger)
                }
            }

            // Output
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 10)
            }

            if !result.stderr.isEmpty {
                GenericTextContent(text: result.stderr, color: AppPalette.danger)
            }
        }
    }
}

// MARK: - KillShell Result View

struct KillShellResultContent: View {
    let result: KillShellResult
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .appFont(11)
                .foregroundColor(AppPalette.danger)

            Text(
                result.message.isEmpty
                    ? l10n.t("Shell %@ terminated", result.shellId) : result.message
            )
            .appFont(11, design: .monospaced)
            .foregroundColor(AppPalette.secondaryText)
        }
    }
}
