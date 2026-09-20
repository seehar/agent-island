//
//  LanguagePickerRow.swift
//  ClaudeIsland
//
//  设置菜单中的语言选择行。语言名称始终以其自身语言书写，便于辨认；
//  “跟随系统”选项则使用 macOS 的语言偏好。
//

import SwiftUI

struct LanguagePickerRow: View {
    @ObservedObject private var selector = LanguageSelector.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    private var isExpanded: Bool { selector.isPickerExpanded }

    var body: some View {
        VStack(spacing: 0) {
            // 主行 —— 显示当前选择
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selector.isPickerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(l10n.t("Language"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(l10n.displayName(for: l10n.language))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // 展开后的语言列表
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(AppLanguage.allCases) { language in
                        LanguageOptionRow(
                            label: l10n.displayName(for: language),
                            isSelected: l10n.language == language
                        ) {
                            l10n.select(language)
                            collapseAfterDelay()
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    /// 选择后短暂延迟再收起，让用户看到选中态的变化。
    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                selector.isPickerExpanded = false
            }
        }
    }
}

// MARK: - 语言选项行

private struct LanguageOptionRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
