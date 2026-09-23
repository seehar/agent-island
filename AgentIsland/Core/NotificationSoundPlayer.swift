//
//  NotificationSoundPlayer.swift
//  AgentIsland
//
//  提示音的播放收口：音效、音量、安静时段三处设置都在这里应用。
//
//  两个调用点——设置行里的试听、完成/待批到达时的自动提示音——共用这一条路径，
//  避免「音量只在一边生效」「安静时段漏判一侧」这类分叉。试听要能听见，
//  因此它显式跳过安静时段判定。
//

import AppKit
import Foundation

@MainActor
enum NotificationSoundPlayer {
    /// 按当前设置播一声提示音。
    ///
    /// - Parameters:
    ///   - sound: 要播的音效；`None` 档不播。
    ///   - ignoresQuietHours: 试听用（刚设完安静时段还要能听一下）。
    /// - Returns: 是否真的播了。设置行与排查都用这个返回值，不靠猜。
    @discardableResult
    static func play(_ sound: NotificationSound, ignoresQuietHours: Bool = false) -> Bool {
        guard let soundName = sound.soundName else { return false }

        if !ignoresQuietHours,
            PreferenceStore.read(QuietHours.self).covers(Date())
        {
            return false
        }

        guard let player = NSSound(named: soundName) else { return false }
        // 音量必须在 `play()` 之前设：NSSound 每次都是新实例，改完再播才生效。
        player.volume = Float(AppSettings.notificationVolume())
        return player.play()
    }
}
