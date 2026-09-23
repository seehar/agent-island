//
//  NotificationSoundPlayer.swift
//  AgentIsland
//
//  提示音的播放收口：音效、音量、安静时段三处设置都在这里应用。
//
//  两个调用点——设置行里的点选即听、完成/待批到达时的自动提示音——共用这一条路径，
//  避免「音量只在一边生效」「安静时段漏判一侧」这类分叉。点选试听要能听见，
//  因此它显式跳过安静时段判定。
//

import AppKit
import Foundation

@MainActor
enum NotificationSoundPlayer {
    /// 按当前设置播一声提示音。
    ///
    /// - Parameters:
    ///   - choice: 要播的档位；「无」档与解析不到的来源都不播。
    ///   - ignoresQuietHours: 试听用（刚设完安静时段还要能听一下）。
    /// - Returns: 是否真的播了。设置行与排查都用这个返回值，不靠猜。
    @discardableResult
    static func play(
        _ choice: NotificationSoundChoice, ignoresQuietHours: Bool = false
    ) -> Bool {
        if !ignoresQuietHours,
            PreferenceStore.read(QuietHours.self).covers(Date())
        {
            return false
        }

        guard let player = self.player(for: choice) else { return false }
        // 音量必须在 `play()` 之前设：NSSound 每次都是新实例，改完再播才生效。
        player.volume = Float(AppSettings.notificationVolume())
        return player.play()
    }

    /// 按来源取播放器：内置走 `NSSound(named:)`（系统按标准目录查找），
    /// 用户音效按路径加载（`byReference: false`：当场读进内存，文件之后被删也不影响这一声）。
    private static func player(for choice: NotificationSoundChoice) -> NSSound? {
        switch choice.playback {
        case .silent:
            return nil
        case .named(let name):
            return NSSound(named: name)
        case .file(let url):
            return NSSound(contentsOf: url, byReference: false)
        }
    }
}
