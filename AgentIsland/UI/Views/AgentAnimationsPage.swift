//
//  AgentAnimationsPage.swift
//  AgentIsland
//
//  「标记动态」设置页：把各 Agent 的运行时**像素角色**一次铺开——顶上一行选活动状态
//  （空闲 / 处理中 / 待审批），一行选预览速度（静止 / 0.5× / 1× / 2×），下面一台
//  大舞台的网格把 18 枚角色同时演给你看。
//
//  入口在这一页自己的行里：它曾经是「智能体」页页眉的一枚小按钮，实测用户注意不到
//  （「找不着动画在哪」），现在换成「监控的智能体」卡片的第一行——带**轮播**的角色
//  缩略图与副标题，点它进这一页（见 `AgentAnimationsEntryRow`）。
//
//  这一页**不占侧栏位**（侧栏只放一级分组，入口在「监控的智能体」卡片第一行）。
//  高度是定值（`NotchMenuMetrics.animationsSectionHeight`）：画廊窗口封顶、超出的在
//  画廊里滚动，因此新增 Agent 不会把面板撑长。
//

import SwiftUI

// MARK: - 预览速度

/// 「标记动态」页的预览倍速。
///
/// **不写偏好**：它只影响这一页的渲染（与状态选择同一口径），所以不进 `AppSettings`，
/// 也不占别页的版面预算——用户要的是「放慢看清细节」，不是长期改动画速度。
private enum AgentPreviewSpeed: CaseIterable, Hashable {
    /// 完全停住（定格在各场景的代表时刻，见 `AgentMascotStatus.stillInstant`），
    /// 用来细看角色的静态姿势。
    case still
    case half
    case normal
    case fast

    /// 传给角色时钟的倍速；0 表示不跑时钟。
    var value: Double {
        switch self {
        case .still: return 0
        case .half: return 0.5
        case .normal: return 1
        case .fast: return 2
        }
    }
}

// MARK: - 页面

struct AgentAnimationsSettingsPage: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 预览的活动状态与速度：只影响这一页的渲染，不写任何偏好。
    @State private var status: AgentMascotStatus = .working
    @State private var speed: AgentPreviewSpeed = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMenuMetrics.groupSpacing) {
            SettingsGroup(
                footnote: l10n.t(
                    "Every agent has its own pixel mascot: it breathes when idle, works when busy, and jumps when it needs you."
                )
            ) {
                AgentStatusPreviewRow(status: $status)
                AgentSpeedPreviewRow(speed: $speed)
                AgentMascotGallery(status: status, speed: speed.value)
            }
        }
    }
}

// MARK: - 「智能体」页的入口行

/// 「标记动态」的入口行：卡片第一行，左侧是**轮播**的角色缩略图（每 2.5s 换一位 Agent），
/// 右侧是标题与副标题，尾部一个 chevron。
///
/// 它替换掉的是「智能体」页页眉里那枚 11 号字的小按钮——那枚按钮实测没人找得到。
/// 代价是一行 48pt：智能体页的高度预算贴着上限（见 `NotchMenuMetrics.blocks(for:)`），
/// 这一行是从「监控的智能体」卡片的可见行数里挪出来的（5 → 4 行，卡片仍渲染全部行、
/// 只是在卡内滚动）。
struct AgentAnimationsEntryRow: View {
    let action: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SettingsRowLabel(
                badge: SettingsBadge(source: .mascot),
                title: l10n.t("Animations"),
                subtitle: l10n.t("Preview every agent's pixel mascot")
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppPalette.tertiaryText)
            }
            .frame(height: NotchMenuMetrics.twoLineRowHeight)
            .background(
                RoundedRectangle(cornerRadius: NotchMenuMetrics.cardRadius, style: .continuous)
                    .fill(isHovered ? AppPalette.rowHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovered = $0 }
        .settingsRowSeparator(true)
    }
}

// MARK: - 两行预览控件

/// 状态选择行：空闲 / 处理中 / 待审批。行内分段控件，不展开、不撑高面板。
private struct AgentStatusPreviewRow: View {
    @Binding var status: AgentMascotStatus

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .symbol(name: "sparkles", tint: AppPalette.accent)),
            title: l10n.t("Activity")
        ) {
            AgentPreviewSegmentedControl(
                options: [
                    (value: AgentMascotStatus.idle, title: l10n.t("Idle")),
                    (value: .working, title: l10n.t("Working")),
                    (value: .alert, title: l10n.t("Needs Approval")),
                ],
                thumbID: "mascot-status-thumb",
                selection: $status
            )
        }
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(true)
    }
}

