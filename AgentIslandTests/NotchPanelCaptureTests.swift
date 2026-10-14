//
//  NotchPanelCaptureTests.swift
//  AgentIslandTests
//
//  面板对系统截取的可见性：面板必须标记为不可捕获 —— 投屏 / 录屏 / 截屏（复合截图、
//  逐窗口截图、ScreenCaptureKit）都不该把它画进去。真实截取路径只能整机实测（本机
//  2026-10-14 实测：sharingType = .none 的窗口在四条截取路径里全部不可见），这里在
//  属性层面钉住，防止这条不变量被静默改掉。
//

import AppKit
import Testing

@testable import AgentIsland

@Suite("面板的截取可见性")
struct NotchPanelCaptureTests {
  @Test("刘海面板标记为不可捕获（sharingType == .none）")
  @MainActor
  func panelIsNotShareable() {
    let panel = NotchPanel(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [], backing: .buffered,
      defer: false)
    #expect(panel.sharingType == .none)
  }
}
