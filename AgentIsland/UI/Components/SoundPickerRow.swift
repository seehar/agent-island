//
//  SoundPickerRow.swift
//  AgentIsland
//
//  设置面板中的通知音效选择行：点选项即试听，因此不需要单独的试听按钮。
//

import AppKit
import SwiftUI

struct SoundPickerRow: View {
    @ObservedObject var soundSelector: SoundSelector
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    private var isExpanded: Bool { soundSelector.isPickerExpanded }

    /// 展开后可见的选项数：超出部分在选项列表里滚动，面板不会被音效列表撑长。
    private var visibleOptionCount: Int {
        min(NotificationSound.allCases.count, SoundSelector.maxVisibleOptions)
    }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "speaker.wave.2", tint: SettingsPalette.accent)),
            title: l10n.t("Notification Sound"),
            value: selectedSound.rawValue,
            isExpanded: isExpanded,
            showsSeparator: showsSeparator,
            onToggle: {
                withAnimation(SettingsMotion.expand) {
                    soundSelector.isPickerExpanded.toggle()
                }
            }
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(NotificationSound.allCases, id: \.self) { sound in
                        SettingsOptionRow(
                            label: sound.rawValue,
                            isSelected: selectedSound == sound
                        ) {
                            // 点选即试听：这是唯一的音频预览入口
                            if let soundName = sound.soundName {
                                NSSound(named: soundName)?.play()
                            }
                            selectedSound = sound
                            AppSettings.notificationSound = sound
                        }
                    }
                }
            }
            .frame(height: CGFloat(visibleOptionCount) * NotchMenuMetrics.optionRowHeight)
        }
        .onAppear {
            selectedSound = AppSettings.notificationSound
        }
    }
}
