//
//  SoundPickerRow.swift
//  AgentIsland
//
//  设置面板中的通知音效选择行：展开块顶部一行「试听当前音效」，下面是可以点选即试听的列表。
//  试听与自动提示音都走 `NotificationSoundPlayer`：音量在那里统一应用，试听显式跳过
//  安静时段判定（刚设完时段也要能听一下）。
//

import SwiftUI

struct SoundPickerRow: View {
    @ObservedObject var soundSelector: SoundSelector
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    private var isExpanded: Bool { soundSelector.isPickerExpanded }

    /// 档位文案：音效名就是 macOS 的声音资源名（`NSSound(named:)` 按它取音源），
    /// 属专有名词，两种语言同一串，因此这里逐档写字面量键。
    ///
    /// 为什么不直接 `l10n.t(sound.rawValue)`：键必须是字面量，否则本地化守卫无法审计
    /// （会报「键必须是字面量」），这个字段也就永远漏在守卫之外。写成 switch 后，
    /// 守卫能看到这 15 个键，日后要补译也只有这一处要改。
    private func title(for sound: NotificationSound) -> String {
        switch sound {
        case .none: return l10n.t("None")
        case .pop: return l10n.t("Pop")
        case .ping: return l10n.t("Ping")
        case .tink: return l10n.t("Tink")
        case .glass: return l10n.t("Glass")
        case .blow: return l10n.t("Blow")
        case .bottle: return l10n.t("Bottle")
        case .frog: return l10n.t("Frog")
        case .funk: return l10n.t("Funk")
        case .hero: return l10n.t("Hero")
        case .morse: return l10n.t("Morse")
        case .purr: return l10n.t("Purr")
        case .sosumi: return l10n.t("Sosumi")
        case .submarine: return l10n.t("Submarine")
        case .basso: return l10n.t("Basso")
        }
    }

    /// 展开后可见的选项数：超出部分在选项列表里滚动，面板不会被音效列表撑长。
    private var visibleOptionCount: Int {
        min(NotificationSound.allCases.count, SoundSelector.maxVisibleOptions)
    }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "speaker.wave.2", tint: AppPalette.accent)),
            title: l10n.t("Notification Sound"),
            value: title(for: selectedSound),
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                // `toggleExpansion()` 而不是直接翻 Bool：展开前先收起上一个展开块
                // （面板高度只按单个展开核对，见 `PickerExpansion`）。
                withAnimation(SettingsMotion.expand) {
                    soundSelector.toggleExpansion()
                }
            }
        ) {
            VStack(spacing: 0) {
                // 试听行不参与滚动：它属于这一行，不该跟着列表滚走。
                AuditionRow(sound: selectedSound)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(NotificationSound.allCases, id: \.self) { sound in
                            SettingsOptionRow(
                                label: title(for: sound),
                                isSelected: selectedSound == sound
                            ) {
                                // 点选即试听：与上面的试听行走同一个播放器。
                                NotificationSoundPlayer.play(sound, ignoresQuietHours: true)
                                selectedSound = sound
                                AppSettings.notificationSound = sound
                            }
                        }
                    }
                }
                .frame(height: CGFloat(visibleOptionCount) * NotchMenuMetrics.optionRowHeight)
            }
        }
        .onAppear {
            selectedSound = AppSettings.notificationSound
        }
    }
}

/// 展开块顶部的试听行：播一次当前选中的音效（不改选中项，因此不必先点列表）。
private struct AuditionRow: View {
    let sound: NotificationSound

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationSoundPlayer.play(sound, ignoresQuietHours: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle")
                    .font(.system(size: 11, weight: .semibold))

                Text(l10n.t("Preview"))
                    .font(.system(size: 12))

                Spacer(minLength: 8)
            }
            .foregroundColor(isHovered ? AppPalette.primaryText : AppPalette.secondaryText)
            .padding(.horizontal, NotchMenuMetrics.optionHorizontalPadding)
            .frame(height: NotchMenuMetrics.optionRowHeight)
            .background(isHovered ? AppPalette.rowHover : Color.clear)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // `None` 档没有音源可播，禁用而不是点了没反应。
        .disabled(sound.soundName == nil)
        .help(l10n.t("Play the selected sound once."))
        .accessibilityLabel(Text(l10n.t("Preview")))
    }
}
