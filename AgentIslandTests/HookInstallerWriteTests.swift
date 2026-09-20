//
//  HookInstallerWriteTests.swift
//  AgentIslandTests
//
//  写回路径的端到端用例：全部在临时目录里跑，不碰真实的 ~/.claude。
//  这三条钉的是「一次启动把用户整份 Claude Code 配置清空」这个具体事故：
//  坏输入必须一个字节都不写、好输入必须原样保留其它键、同一份输入不能反复改文件。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("settings.json 写回路径")
struct HookInstallerWriteTests {
    /// 每个用例一个独立临时目录，避免相互干扰。
    private func makeTempSettings(_ contents: String?) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-island-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        if let contents {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return file
    }

    @Test("坏输入：一个字节都不写（原文件保持原样）")
    func hostileSettingsAreLeftUntouched() throws {
        let hostile = "[1, 2, 3]"
        let file = try makeTempSettings(hostile)
        let before = try Data(contentsOf: file)

        HookInstaller.updateSettings(at: file)

        #expect(try Data(contentsOf: file) == before)
        // 也不能留下备份文件（没写就没得备）
        let backup = file.appendingPathExtension("agent-island-backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("好输入：其它键原样保留，只追加 hooks，并留下备份")
    func validSettingsKeepEverythingElse() throws {
        let original = #"{"model":"opus","env":{"FOO":"1"},"permissions":{"allow":["Bash(ls:*)"]}}"#
        let file = try makeTempSettings(original)

        HookInstaller.updateSettings(at: file)

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["model"] as? String == "opus")
        #expect((json["env"] as? [String: Any])?["FOO"] as? String == "1")
        #expect(json["permissions"] != nil)
        #expect(json["hooks"] != nil)

        let backup = file.appendingPathExtension("agent-island-backup")
        #expect(try Data(contentsOf: backup) == Data(original.utf8))
    }

    @Test("同一份输入重复调用不再改写文件")
    func repeatedInstallIsIdempotent() throws {
        let file = try makeTempSettings(#"{"model":"opus"}"#)

        HookInstaller.updateSettings(at: file)
        let afterFirst = try Data(contentsOf: file)
        HookInstaller.updateSettings(at: file)

        #expect(try Data(contentsOf: file) == afterFirst)
    }

    @Test("文件不存在时新建，且不留下备份")
    func absentFileIsCreated() throws {
        let file = try makeTempSettings(nil)

        HookInstaller.updateSettings(at: file)

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["hooks"] != nil)
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("agent-island-backup").path))
    }
}
