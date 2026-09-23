//
//  SoundPickerRow.swift
//  AgentIsland
//
//  设置面板中的通知音效选择行：展开后列出所有可选音效——macOS 内置的那批，加上用户自己放进
//  `~/Library/Sounds`（或 `/Library/Sounds`）的音频文件；**点一下即听一声并选中**，
//  因此没有单独的试听按钮。
//
//  播放走 `NotificationSoundPlayer`：音量在那里统一应用，点选试听显式跳过安静时段判定
//  （刚设完时段也要能听一下）。
//

import SwiftUI

struct SoundPickerRow: View {
    @ObservedObject var soundSelector: SoundSelector
    /// 是否是所在卡片的最后一行（最后一行不画分隔线）。
    var showsSeparator: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared

    /// 列表内容：内置音效 + 用户音效。进入页面与每次展开时重扫一次——
    /// 往 `~/Library/Sounds` 里丢个文件就能在列表里看到，不必重启应用。
    @State private var choices: [NotificationSoundChoice] = []
    /// 当前选中的 id：显示与播放都以它为准（解析回来的档位见 `AppSettings`）。
    @State private var selectedID: String = AppSettings.notificationSoundID

    private var isExpanded: Bool { soundSelector.isPickerExpanded }

    /// 展开后可见的选项数：超出部分在选项列表里滚动，面板不会被音效列表撑长。
    private var visibleOptionCount: Int {
        min(choices.count, SoundSelector.maxVisibleOptions)
    }

    var body: some View {
        SettingsPickerRow(
            badge: SettingsBadge(
                source: .symbol(name: "speaker.wave.2", tint: AppPalette.accent)),
            title: l10n.t("Notification Sound"),
            value: title(forID: selectedID),
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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        SettingsOptionRow(
                            label: title(forID: choice.id),
                            // 用户音效标出来源目录，一眼能看出它是从哪儿来的。
                            detail: choice.sourceLabel,
                            isSelected: choice.id == selectedID
                        ) {
                            // 点选即试听：这一下既是预览也是选中。
                            NotificationSoundPlayer.play(choice, ignoresQuietHours: true)
                            selectedID = choice.id
                            AppSettings.notificationSoundID = choice.id
                        }
                    }
                }
            }
            .frame(height: CGFloat(visibleOptionCount) * NotchMenuMetrics.optionRowHeight)
        }
        .onAppear(perform: reload)
        // 展开时重扫：刚放进用户目录的音效要能立刻出现在列表里。
        .onChange(of: isExpanded) { _, expanded in
            if expanded { reload() }
        }
    }

    // MARK: - 私有

    private func reload() {
        choices = NotificationSoundLibrary.choices()
        selectedID = AppSettings.notificationSoundID
    }

    /// 档位文案：内置音效名就是 macOS 的声音资源名（`NSSound(named:)` 按它取音源），
    /// 属专有名词，两种语言同一串，因此这里逐档写字面量键。
    ///
    /// 为什么不直接 `l10n.t(sound.rawValue)`：键必须是字面量，否则本地化守卫无法审计
    /// （会报「键必须是字面量」），这个字段也就永远漏在守卫之外。写成 switch 后，
    /// 守卫能看到这些键；用户音效则直接用文件名（那是用户的命名，不翻译）。
    private func title(forID id: String) -> String {
        guard let sound = NotificationSound(rawValue: id) else {
            // 解析不到内置档（用户音效的文件名，或已失效的值）：用解析回来的档位名。
            return NotificationSoundLibrary.choice(forID: id).title
        }

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
}
