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

  // 这一段全是**真实副作用**（写偏好、写用户的 agent 配置、删旧 socket），因此测试宿主
  // 里整段跳过：`xcodebuild test` 会把测试装进本应用里跑（TEST_HOST 就是它，见
  // `AppEnvironment.isRunningTests`），跑一次单测不该改写用户的 agent 配置，也不该往用户
  // 的偏好域里塞迁移标记。测试要验的都是按临时目录/home 注入的，不依赖这段。
  if !AppEnvironment.isRunningTests {
    // 「本机此前是否跑过本应用」必须在**任何本次写入之前**判定：改名迁移会无条件写下
    // 它自己的标记，拿偏好域当判据会把全新安装判成升级（见 `hadPreviousInstallFootprint`）。
    let hadPreviousInstall = AppSettings.hadPreviousInstallFootprint()

    // 偏好域跟着 bundle id 走，改名后要先搬旧域的设置，再读任何配置。
    AppSettings.migrateLegacyDefaultsIfNeeded()
    // 顺序有讲究：先把改名前的域搬过来，再换算启用口径——否则老用户存在旧域里的
    // 禁用集合还没搬进来，迁移会把它当成「全新安装」而什么都不保留。
    AppSettings.migrateAgentEnablementIfNeeded(hadPreviousInstall: hadPreviousInstall)
    // 旧口径的 Claude 目录（`claudeDirectoryName`）搬进通用覆盖表：不然界面显示
    // 「自动检测」而实际解析到别处。
    AppSettings.migrateClaudeDirectoryOverrideIfNeeded()
    // 旧口径的单账号四键（服务器地址 / Key / 访问令牌 / 用户 ID）搬进账号列表。
    AppSettings.migrateNewAPIAccountsIfNeeded()

    // 改名遗留的旧 socket 文件：老客户端会继续往一个无人监听的地址发状态，清一次。
    LegacyArtifacts.removeLegacySockets()

    AgentIntegrationInstaller.installIfNeeded()
  }
  NSApplication.shared.setActivationPolicy(.accessory)

  // 快捷键：装本地监视、注册全局热键（内部自带「测试宿主不装」守卫）。
  ShortcutController.shared.start()

  windowManager = WindowManager()
  _ = windowManager?.setupNotchWindow()

  // 用量统计索引：首轮要把历史记录读一遍，跑在后台低优先级任务里，不阻塞界面。
  // 测试宿主里不启动：单测不需要读几个 GB 的历史，也不该污染用户统计库。
  if !AppEnvironment.isRunningTests {
   Task { await UsageStatsIndexer.shared.start() }
  }

  screenObserver = ScreenObserver { [weak self] in
   self?.handleScreenChange()
  }

  // 「自动检查更新」是**总开关**：它同时管住 Sparkle 自己的后台调度、启动时的这一次
  // 检查与下面这个自建定时器。曾漏掉后两者，关掉开关的用户仍会每小时收到一次检查。
  if updater.canCheckForUpdates, updater.automaticallyChecksForUpdates {
   updater.checkForUpdates()
  }

  updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
   guard let updater = self?.updater,
    updater.canCheckForUpdates,
    updater.automaticallyChecksForUpdates
   else { return }
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

 private func ensureSingleInstance() -> Bool {
  // 判定见 `AppEnvironment.isRunningTests`：`xcodebuild test` 的宿主与用户实例
  // bundle id 相同，这里必须放行，否则整轮测试会因宿主被终止而失败。
  if AppEnvironment.isRunningTests { return true }

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
