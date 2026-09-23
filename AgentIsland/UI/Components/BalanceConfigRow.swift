//
//  BalanceConfigRow.swift
//  AgentIsland
//
//  「额度」页的配置行：图标块 + 标题 + 说明 + 右侧文本框（密钥类带显示/隐藏切换）。
//  这是设置面板里**唯一**的字符串输入行——既有行都是选择 / 开关 / 滑杆 / 按钮。
//  行高由组件自己固定在 `twoLineRowHeight`，`NotchMenuMetrics.blocks(for:)` 的版面表
//  因此与真实排版一致（改行高要同时改那边）。
//

import SwiftUI

/// 配置行：一行一个字符串设置项。
struct BalanceConfigRow: View {
    let badge: SettingsBadge
    let title: String
    let subtitle: String
    @Binding var text: String
    /// 密钥类字段：默认用 `SecureField`，右侧多一个显示 / 隐藏按钮。
    var isSecret: Bool = false
    var placeholder: String = ""
    var showsSeparator: Bool = true
    /// 文本框宽度。默认值给短值（`sk-…` / 令牌 / 用户 ID）留足标签列；服务器地址那行要宽一些，
    /// 否则 `https://your.newapi.host` 这类值在行里会被截掉尾巴（实测：150pt 只放得下
    /// 约 24 个字符）。
    var fieldWidth: CGFloat = 150
    /// 回车提交：写回偏好域并重新取数。
    var onSubmit: () -> Void = {}

    @ObservedObject private var l10n = LocalizationManager.shared
    /// 密钥字段的明文 / 密文切换（只影响这一行的显示，不落盘、不改变行高）。
    @State private var isRevealed = false

    var body: some View {
        SettingsRowLabel(badge: badge, title: title, subtitle: subtitle) {
            HStack(spacing: 6) {
                field
                if isSecret { revealButton }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .settingsRowSeparator(showsSeparator)
    }

    // MARK: - 输入

    /// 文本输入框：宽度固定、单行，行高因此不随内容变化。
    private var field: some View {
        Group {
            if isSecret && !isRevealed {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .foregroundColor(AppPalette.primaryText)
        .frame(width: fieldWidth)
        .onSubmit(onSubmit)
    }

    /// 明文 / 密文切换：默认密文（肩窥时看不到密钥），点一下变明文，便于核对粘进来的值。
    private var revealButton: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppPalette.tertiaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .help(isRevealed ? l10n.t("Hide") : l10n.t("Show"))
        .accessibilityLabel(Text(isRevealed ? l10n.t("Hide") : l10n.t("Show")))
    }
}
