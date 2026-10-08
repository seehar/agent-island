//
//  SettingsStepperRow.swift
//  AgentIsland
//
//  展开的选择器里的微调行：与选项行同一套几何，右侧是「− 数值 +」——数值本身是个
//  输入框，可以直接键入精确的磅值，键入与 ± 都**立刻**写回（边调边看）。
//  胶囊高度与宽度两个选择器共用它，差别只是标签、上下限与步长。
//

import SwiftUI

struct SettingsStepperRow: View {
    /// 行标签。
    let label: String
    /// 当前**生效**的数值（调用方已夹紧）。非编辑态显示它，失焦时文本框也归一成它。
    let value: CGFloat
    /// 微调范围（含）。到达边界时对应方向的按钮变灰。
    let minimum: CGFloat
    let maximum: CGFloat
    let isSelected: Bool
    let decrease: () -> Void
    let increase: () -> Void
    /// 直接写入一个数值（键入用）。**夹紧由调用方负责**——下限随屏幕变化（胶囊宽度下限
    /// 就是物理刘海宽度），只有选择器知道该取哪一档。
    let setValue: (CGFloat) -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    /// 文本框里的文本。**只有编辑中**才可能与 `value` 不同：敲进去的字符原样保留、落盘的
    /// 是夹紧后的值——否则「敲 `2` 就被夹到 185」会把光标后面还要敲的字符一起改写掉。
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    /// 文本框宽度：4 位数字（范围上限 520）在 11pt 等宽下最宽约 27pt。
    private static let fieldWidth: CGFloat = 34
    /// 文本框高度：与徽标块同档，行高因此仍是 `optionRowHeight`（面板高度照旧）。
    private static let fieldHeight: CGFloat = NotchMenuMetrics.badgeSize

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: AppTypeScale.option))
                .foregroundColor(
                    isSelected ? AppPalette.primaryText : AppPalette.secondaryText)

            Spacer(minLength: 8)

            StepperButton(
                systemName: "minus",
                label: l10n.t("Decrease"),
                isEnabled: value > minimum,
                action: { endEditingForStepping(); decrease() }
            )

            valueField

            StepperButton(
                systemName: "plus",
                label: l10n.t("Increase"),
                isEnabled: value < maximum,
                action: { endEditingForStepping(); increase() }
            )
        }
        .padding(.horizontal, NotchMenuMetrics.optionHorizontalPadding)
        .frame(height: NotchMenuMetrics.optionRowHeight)
        // 键入：先把文本归一成纯数字（粘贴 `224 pt` 也认），再逐字符写回。
        // 只在编辑中写回——`draft` 的其它来源（首次出现、外部改动、失焦归一）都是程序性同步，
        // 照单写回会在**打开选择器时就**把来源切成「自定义」。因此 `commitDraft` 只在失焦
        // 回调里跑（那一刻 `isEditing` 已是 false），回车走的是「结束键入」而不是就地归一。
        .onChange(of: draft) { _, newText in
            guard isEditing else { return }
            let digits = Self.digitsOnly(newText)
            if digits != newText { draft = digits }
            guard let typed = Self.value(fromDigits: digits) else { return }
            setValue(typed)
        }
        // 首次出现与 ± 等外部改动都在非编辑态同步进文本框；编辑中不回写，免得跟正在敲的
        // 字符打架（编辑结束后由 `commitDraft` 一次性归一）。
        // `initial: true` 而不是 `onAppear`：离屏渲染宿主不跑 `onAppear`，那样探针图里
        // 输入框会是空的（真实界面看不见这个差别，用例会）。
        .onChange(of: value, initial: true) { _, newValue in
            guard !isEditing else { return }
            draft = Self.digits(from: newValue)
        }
        .onChange(of: isEditing) { _, editing in
            guard !editing else { return }
            commitDraft()
        }
        // 可调范围在界面上无处可见（上下限随屏幕变化，如胶囊宽度下限＝物理刘海宽度），
        // 提示里补上；辅助技术读到的是「标签 当前值 范围」。
        .help(
            l10n.t(
                "%@ · %@ to %@",
                label,
                settingsLengthLabel(minimum),
                settingsLengthLabel(maximum))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(
            Text(
                "\(settingsLengthLabel(value)) (\(settingsLengthLabel(minimum))–\(settingsLengthLabel(maximum)))"
            )
        )
    }

    // MARK: - 数值输入

    /// 数值文本框 + 单位后缀。键入即生效（`setValue`），显示的值由调用方夹紧后送回。
    private var valueField: some View {
        HStack(spacing: 2) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: AppTypeScale.footnote).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .foregroundColor(AppPalette.primaryText)
                .frame(width: Self.fieldWidth)
                .focused($isEditing)
                // 回车＝结束键入（焦点交回去），由失焦回调做归一。**不**在这里直接归一：
                // 那会在 `isEditing == true` 时改写 `draft`，而改写会被下面的 onChanged 当成
                // 键入写回——「展开选择器后在空输入框里按回车」就会把来源静默切成「自定义」。
                .onSubmit { isEditing = false }

            // 单位不翻译，与 `settingsLengthLabel` 用同一个字符串。
            Text(verbatim: settingsLengthUnit)
                .font(.system(size: AppTypeScale.footnote))
                .foregroundColor(AppPalette.secondaryText)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.fieldHeight)
        .background(
            AppPalette.segmentedTrack,
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
    }

    /// 失焦：把文本框归一成**真正生效的**值——键入中途可能停在一个被夹紧前的数字上
    /// （下限随屏幕变化，输入框自己并不知道该夹到哪）。
    ///
    /// 只从失焦回调调用：那里 `isEditing` 已经是 false，写回路径因此不会被这次程序性改写
    /// 触发（见 `body` 里的两条 `onChange`）。
    private func commitDraft() {
        draft = Self.digits(from: value)
    }

    /// 点 ± 之前先结束键入：焦点不交回去的话文本框会停在一个紧接着就被步进改掉的旧数字上
    /// （macOS 的普通按钮不抢 first responder），而且要等到失焦才归一。
    private func endEditingForStepping() {
        isEditing = false
    }

    // MARK: - 文本归一（纯函数，可单测）

    /// 输入框的文本归一：只留 ASCII 数字、最多 4 位。
    ///
    /// 4 位是范围上限（520）的自然界：更长的输入没有意义，还会把文本框撑出内容宽。
    /// 只认 ASCII 数字是因为 `Character.isNumber` 也认阿拉伯-印度数字等形态，而那些字符
    /// `Int(_:)` 解析不了——会出现「看着有数字却写不进去」的怪状态。
    nonisolated static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(4))
    }

    /// 归一后的文本对应的数值；空串（或没有数字）没有数值，调用方保持原值不动。
    nonisolated static func value(fromDigits text: String) -> CGFloat? {
        guard let parsed = Int(digitsOnly(text)) else { return nil }
        return CGFloat(parsed)
    }

    /// 把一个生效值写成文本框的文本。
    nonisolated static func digits(from value: CGFloat) -> String {
        String(Int(value.rounded()))
    }
}

// MARK: - 微调按钮

private struct StepperButton: View {
    let systemName: String
    /// 无障碍与工具提示用的按钮名（「增加」/「减少」）：字形本身读不出语义。
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    isEnabled
                        ? (isHovered ? Color.white : AppPalette.hoverForeground)
                        : AppPalette.subtleText
                )
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        // 悬停底取滑块 token（同值 0.16）；静止底保持 0.08——`AppPalette` 里
                        // 同值的只有 `separator`，而按 token 文档它只画线、不当底色用。
                        .fill(
                            isHovered && isEnabled
                                ? AppPalette.segmentedThumb : Color.white.opacity(0.08))
                )
                // 命中区扩到 28×28（`NotchMenuMetrics.compactHitTarget`）：画出来的方块仍是
                // 20，但 20pt 见方的 ± 在光标下太容易落空（macOS 的舒适下限是 28）。
                .frame(
                    width: NotchMenuMetrics.compactHitTarget,
                    height: NotchMenuMetrics.compactHitTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }
}
