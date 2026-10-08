//
//  SettingsValueFieldTests.swift
//  AgentIslandTests
//
//  微调行输入框的文本归一（纯函数）：只收 ASCII 数字、最多 4 位；空串没有数值，
//  调用方保持原值不动。这几条决定了「键入 → 夹紧 → 落盘」这条链路的入口长什么样。
//

import CoreGraphics
import Testing

@testable import AgentIsland

@MainActor
@Suite("微调行的数值输入")
struct SettingsValueFieldTests {
    @Test("只留 ASCII 数字，最多 4 位")
    func digitsOnlyStripsEverythingElse() {
        #expect(SettingsStepperRow.digitsOnly("224") == "224")
        // 粘贴带单位的文本（行内显示的就是 `224 pt`）
        #expect(SettingsStepperRow.digitsOnly("224 pt") == "224")
        #expect(SettingsStepperRow.digitsOnly("1 2 3") == "123")
        #expect(SettingsStepperRow.digitsOnly("abc") == "")
        // 4 位是范围上限（520）的自然界
        #expect(SettingsStepperRow.digitsOnly("12345") == "1234")
        // 阿拉伯-印度数字等形态 `Int(_:)` 解析不了，不能当数字放行
        #expect(SettingsStepperRow.digitsOnly("١٢٣") == "")
    }

    @Test("空串（或没有数字）没有数值")
    func emptyTextHasNoValue() {
        #expect(SettingsStepperRow.value(fromDigits: "") == nil)
        #expect(SettingsStepperRow.value(fromDigits: "pt") == nil)
        #expect(SettingsStepperRow.value(fromDigits: "0") == 0)
        #expect(SettingsStepperRow.value(fromDigits: "224 pt") == 224)
    }

    @Test("生效值写回文本：取整显示")
    func digitsFromValueRounds() {
        #expect(SettingsStepperRow.digits(from: 224) == "224")
        #expect(SettingsStepperRow.digits(from: 223.6) == "224")
    }
}
