//
//  AgentIntegrationInstaller.swift
//  AgentIsland
//
//  为各 Agent 安装「实时事件上报」集成：
//    - Claude Code：hook 脚本 + settings.json（由 `HookInstaller` 负责）
//    - pi / Oh My Pi：`<agent 目录>/extensions/agent-island-state.ts`
//    - OpenCode：`~/.config/opencode/plugins/agent-island-state.js`
//    - 其余「配置文件型 hook」的工具（Codex / Gemini / Cursor / Copilot / Qoder /
//      Factory / CodeBuddy / Kimi / Cline / Grok / Trae / Trae CLI）：把同一份 hook
//      脚本装到 `~/.agent-island/hooks/`，并按各自的配置结构写条目
//      （由 `AgentConfigInstaller` 负责，描述表见 `AgentHooks.swift`）
//
//  未安装集成的 Agent 仍可使用，只是状态由记录文件推断、且拿不到 pid/tty。
//

import Foundation
import os.log

nonisolated enum AgentIntegrationInstaller {
  private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Integration")

  /// pi 系扩展文件名（同一份源码安装到 omp 与 pi 各自的目录）。
  static let piFamilyExtensionName = "agent-island-state.ts"

  /// 扩展源码在应用 bundle 里的资源名与扩展名。
  /// 注意：`.ts` 会被 Xcode 判为源码类型而不进 Resources，因此随包资源用 `.ts.txt`，
  /// 安装时再写成目标文件名 `agent-island-state.ts`。
  private static let piFamilyExtensionResourceExtension = "ts.txt"

  /// OpenCode 插件里声明的版本标记（与 pi 系扩展同一套做法，插件资源由 P2 维护）。
  private static let openCodeVersionMarkerPrefix = "// agent-island-opencode-plugin-version:"

  /// 当前应用期望的 OpenCode 插件版本：改插件时必须同步 +1。
  /// 3 = 新增交互提问（`question`）的远程作答。
  static let openCodePluginVersion = 3

  /// 6 = 闸门不可用（含「该 Agent 已被关闭」）改走降级档，而不是把服务端关闭读成拒绝。
  /// 当前应用期望的扩展版本戳：改 pi/omp 扩展时必须同步 +1。
  /// `isInstalled` 按它比对（不再只看「文件在不在」），用户手改过或升级未重写都能被发现。
  static let piFamilyExtensionVersion = 6

  /// 扩展源码里声明版本 / 变体 / 降级档的三行注释标记。
  private static let versionMarkerPrefix = "// agent-island-extension-version:"
  private static let kindMarkerPrefix = "// agent-island-extension-kind:"
  private static let degradationMarkerPrefix = "// agent-island-extension-degradation:"
  private static let askScopeMarkerPrefix = "// agent-island-extension-ask-scope:"

  /// 占位符前缀：安装后不该再出现（渲染漏了就拒绝安装）。
  private static let placeholderPrefix = "__AGENT_ISLAND_"

  /// 客户端等刘海的时限（与扩展内的缺省一致；写进文件是为了让策略在文件里可见）。
  static let gateApprovalTimeoutMs = 120_000

  /// 安装时替换的占位符：Agent 名、闸门策略 JSON、降级档名。
  private static let agentToken = "__AGENT_ISLAND_AGENT__"
  private static let gateConfigToken = "__AGENT_ISLAND_GATE_CONFIG__"
  private static let degradationToken = "__AGENT_ISLAND_DEGRADATION__"
  private static let askScopeToken = "__AGENT_ISLAND_ASK_SCOPE__"
  private static let versionToken = "__AGENT_ISLAND_VERSION__"
  /// OpenCode 插件文件名。
  static let openCodePluginName = "agent-island-state.js"

  /// pi 系扩展的两个变体：闸门版（阻塞等刘海决定）与只上报版（关闭闸门/降级时用）。
  enum Variant: String {
    /// 阻塞闸门：`tool_call` 里等刘海决策，`{block:true}` 拦下被拒的工具。
    case gate
    /// 只上报：与旧版行为一致，审批仍在终端完成。
    case reportOnly = "report-only"

    /// 随包资源名（`.ts.txt`）。
    var resourceName: String {
      switch self {
      case .gate: return "agent-island-pi-extension"
      case .reportOnly: return "agent-island-pi-extension-report-only"
      }
    }
  }

  /// 该 Agent 的集成是否支持「刘海审批闸门」（能把决定回传给 agent）。
  /// 目前只有 omp / pi 的扩展提供这条通道；Claude Code 走 hook 自己的审批通道，
  /// 因此不在这里。
  static func supportsApprovalGate(_ kind: AgentKind) -> Bool {
    switch kind {
    case .ohMyPi, .pi: return true
    case .claudeCode, .opencode: return false
    // hook 脚本型 Agent 的审批不需要闸门档位：脚本等刘海决定，应用不在时连不上
    // socket 就直接不输出，工具自己弹原生审批——降级是天然行为，无需烘焙策略。
    default: return false
    }
  }

  /// 是否有任何一个 Agent 开着「刘海审批闸门」：闸门的两个全局档位（问什么、
  /// 应用未运行时）没有开着的闸门时没有意义，设置页据此整行禁用。
  ///
  /// 必须同时要求「该 Agent 已被启用」：Agent 默认关闭，「全部关闭并卸载」之后
  /// 闸门标志还留着（那是有意的，重新启用时会用回原档位），但此时没有任何闸门在
  /// 工作，档位行不该还是可用的。
  static var hasEnabledGate: Bool {
    AgentKind.allCases.contains {
      supportsApprovalGate($0) && AppSettings.isApprovalGateEnabled($0)
        && AppSettings.isAgentEnabled($0)
    }
  }

  /// 重装**已开启闸门且仍在监控**的 Agent 的扩展。档位值烘焙在扩展文件里，
  /// 换档必须重装才会生效。
  ///
  /// 必须带上 `isAgentEnabled`：关闭某个 Agent 会卸掉它的集成，但不清闸门标志
  /// （见 `AgentSettingsSection.toggle`）。少了这一条，关掉 Agent 之后再改闸门档位
  /// 会把扩展写回它的目录，和「关掉即卸载」这条不变量冲突。
  static func reinstallGateExtensions() {
    for kind in AgentKind.allCases
    where supportsApprovalGate(kind) && AppSettings.isApprovalGateEnabled(kind)
      && AppSettings.isAgentEnabled(kind)
    {
      install(kind)
    }
  }

  /// 该集成是否带版本戳：pi 系扩展与 OpenCode 插件都有；Claude 的 hook 脚本没有。
  static func hasVersionedIntegration(_ kind: AgentKind) -> Bool {
    switch kind {
    case .ohMyPi, .pi, .opencode: return true
    // Claude 的 hook 脚本与配置文件型 hook 都没有版本戳：脚本按内容比对升级，
    // 配置条目的存在性就是安装状态。
    case .claudeCode: return false
    default: return false
    }
  }

  /// 该 Agent 当前应安装哪个变体：开关关闭（或该 Agent 不支持闸门）时用只上报版。
  static func piFamilyExtensionVariant(_ kind: AgentKind) -> Variant {
    guard supportsApprovalGate(kind), AppSettings.isApprovalGateEnabled(kind) else {
      return .reportOnly
    }
    return .gate
  }

  /// 改名前的 pi 系扩展文件名：Agent 会加载目录里所有扩展，旧文件不清掉等于旧脚本
  /// 继续上报到废弃的 socket。装与卸都顺手清。
  static let legacyPiFamilyExtensionNames = ["claude-island-state.ts"]

  /// 改名前的 OpenCode 插件文件名（同上）。
  static let legacyOpenCodePluginNames = ["claude-island-state.js"]

  // MARK: - 批量安装

  /// 启动时为所有已启用的 Agent 安装集成。
  static func installIfNeeded() {
    // 所有随包提供集成的 Agent 都尝试安装：OpenCode 没有集成也能靠数据库轮询工作，
    // 但插件能带来实时事件，因此同样默认安装（安装失败不影响其可用性）。
    for kind in AgentRegistry.enabled
    where AgentRegistry.provider(for: kind).integrationStatus() != nil {
      let installed = install(kind)
      // 依赖集成的 Agent 装不上要留下痕迹：界面上那一行会显示「未安装」，
      // 但只有日志能说明为什么（资源缺失、目录不可写、配置不可安全改写）。
      if !installed, kind.requiresIntegrationInstall {
        logger.error("启动时安装 \(kind.rawValue, privacy: .public) 的集成失败")
      }
    }
  }

  // MARK: - 单个 Agent

  /// 安装某个 Agent 的集成；返回是否安装成功。
  @discardableResult
  static func install(_ kind: AgentKind) -> Bool {
    // 工具没装就什么都不做：Claude / omp / pi 的 Provider 不做存在性检查（扩展/脚本型），
    // 少了这道闸门就会给没装它们的用户凭空造出 `~/.omp/agent/extensions/` 这类目录。
    // 「跳过」与配置文件型 Agent 的存在性闸门同口径——不算失败（返回 true），
    // 界面上的状态由 `integrationStatus()` 表达（未安装/不可用）。
    guard AgentRegistry.provider(for: kind).isToolInstalled else { return true }

    switch kind {
    case .claudeCode:
      HookInstaller.installIfNeeded()
      return HookInstaller.isInstalled()
    case .ohMyPi, .pi:
      return installPiFamilyExtension(kind)
    case .opencode:
      return installOpenCodePlugin()
    default:
      // 配置文件型 hook：没有描述表（DSH）就没什么可装。
      guard kind.hookSpec != nil else { return false }
      // 脚本先落地再改配置：配置指向不存在的脚本时，工具会在每个事件上跑一次
      // 注定失败的命令。
      guard AgentConfigInstaller.installHookScript() else { return false }
      return AgentConfigInstaller.install(kind)
    }
  }

  /// 卸载某个 Agent 的集成（含改名遗留的旧文件）。
  static func uninstall(_ kind: AgentKind) {
    switch kind {
    case .claudeCode:
      HookInstaller.uninstall()
    case .ohMyPi, .pi:
      if let file = piFamilyExtensionFile(kind) {
        removeFile(file, label: "pi 扩展")
        removeLegacyFiles(
          in: file.deletingLastPathComponent(), names: Self.legacyPiFamilyExtensionNames)
      }
    case .opencode:
      if let file = openCodePluginFile() {
        removeFile(file, label: "OpenCode 插件")
        removeLegacyFiles(in: file.deletingLastPathComponent(), names: Self.legacyOpenCodePluginNames)
      }
    default:
      // 只摘掉这个 Agent 的条目；共享脚本保留（其它工具还引用它）。
      guard kind.hookSpec != nil else { return }
      AgentConfigInstaller.uninstall(kind)
    }
  }

  /// 是否已安装。
  ///
  /// pi 系不止看「文件在不在」，还要看版本戳与变体是否匹配当前设置——用户手改过扩展、
  /// 应用降级、或写入被 `catch` 吞掉时，界面不能继续显示「已安装」。
  static func isInstalled(_ kind: AgentKind) -> Bool {
    switch kind {
    case .claudeCode:
      return HookInstaller.isInstalled()
    case .ohMyPi, .pi:
      return isPiFamilyExtensionCurrent(kind)
    case .opencode:
      return isOpenCodePluginCurrent()
    default:
      guard kind.hookSpec != nil else { return false }
      return AgentConfigInstaller.isInstalled(kind)
    }
  }

  /// 磁盘上的 OpenCode 插件是不是「当前该装的那一份」。
  ///
  /// 只比版本戳：插件是**单一份**（没有闸门版 / 只上报版两态），也没有把闸门策略烘焙进文件
  /// （它的降级语义由插件自持），因此变体与降级档都不参与比对——多比只会把「不该重装的」
  /// 判成「需重装」。
  static func isOpenCodePluginCurrent() -> Bool {
    guard let file = openCodePluginFile(),
      let contents = try? String(contentsOf: file, encoding: .utf8)
    else {
      return false
    }
    return markerValue(in: contents, prefix: openCodeVersionMarkerPrefix)
      == String(openCodePluginVersion)
  }

  /// 磁盘上的扩展是不是「当前该装的那一份」：版本戳、变体、以及闸门版的降级档都要对上。
  static func isPiFamilyExtensionCurrent(_ kind: AgentKind) -> Bool {
    guard let file = piFamilyExtensionFile(kind),
      let contents = try? String(contentsOf: file, encoding: .utf8)
    else {
      return false
    }
    let variant = piFamilyExtensionVariant(kind)
    guard markerValue(in: contents, prefix: versionMarkerPrefix) == String(piFamilyExtensionVersion),
      markerValue(in: contents, prefix: kindMarkerPrefix) == variant.rawValue
    else {
      return false
    }
    if variant == .gate,
      markerValue(in: contents, prefix: degradationMarkerPrefix) != AppSettings.approvalDegradation.rawValue
    {
      return false
    }
    // 适用范围同理：换档位等于换文件，界面不能继续显示「已安装」。
    if variant == .gate,
      markerValue(in: contents, prefix: askScopeMarkerPrefix)
        != AppSettings.approvalAskScope.rawValue
    {
      return false
    }
    return true
  }

  /// 读扩展文件头里的一行标记值（形如 `// agent-island-extension-version: 2`）。
  private static func markerValue(in contents: String, prefix: String) -> String? {
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false)
    where line.hasPrefix(prefix) {
      return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  // MARK: - pi 系

  /// pi/omp 扩展的目标路径。
  static func piFamilyExtensionFile(_ kind: AgentKind) -> URL? {
    guard let paths = AgentRegistry.provider(for: kind).paths() else { return nil }
    return paths.configDir
      .appendingPathComponent("extensions")
      .appendingPathComponent(piFamilyExtensionName)
  }

  private static func installPiFamilyExtension(_ kind: AgentKind) -> Bool {
    guard let destination = piFamilyExtensionFile(kind) else { return false }
    let variant = piFamilyExtensionVariant(kind)
    guard
      let source = Bundle.main.url(
        forResource: variant.resourceName,
        withExtension: piFamilyExtensionResourceExtension
      ),
      let contents = try? String(contentsOf: source, encoding: .utf8)
    else {
      logger.error(
        "缺少内置的 pi 扩展资源（\(variant.rawValue, privacy: .public)），无法为 \(kind.rawValue, privacy: .public) 安装集成"
      )
      return false
    }

    let rendered = renderPiFamilyExtension(contents, kind: kind, variant: variant)
    guard !rendered.contains(placeholderPrefix) else {
      // 占位符没替换完的扩展写出去就是坏脚本：宁可报告失败也不要静默装一个坏文件。
      logger.error("pi 扩展资源里有未替换的占位符，拒绝安装")
      return false
    }
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try rendered.write(to: destination, atomically: true, encoding: .utf8)
      // 装新的同时清旧的：旧文件不删会被 Agent 一起加载，等于双份上报
      removeLegacyFiles(
        in: destination.deletingLastPathComponent(), names: Self.legacyPiFamilyExtensionNames)
      return true
    } catch {
      logger.error("写入 pi 扩展失败：\(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  /// 把随包资源渲染成可安装的扩展：替换 Agent 名；闸门版再把降级档、适用范围与策略常量注入。
  ///
  /// 策略写进文件而不是运行时下发：扩展在 `tool_call` 里需要立刻知道降级档与适用范围，而
  /// 此时未必还能跟应用通话（应用不在正是降级档的适用场景）。
  private static func renderPiFamilyExtension(
    _ contents: String,
    kind: AgentKind,
    variant: Variant
  ) -> String {
    var rendered = contents.replacingOccurrences(of: agentToken, with: kind.rawValue)
    // 版本号由这里写入：模板里的版本标记与 `EXTENSION_VERSION` 都用同一个占位符，
    // 版本因此只有一个来源（`piFamilyExtensionVersion`）——两个变体、两处写法都不会漂。
    rendered = rendered.replacingOccurrences(
      of: versionToken, with: String(piFamilyExtensionVersion))
    guard variant == .gate else { return rendered }
    let degradation = AppSettings.approvalDegradation.rawValue
    let askScope = AppSettings.approvalAskScope.rawValue
    rendered = rendered.replacingOccurrences(of: degradationToken, with: degradation)
    rendered = rendered.replacingOccurrences(of: askScopeToken, with: askScope)
    rendered = rendered.replacingOccurrences(
      of: gateConfigToken,
      with:
        #"{"degradation":"\#(degradation)","timeoutMs":\#(gateApprovalTimeoutMs),"askScope":"\#(askScope)"}"#
    )
    return rendered
  }

  // MARK: - 文件清理

  /// 删除一个集成文件；不存在时静默跳过（本来就没装）。
  private static func removeFile(_ file: URL, label: String) {
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do {
      try FileManager.default.removeItem(at: file)
    } catch {
      logger.error("删除 \(label, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
    }
  }

  /// 删除同一目录下改名遗留的旧文件。
  private static func removeLegacyFiles(in directory: URL, names: [String]) {
    for name in names {
      let file = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      do {
        try FileManager.default.removeItem(at: file)
        logger.notice("已清理改名遗留的集成文件：\(name, privacy: .public)")
      } catch {
        logger.debug("遗留集成文件未能删除：\(name, privacy: .public)")
      }
    }
  }

  // MARK: - OpenCode

  /// OpenCode 插件的目标路径。
  static func openCodePluginFile() -> URL? {
    guard let paths = AgentRegistry.provider(for: .opencode).paths() else { return nil }
    return paths.configDir
      .appendingPathComponent("plugins")
      .appendingPathComponent(openCodePluginName)
  }

  private static func installOpenCodePlugin() -> Bool {
    guard let destination = openCodePluginFile() else { return false }
    guard
      let source = Bundle.main.url(
        forResource: "agent-island-opencode-plugin", withExtension: "js"),
      let contents = try? String(contentsOf: source, encoding: .utf8)
    else {
      logger.error("缺少内置的 OpenCode 插件资源，无法安装集成")
      return false
    }

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: destination, atomically: true, encoding: .utf8)
      removeLegacyFiles(in: destination.deletingLastPathComponent(), names: Self.legacyOpenCodePluginNames)
      return true
    } catch {
      logger.error("写入 OpenCode 插件失败：\(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}
