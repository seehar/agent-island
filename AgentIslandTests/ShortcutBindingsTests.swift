//
//  ShortcutBindingsTests.swift
//  AgentIslandTests
//
//  绑定表的持久化、清空、恢复默认与冲突判定。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("快捷键绑定表")
@MainActor
struct ShortcutBindingsTests {
    /// 每个用例一个独立偏好域：互不污染，也不需要清理。
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "shortcut-tests-\(UUID().uuidString)")!
    }

    @Test("全新域：每个动作都拿到默认组合，没有未绑定项")
    func freshDomainUsesDefaults() {
        let bindings = ShortcutBindings(defaults: makeDefaults())
        for action in ShortcutAction.allCases {
            #expect(
                bindings.chord(for: action) == action.defaultChord, "\(action.rawValue) 未取到默认组合")
        }
        #expect(bindings.bindings.count == ShortcutAction.allCases.count)
    }

    @Test("写盘往返：set 之后新实例读出同一个组合")
    func setRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        let chord = KeyChord(keyCode: 8, modifiers: [.control, .option, .command])
        ShortcutBindings(defaults: defaults).set(chord, for: .summon)

        let reloaded = ShortcutBindings(defaults: defaults)
        #expect(reloaded.chord(for: .summon) == chord)
        // 只改这一个动作，其余仍是默认。
        #expect(reloaded.chord(for: .dismiss) == ShortcutAction.dismiss.defaultChord)
    }

    @Test("清空：未绑定不会被默认值覆盖，恢复默认后回到默认")
    func clearThenResetReturnsToDefaults() {
        let defaults = makeDefaults()
        let bindings = ShortcutBindings(defaults: defaults)
        bindings.clear(.openChat)

        #expect(bindings.chord(for: .openChat) == nil)
        #expect(
            ShortcutBindings(defaults: defaults).chord(for: .openChat) == nil, "清空要落盘，不能被默认值覆盖")

        ShortcutBindings(defaults: defaults).resetToDefaults()
        #expect(
            ShortcutBindings(defaults: defaults).chord(for: .openChat)
                == ShortcutAction.openChat.defaultChord)
    }

    @Test("清空全局动作：组合消失且不再参与冲突判定")
    func clearingGlobalActionSuppressesChordAndConflict() {
        let defaults = makeDefaults()
        let bindings = ShortcutBindings(defaults: defaults)

        // 先把它挪到一个与「打开对话」冲突的组合上，确认冲突确实存在
        bindings.set(ShortcutAction.openChat.defaultChord, for: .summon)
        #expect(
            bindings.conflict(for: ShortcutAction.openChat.defaultChord, excluding: .openChat)
                == .summon)

        bindings.clear(.summon)
        #expect(bindings.chord(for: .summon) == nil)
        // 未绑定 = 彻底不生效：冲突判定里也不该再出现它
        #expect(
            bindings.conflict(for: ShortcutAction.openChat.defaultChord, excluding: .openChat)
                == nil)
        // 也不会回落到默认组合
        #expect(ShortcutBindings(defaults: defaults).chord(for: .summon) == nil)
    }

    @Test("清空后重新录制：能再次拿到组合")
    func rebindingAfterClearWorks() {
        let defaults = makeDefaults()
        let bindings = ShortcutBindings(defaults: defaults)
        bindings.clear(.dismiss)
        #expect(bindings.chord(for: .dismiss) == nil)

        let chord = KeyChord(keyCode: 8, modifiers: [.option, .command])
        bindings.set(chord, for: .dismiss)
        #expect(ShortcutBindings(defaults: defaults).chord(for: .dismiss) == chord)
    }

    @Test("写坏的值与未知键回落到默认组合")
    func corruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: ShortcutBindings.keyPrefix + "summon")

        let bindings = ShortcutBindings(defaults: defaults)
        #expect(bindings.chord(for: .summon) == ShortcutAction.summon.defaultChord)
    }

    @Test("冲突判定：同键且生效页面相交才算冲突")
    func conflictRules() {
        let bindings = ShortcutBindings(defaults: makeDefaults())

        // 同键 + 页面相交（两者都在列表页生效）
        bindings.set(ShortcutAction.openChat.defaultChord, for: .moveSelectionUp)
        #expect(
            bindings.conflict(
                for: ShortcutAction.openChat.defaultChord, excluding: .moveSelectionUp)
                == .openChat)

        // 同键但页面不相交：重新统计只在统计页、打开对话只在列表页，可以共存
        bindings.set(ShortcutAction.openChat.defaultChord, for: .rescan)
        #expect(
            bindings.conflict(for: ShortcutAction.openChat.defaultChord, excluding: .rescan) == nil)

        // 不同键：没有冲突
        #expect(
            bindings.conflict(
                for: KeyChord(keyCode: 8, modifiers: [.command]), excluding: .rescan) == nil)
    }

    @Test("冲突判定：全局动作与面板内动作抢同一个组合也算冲突")
    func globalActionConflictsAcrossPages() {
        let bindings = ShortcutBindings(defaults: makeDefaults())
        bindings.set(ShortcutAction.dismiss.defaultChord, for: .summon)

        #expect(
            bindings.conflict(for: ShortcutAction.dismiss.defaultChord, excluding: .summon)
                == .dismiss)
    }
}
