//
//  NotificationSoundLibrary.swift
//  AgentIsland
//
//  可选提示音的来源与解析：macOS 内置音效（`/System/Library/Sounds`，名字即
//  `NSSound(named:)` 的键）＋用户自己放进 `~/Library/Sounds`（或 `/Library/Sounds`）的音频文件。
//
//  为什么把用户目录也算进来：内置音效只有 14 个，而「换一个顺耳的提示音」是很个人的事——
//  macOS 的提示音本来就支持用户自带音效（系统设置里那份列表就来自这几个目录），
//  这里跟着它走，用户放进去的文件会直接出现在列表里。
//
//  持久化只存 id：内置存声音名（与历史偏好完全兼容），用户文件存 `file:<绝对路径>`。
//  文件被删或目录改名后解析不到，就回退到内置默认档（见 `choice(forID:)`），
//  不会出现「设置里显示了一个播不出来/播成别的音效」的状态。
//

import Foundation

/// 一个可选的提示音。
nonisolated struct NotificationSoundChoice: Identifiable, Hashable, Sendable {
    /// 播放方式。
    enum Playback: Hashable, Sendable {
        /// `NSSound(named:)`：macOS 内置音效。
        case named(String)
        /// 用户目录里的音频文件。
        case file(URL)
        /// 不出声（「无」档）。
        case silent
    }

    /// 持久化用的 id：内置＝声音名；用户文件＝`file:<绝对路径>`。
    let id: String
    /// 列表里显示的名字。
    let title: String
    /// 列表右侧的来源说明（内置档不显示；用户音效显示它所在的目录）。
    let sourceLabel: String?
    let playback: Playback

    var isSilent: Bool { playback == .silent }
}

nonisolated enum NotificationSoundLibrary {
    // MARK: - 内置音效

    /// macOS 内置的那批（`NotificationSound` 的枚举就是它们的名字表）。
    /// 名字属专有名词，展示文案在视图里按字面量取键（本地化守卫才审计得到）。
    static let builtInChoices: [NotificationSoundChoice] = NotificationSound.allCases.map { sound in
        NotificationSoundChoice(
            id: sound.rawValue,
            title: sound.rawValue,
            sourceLabel: nil,
            playback: sound.soundName.map { .named($0) } ?? .silent
        )
    }

    /// 没设过 / 设的值已失效时用的档（与改造前一致：Pop）。
    static var defaultChoice: NotificationSoundChoice {
        builtInChoices.first { $0.id == NotificationSound.defaultSound.rawValue }
            ?? builtInChoices[0]
    }

    // MARK: - 用户音效

    /// 会被认成音效的扩展名。与 `NSSound` 能解码的常见格式对齐（它是 CoreAudio 的封装，
    /// 这些都能放）；不认的扩展名（txt/md…）直接跳过，避免列表里出现点了没反应的档位。
    static let supportedExtensions: Set<String> = [
        "aif", "aiff", "aifc", "au", "caf", "m4a", "mp3", "wav",
    ]

    /// 默认要扫的目录：用户音效优先，其次是全机器共用的那个（管理员放的）。
    static var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Sounds", isDirectory: true),
            URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
        ]
    }

    /// 列表内容：内置在前（顺序稳定），用户音效按文件名排在后面。
    static func choices(
        directories: [URL] = defaultDirectories,
        fileManager: FileManager = .default
    ) -> [NotificationSoundChoice] {
        builtInChoices + userChoices(directories: directories, fileManager: fileManager)
    }

    /// 扫用户目录里的音频文件。目录不存在或读不到都只是「没有用户音效」，不是错误。
    static func userChoices(
        directories: [URL],
        fileManager: FileManager = .default
    ) -> [NotificationSoundChoice] {
        var seenPaths = Set<String>()
        var choices: [NotificationSoundChoice] = []

        for directory in directories {
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
            else { continue }

            // 按文件名排序，且**不分大小写**（与访达一致：alpha 在 Beta 前面）；
            // 仅在忽略大小写后同名时，用原始串兜底，保证顺序稳定。
            let ordered = entries.sorted { lhs, rhs in
                let left = lhs.lastPathComponent.lowercased()
                let right = rhs.lastPathComponent.lowercased()
                return left == right ? lhs.lastPathComponent < rhs.lastPathComponent : left < right
            }
            for entry in ordered {
                let ext = entry.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }

                // 同一个文件可能同时被两个目录命中（软链/重复放置）：按真实路径去重。
                let resolved = entry.resolvingSymlinksInPath().path
                guard seenPaths.insert(resolved).inserted else { continue }

                choices.append(
                    NotificationSoundChoice(
                        id: fileID(for: entry),
                        title: entry.deletingPathExtension().lastPathComponent,
                        sourceLabel: shortPathLabel(for: directory),
                        playback: .file(entry)
                    )
                )
            }
        }

        return choices
    }

    // MARK: - 解析

    /// 解析持久化的 id。
    ///
    /// 用户音效的文件没了（删掉、目录改名、换机器）时**回退到内置默认档**：
    /// 界面上显示的就是真正会响的那一个，不会留下「显示 A、响 B／不响」的状态。
    static func choice(
        forID id: String,
        directories: [URL] = defaultDirectories,
        fileManager: FileManager = .default
    ) -> NotificationSoundChoice {
        if let builtIn = builtInChoices.first(where: { $0.id == id }) { return builtIn }
        if let fileChoice = userChoices(directories: directories, fileManager: fileManager)
            .first(where: { $0.id == id })
        {
            return fileChoice
        }
        return defaultChoice
    }

    // MARK: - 私有

    /// 用户音效的持久化 id：`file:<绝对路径>`（路径即身份，改名就是另一个音效）。
    nonisolated static func fileID(for url: URL) -> String {
        "file:" + url.standardizedFileURL.path
    }

    /// 来源说明：`~/Library/Sounds` 写成 `~/Library/Sounds`，其余写绝对路径——
    /// 用户一眼就知道这个音效是从哪儿来的。
    private static func shortPathLabel(for directory: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = directory.standardizedFileURL.path
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
