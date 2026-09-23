//
//  ShortcutRecorderTests.swift
//  AgentIslandTests
//
//  录制模式的判定表：取消 / 清空 / 四类拒收 / 接受。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("快捷键录制判定")
struct ShortcutRecorderTests {
    private func outcome(
        keyCode: UInt16 = 40,  // K
        modifiers: KeyChord.Modifier = [.command],
        chord: KeyChord? = nil,
        action: ShortcutAction = .openChat,
        conflict: ShortcutAction? = nil
    ) -> ShortcutRecorder.Outcome {
        ShortcutRecorder.outcome(
            keyCode: keyCode,
            modifiers: modifiers,
            chord: chord ?? KeyChord(keyCode: keyCode, modifiers: modifiers),
            action: action,
            conflict: conflict
        )
    }

    @Test("Esc 一律取消录制，不带任何绑定（带修饰键也算取消）")
    func escapeAlwaysCancels() {
        #expect(outcome(keyCode: 53, modifiers: []) == .cancel)
        #expect(outcome(keyCode: 53, modifiers: [.command]) == .cancel)
    }

    @Test("裸 ⌫ 清空绑定；带修饰键的 ⌫ 是正常组合")
    func bareDeleteUnbindsOnly() {
        #expect(outcome(keyCode: 51, modifiers: []) == .unbind)
        #expect(
            outcome(keyCode: 51, modifiers: [.command])
                == .bind(KeyChord(keyCode: 51, modifiers: [.command])))
    }

    @Test("受支持的键才算组合：不认的键码直接拒收")
    func unsupportedKeyIsRejected() {
        #expect(outcome(keyCode: 122, modifiers: [], chord: nil) == .reject(.unsupportedKey))
    }

    @Test("可打印字符必须带修饰键")
    func printableNeedsModifier() {
        #expect(
            outcome(keyCode: 34, modifiers: [], chord: KeyChord(keyCode: 34))
                == .reject(.needsModifier))
        // 非可打印键（方向键）不受这条限制
        #expect(
            outcome(keyCode: 126, modifiers: [], chord: KeyChord(keyCode: 126))
                == .bind(KeyChord(keyCode: 126)))
    }

    @Test("全局动作必须带 ⌥ 或 ⌃，且这条先于冲突判定")
    func globalRequiresOptionOrControl() {
        // 只有 ⌘：拒收（会把系统复制/粘贴之类抢掉）
        #expect(
            outcome(keyCode: 34, modifiers: [.command], action: .summon)
                == .reject(.globalNeedsOptionOrControl))
        // 有 ⌥：接受
        #expect(
            outcome(keyCode: 34, modifiers: [.option, .command], action: .summon)
                == .bind(KeyChord(keyCode: 34, modifiers: [.option, .command])))
        // 与别的动作冲突时，先报「必须带 ⌥ 或 ⌃」——那条更根本
        #expect(
            outcome(
                keyCode: 34, modifiers: [.command], action: .summon, conflict: .openChat)
                == .reject(.globalNeedsOptionOrControl))
        // 面板内动作不受这条限制
        #expect(
            outcome(keyCode: 34, modifiers: [.command], action: .openChat)
                == .bind(KeyChord(keyCode: 34, modifiers: [.command])))
    }

    @Test("已被占用的组合拒收，并指出是哪个动作")
    func conflictIsRejected() {
        #expect(
            outcome(action: .focusTerminal, conflict: .toggleStatistics)
                == .reject(.conflicting(.toggleStatistics)))
    }

    @Test("其余情况接受，并原样写入组合")
    func acceptsOtherwise() {
        let chord = KeyChord(keyCode: 1, modifiers: [.command, .shift])
        #expect(outcome(keyCode: 1, modifiers: [.command, .shift]) == .bind(chord))
    }
}
