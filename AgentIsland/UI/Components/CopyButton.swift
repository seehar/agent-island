//
//  CopyButton.swift
//  AgentIsland
//
//  行内复制按钮：把一段文本写进系统剪贴板，点击后原位短暂显示「已复制」。
//
//  只用在对话面里「用户要拿走」的块上（Markdown 代码块、工具输出、读到的文件
//  内容），所以做成 10pt 级的图标 + 固定占位框：对话面板只有 480pt 宽，行高与
//  相邻元素的水平位置都不能因为这一枚按钮发生变化。
//

import AppKit
import SwiftUI

// MARK: - 复制动作

/// 复制动作本身。
///
/// 与视图分开：写剪贴板只有这一处实现，视图只管反馈动画，不会随视图重建多出
/// 第二份「怎么写剪贴板」的逻辑。
nonisolated enum CopyAction {
    /// 把 `text` 写进系统剪贴板。
    ///
    /// `clearContents` 不能省：不清空时剪贴板里会残留上一份内容的其它类型，
    /// 目标应用可能读到旧数据。
    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - 复制按钮

/// 行内复制按钮。`text` 必须是**未截断的原文**——界面上折叠后只显示前若干行，
/// 复制要拿走的却是整份内容，因此调用点传的始终是完整文本。
struct CopyButton: View {
    let text: String

    @ObservedObject private var l10n = LocalizationManager.shared

    /// 复制成功后的短暂反馈（图标换成对勾 + 「已复制」）。
    @State private var didCopy = false
    /// 反馈的复位任务。连点时先取消上一枚，免得旧计时把新的反馈提前清掉。
    @State private var resetTask: Task<Void, Never>?

    /// 内容面字号比例：占位框跟着一起缩放，否则用户把字号调大后「已复制」会被裁掉。
    @Environment(\.appTextScale) private var textScale

    /// 反馈停留时长。
    private static let feedbackDuration: Duration = .milliseconds(1400)
    /// 基准占位框：装得下「已复制」三个字，也不再随反馈态变宽变高。窄面板里
    /// 位置跳动比多占十几个点更刺眼，所以宁可留一点空白。
    private static let baseSlotWidth: CGFloat = 62
    private static let baseSlotHeight: CGFloat = 14

    private var slotWidth: CGFloat { Self.baseSlotWidth * textScale }
    private var slotHeight: CGFloat { Self.baseSlotHeight * textScale }

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 3) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .appFont(10, weight: .medium)

                if didCopy {
                    Text(l10n.t("Copied"))
                        .appFont(10)
                        .lineLimit(1)
                }
            }
            // 右对齐：文案变长时向左生长，图标始终停在同一个位置。
            .frame(width: slotWidth, height: slotHeight, alignment: .trailing)
            .foregroundColor(didCopy ? AppPalette.success : AppPalette.tertiaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .help(l10n.t("Copy"))
        .accessibilityLabel(Text(l10n.t("Copy")))
        .onDisappear { resetTask?.cancel() }
    }

    /// 写剪贴板并触发反馈。
    private func copy() {
        CopyAction.write(text)

        didCopy = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}