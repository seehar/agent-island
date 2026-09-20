//
//  HookSettingsMergerTests.swift
//  AgentIslandTests
//
//  settings.json 合并的安全性。这组用例钉的是一个真实风险：旧实现读不到／读不懂配置时
//  把字典退回空 [:] 后**仍然写回**，等于一次启动就把用户整份 Claude Code 配置清空
//  （env / permissions / statusLine / 插件全没了）。所以每条断言都在问同一个问题：
//  这个输入允许写回吗？
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("Claude settings.json 合并安全性")
struct HookSettingsMergerTests {
    /// 本应用的 hook 命令判定（含改名前的旧脚本名）。
    private func isOwn(_ command: String) -> Bool {
        command.contains("agent-island-state.py") || command.contains("claude-island-state.py")
    }

    /// 一份「有真实内容」的用户配置：合并后这些键必须一个不少。
    private var userSettings: [String: Any] {
        [
            "model": "opus",
            "env": ["FOO": "1"],
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": "python3 ~/.claude/hooks/agent-island-state.py",
                            ]
                        ]
                    ],
                    ["hooks": [["type": "command", "command": "echo keep-me"]]],
                ]
            ],
        ]
    }

    @Test("文件不存在时允许新建")
    func absentFileIsWritable() {
        let load = HookSettingsMerger.load(data: nil, fileExists: false)
        #expect(load.refusalReason == nil)
        #expect(load.settings.isEmpty)
    }

    @Test("只有空白的文件等同没有配置")
    func whitespaceOnlyFileIsTreatedAsAbsent() {
        let load = HookSettingsMerger.load(data: Data("  \n".utf8), fileExists: true)
        #expect(load.refusalReason == nil)
    }

    @Test("读不到内容时拒绝写入")
    func unreadableFileIsRefused() {
        let load = HookSettingsMerger.load(data: nil, fileExists: true)
        #expect(load.refusalReason != nil)
    }

    @Test("坏 JSON 与顶层不是对象时拒绝写入")
    func malformedFileIsRefused() {
        #expect(HookSettingsMerger.load(data: Data("{".utf8), fileExists: true).refusalReason != nil)
        #expect(
            HookSettingsMerger.load(data: Data("[1, 2]".utf8), fileExists: true).refusalReason != nil)
        // 手改时留下注释的 JSON 解析同样失败 —— 也必须拒绝写入，而不是把配置清零
        #expect(
            HookSettingsMerger.load(data: Data("{\"a\":1,//note\n}".utf8), fileExists: true)
                .refusalReason != nil)
    }

    @Test("合并只动 hooks，其它键一个不丢")
    func mergePreservesUnrelatedKeys() {
        let merged = HookSettingsMerger.appending(
            hookEvents: [(
                event: "SessionStart",
                entries: [["hooks": [["type": "command", "command": "python3 new-hook.py"]]]]
            )],
            to: HookSettingsMerger.strippingOwnHooks(from: userSettings, isOwnCommand: isOwn)
        )

        #expect(merged["model"] as? String == "opus")
        #expect((merged["env"] as? [String: Any])?["FOO"] as? String == "1")
        #expect(merged["permissions"] != nil)
        #expect(merged["hooks"] != nil)
    }

    @Test("所有事件上的本应用 hook 都被摘掉，别人的 hook 留着")
    func strippingRemovesOwnHooksEverywhere() {
        let stripped = HookSettingsMerger.strippingOwnHooks(from: userSettings, isOwnCommand: isOwn)
        let entries = (stripped["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        #expect(entries?.count == 1)

        let commands = (entries?.first?["hooks"] as? [[String: Any]])?.compactMap {
            $0["command"] as? String
        }
        #expect(commands == ["echo keep-me"])
    }

    @Test("摘干净后 hooks 键本身也消失")
    func strippingRemovesEmptyHooksKey() {
        let onlyOwn: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "python3 agent-island-state.py"]]]]
            ]
        ]
        let stripped = HookSettingsMerger.strippingOwnHooks(from: onlyOwn, isOwnCommand: isOwn)
        #expect(stripped["hooks"] == nil)
    }

    @Test("改名前的旧脚本命令也算本应用的 hook")
    func legacyCommandCountsAsOwn() {
        #expect(HookInstaller.isOwnHookCommand("python3 ~/.claude/hooks/claude-island-state.py"))
        #expect(!HookInstaller.isOwnHookCommand("echo hi"))
    }
}
