//
//  ApprovalAskView.swift
//  AgentIsland
//
//  待批卡片的「交互式提问」形态：`ask` 工具不是批准/拒绝，而是要在刘海上选答案。
//  这里渲染问题、选项与自由文本输入，并把「提交 / 跳过」折成回传决定。
//
//  尺寸受限于刘海面板的对话区（面板高度固定），所以整体是一张紧凑卡：标题行 +
//  可滚动的提问区（有高度上限）+ 底部按钮，字号、间距与底色沿用对话区既有取值，
//  不引入新的视觉规格。
//
//  选择状态是独立的纯值类型（`AskSelection`），视图只负责渲染与转发：这样
//  「选择 → 答案字典」那一段可以脱离 UI 独立验证（见 q2 探针）。
//

import SwiftUI

/// 作答过程中的选择状态：问题 id → 选中的选项 label，加上各题的自由文本。
/// 纯值类型、无 SwiftUI 依赖，答案字典的构造规则都收敛在这里。
nonisolated struct AskSelection: Equatable, Sendable {
    /// 每个问题已选中的选项 label。
    private var picked: [String: Set<String>] = [:]
    /// 每个问题输入的自由文本原文。
    private var freeTexts: [String: String] = [:]

    /// 该选项在当前选择下是否已选中。
    func isPicked(_ label: String, in questionId: String) -> Bool {
        picked[questionId]?.contains(label) == true
    }

    /// 切换一个选项：多选叠加、单选替换；再点已选中项则取消——允许「这题先不答」。
    mutating func toggle(_ label: String, in question: AskQuestion) {
        var current = picked[question.id] ?? []
        if current.contains(label) {
            current.remove(label)
        } else if question.multiSelect {
            current.insert(label)
        } else {
            current = [label]
        }
        picked[question.id] = current
    }

    /// 记录某题的自由文本原文。
    mutating func setFreeText(_ text: String, for questionId: String) {
        freeTexts[questionId] = text
    }

    /// 某题的自由文本（未输入过为空串）。
    func freeText(for questionId: String) -> String {
        freeTexts[questionId] ?? ""
    }

    /// 按「问题声明顺序 + 选项声明顺序」收集答案；自由文本排在选项之后。
    /// 一题都没答的问题**不进字典**——集成侧对「键缺失」与「空数组」的处理不同，
    /// 只发真的选到了答案的问题。
    func answers(for questions: [AskQuestion]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for question in questions {
            let selected = picked[question.id] ?? []
            var values = question.options.map(\.label).filter { selected.contains($0) }
            let text = freeText(for: question.id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if question.freeText && !text.isEmpty {
                values.append(text)
            }
            if !values.isEmpty {
                result[question.id] = values
            }
        }
        return result
    }
}

/// 交互式提问的作答卡：读 `AskPayload`、写「问题 id → 选中项」。
struct ApprovalAskView: View {
    /// 集成侧给出的问题集。
    let ask: AskPayload
    /// 用户提交：问题 id → 选中的 label（自由文本为输入原文）。
    let onSubmit: ([String: [String]]) -> Void
    /// 用户放弃作答（上层把它折成 deny 回传）。
    let onSkip: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    /// 选择状态（纯值类型，答案字典由它构造）。
    @State private var selection = AskSelection()

    /// 提问区的高度上限：面板高度固定，问题多时在区内滚动，不吃掉消息列表。
    private let scrollMaxHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(ask.questions.enumerated()), id: \.element.id) { index, question in
                        questionBlock(question, index: index)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: scrollMaxHeight)
            .scrollBounceBehavior(.basedOnSize)

            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - 标题行

    /// 顶部一行：工具名（等宽 amber）+ 问题数。与 ChatApprovalBar 的标题行同规格。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble")
                .appFont(11, weight: .medium)
            Text(l10n.t("Question"))
                .appFont(12, weight: .medium, design: .monospaced)

            if ask.questions.count > 1 {
                Text(l10n.t("%lld questions", ask.questions.count))
                    .appFont(11)
                    .foregroundColor(AppPalette.tertiaryText)
            }

            Spacer(minLength: 0)
        }
        .foregroundColor(TerminalColors.amber)
    }

    // MARK: - 问题与选项

    /// 单个问题：短标题（多问题时带序号）+ 正文 + 选项行 +（可选）自由文本。
    @ViewBuilder
    private func questionBlock(_ question: AskQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let headerText = question.header, !headerText.isEmpty {
                HStack(spacing: 4) {
                    if ask.questions.count > 1 {
                        Text("\(index + 1)")
                            .appFont(10, weight: .semibold, design: .monospaced)
                            .foregroundColor(AppPalette.subtleText)
                    }
                    Text(headerText)
                        .appFont(11, weight: .medium)
                        .foregroundColor(AppPalette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Text(question.question)
                .appFont(12, weight: .medium)
                .foregroundColor(AppPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if question.multiSelect && question.options.count > 1 {
                Text(l10n.t("Select one or more"))
                    .appFont(10)
                    .foregroundColor(AppPalette.subtleText)
            }

            ForEach(question.options, id: \.label) { option in
                optionRow(option, question: question)
            }

            if question.freeText {
                freeTextField(question)
            }
        }
    }

    /// 选项行：整行可点，左侧是选中指示（单选圆点 / 多选勾选框），
    /// label 为主、description 为副。
    private func optionRow(_ option: AskOption, question: AskQuestion) -> some View {
        let isSelected = selection.isPicked(option.label, in: question.id)

        return Button {
            selection.toggle(option.label, in: question)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selectionSymbol(isSelected: isSelected, multi: question.multiSelect))
                    .appFont(11, weight: .medium)
                    .foregroundColor(isSelected ? AppPalette.accent : AppPalette.subtleText)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .appFont(12)
                        .foregroundColor(AppPalette.primaryText)
                        .multilineTextAlignment(.leading)

                    if let detail = option.description, !detail.isEmpty {
                        Text(detail)
                            .appFont(10)
                            .foregroundColor(AppPalette.tertiaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.control)
                    .fill(isSelected ? AppPalette.rowHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 选中指示符号：单选用圆点、多选用方框，位置与尺寸固定，勾选时不位移。
    private func selectionSymbol(isSelected: Bool, multi: Bool) -> String {
        if multi {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    /// 自由文本输入：`free_text` 为真时提供，回车即提交。
    private func freeTextField(_ question: AskQuestion) -> some View {
        TextField(l10n.t("Type your answer"), text: freeTextBinding(for: question.id))
            .textFieldStyle(.plain)
            .appFont(12)
            .foregroundColor(AppPalette.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.control)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.control)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .onSubmit { submit() }
    }

    private func freeTextBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { selection.freeText(for: questionId) },
            set: { selection.setFreeText($0, for: questionId) }
        )
    }

    // MARK: - 底部动作

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button {
                onSkip()
            } label: {
                Text(l10n.t("Skip"))
                    .appFont(13, weight: .medium)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                submit()
            } label: {
                Text(l10n.t("Submit"))
                    .appFont(13, weight: .medium)
                    .foregroundColor(canSubmit ? .black : .white.opacity(0.4))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(canSubmit ? 0.95 : 0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    // MARK: - 作答

    /// 当前可提交的答案（空字典 = 一题都没答）。
    private var collectedAnswers: [String: [String]] {
        selection.answers(for: ask.questions)
    }

    /// 有任意一题作答才允许提交；否则只剩「跳过」这一条路。
    private var canSubmit: Bool { !collectedAnswers.isEmpty }

    private func submit() {
        let answers = collectedAnswers
        guard !answers.isEmpty else { return }
        onSubmit(answers)
    }
}
