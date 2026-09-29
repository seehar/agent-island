//
//  NotchOpenPolicyTests.swift
//  AgentIslandTests
//
//  两条「反过来就是体验事故」的展开策略，都抽成了纯逻辑因此可以在这里钉住：
//   * 展开时抢不抢键盘焦点 —— 悬停展开（默认 1s，鼠标只是路过）抢焦点，用户在编辑器里
//     正在打的字会丢进面板（面板里当时没有聚焦的输入框，字直接没了）；
//   * 启动那次展开留不留下 —— 反过来（老用户每次启动都停在展开态）就是面板白挡屏幕顶部。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("展开策略：键盘焦点与首次引导")
struct NotchOpenPolicyTests {
  @MainActor
  private func makeModel() -> NotchViewModel {
    NotchViewModel(
      deviceNotchRect: CGRect(x: 0, y: 0, width: 300, height: 32),
      screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowHeight: 750,
      hasPhysicalNotch: false
    )
  }

  @Test("只有用户主动唤出（点击 / 热键）才抢键盘焦点")
  @MainActor
  func keyboardFocusOnlyForDeliberateOpens() {
    let model = makeModel()

    // 鼠标只是路过、或应用自己启动/通知触发的展开：一律不抢焦点。
    model.notchOpen(reason: .hover)
    #expect(model.takesKeyboardFocusOnOpen == false)

    model.notchOpen(reason: .boot)
    #expect(model.takesKeyboardFocusOnOpen == false)

    model.notchOpen(reason: .notification)
    #expect(model.takesKeyboardFocusOnOpen == false)

    model.notchOpen(reason: .unknown)
    #expect(model.takesKeyboardFocusOnOpen == false)

    // 用户点了胶囊、或按了全局热键：这才是「我要用面板」，可以抢。
    model.notchOpen(reason: .click)
    #expect(model.takesKeyboardFocusOnOpen)

    model.notchOpen(reason: .hotkey)
    #expect(model.takesKeyboardFocusOnOpen)
  }

  @Test("通知触发的展开不再把正在读的对话丢掉")
  @MainActor
  func notificationOpenKeepsCurrentChat() {
    let model = makeModel()
    let session = SessionState(agent: .claudeCode, sessionId: "chat-keep", cwd: "/tmp")

    // 用户点开某个对话 → 收起（收起时记住这个对话）。
    model.contentType = .chat(session)
    model.notchClose()

    // 来一条待批自动展开：这一次应当显示会话列表，但**不能**把记住的对话抹掉。
    model.notchOpen(reason: .notification)
    #expect(model.contentType == .instances)
    model.notchClose()

    // 再点开面板：回到原来那个对话（旧实现这里已经退回会话列表了）。
    model.notchOpen(reason: .click)
    #expect(model.contentType == .chat(session))
  }

  @Test("启动展开只在「首次引导 + 一个 Agent 都没启用」时留着不收起")
  func bootPanelStaysOpenOnlyForFreshInstall() {
    #expect(
      NotchViewModel.shouldKeepBootPanelOpen(firstRunIntroPending: true, enabledAgentCount: 0))
    // 引导走完了：恢复原来的 1 秒动画。
    #expect(
      NotchViewModel.shouldKeepBootPanelOpen(firstRunIntroPending: false, enabledAgentCount: 0)
        == false)
    // 已经启用过 Agent 的安装：不进首次引导（老用户升级后不该被面板挡住）。
    #expect(
      NotchViewModel.shouldKeepBootPanelOpen(firstRunIntroPending: true, enabledAgentCount: 2)
        == false)
  }
}
