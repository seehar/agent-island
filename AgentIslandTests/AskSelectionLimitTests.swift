//
//  AskSelectionLimitTests.swift
//  AgentIslandTests
//
//  作答自由文本的长度上限：作答要经 socket 回写、再由各集成翻译成 `updatedInput`，
//  过长的答案没有可靠通道（历史坑：脚本端单次 `recv(4096)` 会把长答案截成半条 JSON，
//  对端解析失败 → 静默回落到原生弹窗，用户敲的字白输）。上限在**入口**截断，
//  界面同时显示提示，所以这里钉住两件事：截断发生、且判据与截断阈值同源。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("作答自由文本的长度上限")
struct AskSelectionLimitTests {
  @Test("未到上限时原样保留")
  func keepsTextBelowLimit() {
    var selection = AskSelection()
    let text = String(repeating: "a", count: AskSelection.freeTextLimit - 1)

    selection.setFreeText(text, for: "q1")

    #expect(selection.freeText(for: "q1") == text)
    #expect(selection.reachedFreeTextLimit(for: "q1") == false)
  }

  @Test("超过上限时截断，并标记「已顶到上限」")
  func truncatesTextAboveLimit() {
    var selection = AskSelection()
    let text = String(repeating: "a", count: AskSelection.freeTextLimit + 500)

    selection.setFreeText(text, for: "q1")

    #expect(selection.freeText(for: "q1").count == AskSelection.freeTextLimit)
    #expect(selection.reachedFreeTextLimit(for: "q1"))
  }

  @Test("上限本身是「已顶到」：正好等于上限时就要提示")
  func flagsExactLimit() {
    var selection = AskSelection()

    selection.setFreeText(String(repeating: "a", count: AskSelection.freeTextLimit), for: "q1")

    #expect(selection.reachedFreeTextLimit(for: "q1"))
  }
}
