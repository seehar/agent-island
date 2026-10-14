//
//  NotchPanelCaptureTests.swift
//  AgentIslandTests
//
//  面板对系统截取的可见性：默认标记为不可捕获——投屏 / 录屏 / 截屏都不该把它画进去；
//  偏好 `showWhileCasting`（设置 → 通用 → 投屏时显示）打开后按普通窗口参与捕获。
//
//  真实截取路径只能整机实测：本机 2026-10-14 实测 screencapture / ScreenCaptureKit /
//  旧版 CGWindowListCreateImage / CGDisplayCreateImage 四条路径在 `.none` 下都拍不到面板
//  （逐窗口截图取回全透明图、`screencapture -l` 直接失败）。
//
//  **测试环境边界**：xctest 宿主进程里 WindowServer 拒绝 `.none → .readOnly` 的升级
//  （连裸 NSPanel 都拒绝；降级不受影响），而正常启动的应用里同一操作成功且可重复
//  （整机实测过两次往复）——升级方向因此只由实机验收覆盖。这里钉住：偏好 → 共享类型的
//  映射、面板初始化的两个方向、以及降级重应用（窗口控制器实时订阅调用的同一条路径）。
//

import AppKit
import Testing

@testable import AgentIsland

@Suite("面板的截取可见性", .serialized)
struct NotchPanelCaptureTests {
  /// 共享偏好按「用户真实档位」读写：用例自己建立前置、结束前把原值与键的存在性都放回去。
  @MainActor
  private func withPreferenceValue(_ value: Bool, _ body: () -> Void) {
    let preference = CastVisibilityPreferences.showWhileCasting
    let previous = UserDefaults.standard.object(forKey: preference.key)
    defer {
      preference.set(previous as? Bool ?? preference.defaultValue)
      if let previous {
        UserDefaults.standard.set(previous, forKey: preference.key)
      } else {
        UserDefaults.standard.removeObject(forKey: preference.key)
      }
    }
    preference.set(value)
    body()
  }

  /// 面板 + 偏好复位。
  @MainActor
  private func withPreference(_ value: Bool, _ body: (NotchPanel) -> Void) {
    withPreferenceValue(value) {
      let panel = NotchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [], backing: .buffered,
        defer: false)
      body(panel)
    }
  }

  @Test("偏好 → 共享类型的映射：关闭 = 不可捕获，打开 = 可捕获")
  @MainActor
  func preferenceMapsToSharingType() {
    withPreferenceValue(false) {
      #expect(NotchPanel.preferredSharingType == .none)
    }
    withPreferenceValue(true) {
      #expect(NotchPanel.preferredSharingType == .readOnly)
    }
  }

  @Test("默认（投屏时显示关闭）：面板标记为不可捕获")
  @MainActor
  func panelIsNotShareableByDefault() {
    withPreference(false) { panel in
      #expect(panel.sharingType == .none)
    }
  }

  @Test("打开「投屏时显示」：面板按普通窗口参与捕获")
  @MainActor
  func panelIsShareableWhenPreferenceIsOn() {
    withPreference(true) { panel in
      #expect(panel.sharingType == .readOnly)
    }
  }

  @Test("开关关掉后重应用：面板回到不可捕获（窗口控制器实时订阅调用的同一条路径）")
  @MainActor
  func reapplyingPreferenceDowngradesSharingType() {
    withPreference(true) { panel in
      #expect(panel.sharingType == .readOnly)
      CastVisibilityPreferences.showWhileCasting.set(false)
      panel.applyCastVisibilityPreference()
      #expect(panel.sharingType == .none)
    }
  }
}
