import AppKit
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
 private var windowManager: WindowManager?
 private var screenObserver: ScreenObserver?
 private var updateCheckTimer: Timer?

 static var shared: AppDelegate?
 let updater: SPUUpdater
 private let userDriver: NotchUserDriver

 var windowController: NotchWindowController? {
  windowManager?.windowController
 }

 override init() {
  userDriver = NotchUserDriver()
  updater = SPUUpdater(
   hostBundle: Bundle.main,
   applicationBundle: Bundle.main,
   userDriver: userDriver,
   delegate: nil
  )
  super.init()
  AppDelegate.shared = self

  do {
   try updater.start()
  } catch {
   print("Failed to start Sparkle updater: \(error)")
  }
 }

 func applicationDidFinishLaunching(_ notification: Notification) {
  if !ensureSingleInstance() {
   NSApplication.shared.terminate(nil)
   return
  }

  // 偏好域跟着 bundle id 走，改名后要先搬旧域的设置，再读任何配置。
  AppSettings.migrateLegacyDefaultsIfNeeded()

  // 改名遗留的旧 socket 文件：老客户端会继续往一个无人监听的地址发状态，清一次。
  LegacyArtifacts.removeLegacySockets()

  AgentIntegrationInstaller.installIfNeeded()
  NSApplication.shared.setActivationPolicy(.accessory)

  windowManager = WindowManager()
  _ = windowManager?.setupNotchWindow()

  // 用量统计索引：首轮要把历史记录读一遍，跑在后台低优先级任务里，不阻塞界面。
  // 测试宿主里不启动：单测不需要读几个 GB 的历史，也不该污染用户统计库。
  if !isRunningTests {
   Task { await UsageStatsIndexer.shared.start() }
  }

  screenObserver = ScreenObserver { [weak self] in
   self?.handleScreenChange()
  }

  if updater.canCheckForUpdates {
   updater.checkForUpdates()
  }

  updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
   guard let updater = self?.updater, updater.canCheckForUpdates else { return }
   updater.checkForUpdates()
  }
 }

 private func handleScreenChange() {
  _ = windowManager?.setupNotchWindow()
 }

 func applicationWillTerminate(_ notification: Notification) {
  updateCheckTimer?.invalidate()
  screenObserver = nil
  Task { await UsageStatsIndexer.shared.stop() }
 }

 /// 是否运行在单元测试宿主里。
 ///
 /// `xcodebuild test` 会启动一份 App 作为测试宿主，它与用户正在运行的实例 bundle id
 /// 完全一样；单实例守卫一拦，整轮测试就会因为宿主被终止而失败。
 private var isRunningTests: Bool {
  NSClassFromString("XCTestCase") != nil
   || Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
   || Foundation.ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
 }

 private func ensureSingleInstance() -> Bool {
  if isRunningTests { return true }

  let bundleID = Bundle.main.bundleIdentifier ?? "com.celestial.AgentIsland"
  let runningApps = NSWorkspace.shared.runningApplications.filter {
   $0.bundleIdentifier == bundleID
  }

  if runningApps.count > 1 {
   if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
    existingApp.activate()
   }
   return false
  }

  return true
 }
}
