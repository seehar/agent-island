//
//  NotificationSoundLibraryTests.swift
//  AgentIslandTests
//
//  提示音来源的解析：内置档的顺序与 id 稳定（历史偏好存的就是这些名字）、
//  用户目录里只认音频扩展名、按路径去重、id 解析不到时回退内置默认档。
//  全部在临时目录上跑，不碰用户的 ~/Library/Sounds。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("提示音来源")
struct NotificationSoundLibraryTests {
    /// 造一个「用户音效目录」：两个音频 + 一个不该被认出来的文本文件。
    private func makeSoundDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-island-sounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["Beta.wav", "alpha.caf", "notes.txt"] {
            try Data("not-a-real-sound".utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test("内置档的顺序与 id 就是声音名：历史偏好（存 rawValue）因此继续有效")
    func builtInChoicesKeepStableIDs() {
        let builtIns = NotificationSoundLibrary.builtInChoices
        #expect(builtIns.map(\.id) == NotificationSound.allCases.map(\.rawValue))
        // 「无」档不出声，其余都是 `NSSound(named:)` 的键。
        #expect(builtIns.filter(\.isSilent).map(\.id) == [NotificationSound.none.rawValue])
        #expect(builtIns.filter { !$0.isSilent }.allSatisfy { choice in
            if case .named = choice.playback { return true }
            return false
        })
    }

    @Test("默认档与改造前一致（Pop），且解析不到内置名时也回退到它")
    func defaultChoiceMatchesPreviousBehavior() {
        #expect(NotificationSound.defaultSound == .pop)
        #expect(NotificationSoundLibrary.defaultChoice.id == "Pop")

        let unknown = NotificationSoundLibrary.choice(forID: "file:/nope/missing.wav", directories: [])
        #expect(unknown.id == "Pop", "失效的 id 回退到默认档，而不是留下播不出来的一档")
        #expect(NotificationSoundLibrary.choice(forID: "", directories: []).id == "Pop")
    }

    @Test("用户目录：只认音频扩展名、按文件名排序、id 是 file:<路径>")
    func userChoicesFilterAndOrder() throws {
        let directory = try makeSoundDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let choices = NotificationSoundLibrary.userChoices(directories: [directory])
        #expect(choices.map(\.title) == ["alpha", "Beta"], "按文件名排序，跳过 notes.txt")
        #expect(choices.allSatisfy { $0.id.hasPrefix("file:") })
        #expect(choices.allSatisfy { $0.sourceLabel != nil }, "用户音效要标出来源目录")
        #expect(NotificationSoundLibrary.choices(directories: [directory]).count
            == NotificationSoundLibrary.builtInChoices.count + 2)
    }

    @Test("同一目录重复给出时不重复列出（按真实路径去重）")
    func userChoicesDeduplicateByPath() throws {
        let directory = try makeSoundDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let choices = NotificationSoundLibrary.userChoices(directories: [directory, directory])
        #expect(choices.count == 2)
    }

    @Test("目录不存在只是「没有用户音效」，不是错误")
    func missingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-island-no-such-dir-\(UUID().uuidString)")
        #expect(NotificationSoundLibrary.userChoices(directories: [missing]).isEmpty)
    }
}
