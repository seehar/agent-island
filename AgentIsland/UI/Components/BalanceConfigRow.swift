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
    /// 文本框的**理想上限**宽度。默认值给短值（`sk-…` / 令牌 / 用户 ID）留足标签列；
    /// 服务器地址那行要宽一档，否则 `https://your.newapi.host` 这类值会被截掉尾巴
    /// （实测：150pt 只放得下约 24 个字符）。
    ///
    /// 它是上限而不是定值：面板宽度随 `PanelSize` 缩放，写死宽度在紧凑档会把标签列
    /// 挤成省略号（真机实测）。实际宽度按这一行实测的可用宽取小（见 `resolvedFieldWidth`）。
    var preferredFieldWidth: CGFloat = 150
    /// 回车提交：写回偏好域并重新取数。
    var onSubmit: () -> Void = {}

    @ObservedObject private var l10n = LocalizationManager.shared
    /// 密钥字段的明文 / 密文切换（只影响这一行的显示，不落盘、不改变行高）。
    @State private var isRevealed = false
    /// 这一行实测到的宽度：探针挂在背景上、不参与排版，只用来算文本框宽度。
    @State private var measuredWidth: CGFloat = 0

    /// 标签列下限：低于它标题就会变成省略号（紧凑档实测）。
    private static let minimumLabelWidth: CGFloat = 130
    /// 文本框再窄也要放得下 `sk-…` 这类短值。
    private static let minimumFieldWidth: CGFloat = 90
    /// `SettingsRowLabel` 里 `Spacer(minLength: 8)` 给标签列与尾部之间留的间隙。
    private static let trailingSpacer: CGFloat = 8
    /// 文本框与显示 / 隐藏按钮之间的间距（`body` 的 `HStack` 与宽度推导共用）。
    private static let revealGap: CGFloat = 6
    /// 显示 / 隐藏按钮的命中框边长（画出来的方块是 16×16，命中框撑到 28×28）。
    private static let revealHitTarget: CGFloat = 28

    var body: some View {
        SettingsRowLabel(badge: badge, title: title, subtitle: subtitle) {
            HStack(spacing: Self.revealGap) {
                field
                if isSecret { revealButton }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotchMenuMetrics.twoLineRowHeight)
        .background(widthProbe)
        .settingsRowSeparator(showsSeparator)
    }

    // MARK: - 输入

    /// 文本输入框：宽度按这一行的可用宽算（单行，行高因此不随内容变化）。
    private var field: some View {
        Group {
            if isSecret && !isRevealed {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: AppTypeScale.option))
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .foregroundColor(AppPalette.primaryText)
        .frame(width: resolvedFieldWidth)
        .onSubmit(onSubmit)
    }

    /// 量一下这一行有多宽：`GeometryReader` 挂在背景上，不改变排版。
    ///
    /// 量不到（首帧 / 离屏渲染宿主）时先用理想上限，拿到宽度后重排一次——两帧都只在
    /// 紧凑档有差别，而行高两帧都一样。
    private var widthProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { measuredWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in measuredWidth = width }
        }
    }

    /// 文本框宽度 = 理想上限与可用宽的较小者（内部可见：单测钉住「紧凑档也不挤掉标签列」）。
    ///
    /// `available` 是这一行扣掉左右内边距与徽标块之后、留给「标签列 + 尾部控件」的宽度；
    /// 这里再扣掉标签列下限与尾部间隙，密钥行还要扣掉显示 / 隐藏按钮那一段。
    static func fieldWidth(preferred: CGFloat, available: CGFloat, isSecret: Bool) -> CGFloat {
        guard available > 0 else { return preferred }
        var chrome = minimumLabelWidth + trailingSpacer
        if isSecret { chrome += revealGap + revealHitTarget }
        return min(preferred, max(minimumFieldWidth, available - chrome))
    }

    /// 这一行实测到的宽度 − 左右内边距 − 徽标块 = 留给「标签列 + 尾部控件」的可用宽。
    ///
    /// 宽度是**实测**的而不是按面板档位推的：面板宽还受屏幕宽夹取（见
    /// `NotchViewModel.openedSize`），只有量出来的才是真的。首帧还没量到（离屏渲染宿主
    /// 也不会走 `onAppear`）时按理想上限来，那一帧的宽度与会话界面无关。
    private var resolvedFieldWidth: CGFloat {
        guard measuredWidth > 0 else { return preferredFieldWidth }
        let available =
            measuredWidth - 2 * NotchMenuMetrics.rowHorizontalPadding
            - NotchMenuMetrics.badgeSize - NotchMenuMetrics.badgeGap
        return Self.fieldWidth(
            preferred: preferredFieldWidth, available: available, isSecret: isSecret)
    }

    /// 明文 / 密文切换：默认密文（肩窥时看不到密钥），点一下变明文，便于核对粘进来的值。
    ///
    /// 画出来的方块仍是 16×16，命中框撑到 28×28（`contentShape` 只扩命中面，
    /// 不改版面、不改行高）：16pt 的图标按钮低于可点下限。
    private var revealButton: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppPalette.tertiaryText)
                .frame(width: 16, height: 16)
                .frame(
                    minWidth: Self.revealHitTarget, minHeight: Self.revealHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .help(isRevealed ? l10n.t("Hide") : l10n.t("Show"))
        .accessibilityLabel(Text(isRevealed ? l10n.t("Hide") : l10n.t("Show")))
    }
}