/// 速度选择行：静止 / 0.5× / 1× / 2×。放慢是为了看清细节，停下是为了看静态姿势。
private struct AgentSpeedPreviewRow: View {
    @Binding var speed: AgentPreviewSpeed

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsRowLabel(
            badge: SettingsBadge(source: .symbol(name: "speedometer", tint: AppPalette.accent)),
            title: l10n.t("Speed")
        ) {
            AgentPreviewSegmentedControl(
                options: [
                    (value: AgentPreviewSpeed.still, title: l10n.t("Still")),
                    (value: .half, title: l10n.t("0.5×")),
                    (value: .normal, title: l10n.t("1×")),
                    (value: .fast, title: l10n.t("2×")),
                ],
                thumbID: "mascot-speed-thumb",
                selection: $speed
            )
        }
        .frame(height: NotchMenuMetrics.rowHeight)
        .settingsRowSeparator(true)
    }
}

/// 行内的小分段控件：把「一组等宽档位」收进一行里。做法与分组切换条同源（滑块
/// `matchedGeometryEffect` 滑过去，而不是各段各自亮一下），只是尺寸收进一行里。
///
/// 文案由调用方在它自己的视图主体里解析好再传进来：本地化键必须是字面量，
/// 守卫（`check-localization.py`）才审计得到，所以这里不接「键 → 文案」的闭包。
private struct AgentPreviewSegmentedControl<Option: Hashable>: View {
    /// 档位与它已本地化的短标签，一一对应。
    let options: [(value: Option, title: String)]
    /// 滑块动画的命名空间 id：一页里有两条分段控件，共用 id 会把两边的滑块认成同一个。
    let thumbID: String
    @Binding var selection: Option

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppPalette.segmentedTrack)
        )
    }

    private func segment(_ option: (value: Option, title: String)) -> some View {
        let isSelected = option.value == selection

        return Button {
            withAnimation(SettingsMotion.segment) { selection = option.value }
        } label: {
            Text(option.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(
                    isSelected ? AppPalette.primaryText : AppPalette.secondaryText
                )
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppPalette.segmentedThumb)
                            .matchedGeometryEffect(id: thumbID, in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .accessibilityLabel(Text(option.title))
    }
}

// MARK: - 画廊

/// 各 Agent 角色的画廊：渲染**全部** Agent（只截断窗口高度，超出的在画廊里滚动），
/// 与「监控的智能体」卡片同一条不变量——否则窗口外的 Agent 就永远看不到它的动效。
///
/// 整台画廊只跑**一个**时钟，每一格用 `frozenTime:` 定帧渲染：
/// 18 枚角色各开一份 `TimelineView` 会把设置面板的动效开销翻 18 倍，而它们的相位
/// 本来就取自同一个 epoch，用一个时钟反而让所有角色天然同相。
private struct AgentMascotGallery: View {
    let status: AgentMascotStatus
    /// 预览倍速；0 = 静止（不跑时钟，按 `AgentMascotStatus.stillInstant` 定格）。
    let speed: Double

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: NotchMenuMetrics.animationGalleryColumnSpacing),
        count: NotchMenuMetrics.animationGalleryColumns
    )

    var body: some View {
        Group {
            if speed == 0 {
                grid(at: status.stillInstant)
            } else {
                TimelineView(
                    .periodic(from: MascotMotion.epoch, by: status.frameInterval)
                ) { context in
                    grid(at: context.date.timeIntervalSince(MascotMotion.epoch) * speed)
                }
            }
        }
        .frame(height: NotchMenuMetrics.animationGalleryHeight)
    }

    private func grid(at time: Double) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: NotchMenuMetrics.animationGalleryRowSpacing) {
                ForEach(AgentKind.allCases) { kind in
                    AgentMascotTile(kind: kind, status: status, time: time)
                }
            }
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
            .padding(.bottom, NotchMenuMetrics.rowVerticalPadding)
        }
    }
}

/// 画廊里的一格：黑色舞台 + 正在动的角色，下面一行短名。
private struct AgentMascotTile: View {
    let kind: AgentKind
    let status: AgentMascotStatus
    /// 画廊那个共享时钟给出的时刻；这一格按它定帧（不再各自开时钟）。
    let time: Double

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)

                AgentMascot(
                    agent: kind, status: status,
                    size: NotchMenuMetrics.animationGalleryMascotSize,
                    frozenTime: time
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchMenuMetrics.animationGalleryMarkTileHeight)

            Text(kind.shortName)
                .font(.system(size: 10))
                .foregroundColor(AppPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: NotchMenuMetrics.animationGalleryTileTextHeight)
        }
        .frame(height: NotchMenuMetrics.animationGalleryTileHeight)
    }
}
