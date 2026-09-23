//
//  KeyChordTests.swift
//  AgentIslandTests
//
//  按键组合的展示字形、修饰键归一、可录制性与存储形态。
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import AgentIsland

@Suite("按键组合")
struct KeyChordTests {
    @Test("展示串：修饰键按 ⌃⌥⇧⌘ 排序，主键取字形")
    func displayLabels() {
        #expect(ShortcutAction.summon.defaultChord.displayLabel == "⌥⌘I")
        #expect(ShortcutAction.dismiss.defaultChord.displayLabel == "⎋")
        #expect(ShortcutAction.toggleStatistics.defaultChord.displayLabel == "⇧⌘S")
        #expect(ShortcutAction.openSettings.defaultChord.displayLabel == "⌘,")
        #expect(ShortcutAction.deny.defaultChord.displayLabel == "⌘⌫")
        #expect(ShortcutAction.openChat.defaultChord.displayLabel == "↩")
        #expect(ShortcutAction.focusTerminal.defaultChord.displayLabel == "⇧↩")
        #expect(ShortcutAction.moveSelectionUp.defaultChord.displayLabel == "↑")
        #expect(
            KeyChord(keyCode: 36, modifiers: [.control, .option, .shift, .command]).displayLabel
                == "⌃⌥⇧⌘↩")
    }

    @Test("修饰键归一：capsLock / fn 不参与匹配")
    func modifierNormalization() {
        #expect(
            KeyChord.Modifier(NSEvent.ModifierFlags([.command, .capsLock]))
                == KeyChord.Modifier([.command]))
        #expect(
            KeyChord.Modifier(NSEvent.ModifierFlags([.command, .option, .function]))
                == KeyChord.Modifier([.command, .option]))
        #expect(KeyChord.Modifier([.control, .shift]).displayPrefix == "⌃⇧")
    }

    @Test("从事件取组合：只认受支持的键码")
    func chordFromEvent() throws {
        try #expect(
            KeyChord.from(makeKeyEvent(keyCode: 34, modifiers: [.option, .command]))
                == KeyChord(keyCode: 34, modifiers: [.option, .command]))
        try #expect(KeyChord.from(makeKeyEvent(keyCode: 122, modifiers: [])) == nil)  // F1
        try #expect(KeyChord.from(makeKeyEvent(keyCode: 107, modifiers: [])) == nil)  // F14
    }

    @Test("可录制性：可打印字符必须带修饰键，非可打印键不受限")
    func recordability() {
        #expect(KeyChord(keyCode: 34).isRecordable == false)
        #expect(KeyChord(keyCode: 34, modifiers: [.command]).isRecordable)
        #expect(KeyChord(keyCode: 29).isRecordable == false)
        #expect(KeyChord(keyCode: 126).isRecordable)
        #expect(KeyChord(keyCode: 53).isRecordable)
    }

    @Test("Carbon 修饰键位与 Carbon 常量一致")
    func carbonFlags() {
        #expect(KeyChord.Modifier([.command]).carbonFlags == UInt32(cmdKey))
        #expect(KeyChord.Modifier([.shift]).carbonFlags == UInt32(shiftKey))
        #expect(KeyChord.Modifier([.option]).carbonFlags == UInt32(optionKey))
        #expect(KeyChord.Modifier([.control]).carbonFlags == UInt32(controlKey))
        #expect(
            KeyChord.Modifier([.command, .option]).carbonFlags == UInt32(cmdKey) | UInt32(optionKey)
        )
        #expect(KeyChord.Modifier([]).carbonFlags == 0)
    }

    @Test("存储形态：修饰键写成裸整数，往返相等")
    func codableRoundTrip() throws {
        let chord = KeyChord(keyCode: 34, modifiers: [.option, .command])
        let data = try JSONEncoder().encode(chord)
        #expect(String(decoding: data, as: UTF8.self).contains("\"modifiers\":3"))
        #expect(try JSONDecoder().decode(KeyChord.self, from: data) == chord)
    }

    // MARK: - 夹具

    private func makeKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ))
    }
}
