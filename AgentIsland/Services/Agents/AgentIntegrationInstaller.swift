//
//  AgentIntegrationInstaller.swift
//  AgentIsland
//
//  为各 Agent 安装「实时事件上报」集成：
//    - Claude Code：hook 脚本 + settings.json（由 `HookInstaller` 负责）
//    - pi / Oh My Pi：`<agent 目录>/extensions/agent-island-state.ts`
//    - OpenCode：`~/.config/opencode/plugins/agent-island-state.js`
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
  private static let piFamilyExtensionResourceName = "agent-island-pi-extension"
  private static let piFamilyExtensionResourceExtension = "ts.txt"
  /// OpenCode 插件文件名。
  static let openCodePluginName = "agent-island-state.js"

  /// 安装时替换的 Agent 标识占位符。
  private static let agentToken = "__AGENT_ISLAND_AGENT__"

  // MARK: - 批量安装

  /// 启动时为所有已启用的 Agent 安装集成。
  static func installIfNeeded() {
    // 所有随包提供集成的 Agent 都尝试安装：OpenCode 没有集成也能靠数据库轮询工作，
    // 但插件能带来实时事件，因此同样默认安装（安装失败不影响其可用性）。
    for kind in AgentRegistry.enabled
    where AgentRegistry.provider(for: kind).integrationStatus() != nil {
      _ = install(kind)
    }
  }

  // MARK: - 单个 Agent

  /// 安装某个 Agent 的集成；返回是否安装成功。
  @discardableResult
  static func install(_ kind: AgentKind) -> Bool {
    switch kind {
    case .claudeCode:
      HookInstaller.installIfNeeded()
      return HookInstaller.isInstalled()
    case .ohMyPi, .pi:
      return installPiFamilyExtension(kind)
    case .opencode:
      return installOpenCodePlugin()
    }
  }

  /// 卸载某个 Agent 的集成。
  static func uninstall(_ kind: AgentKind) {
    switch kind {
    case .claudeCode:
      HookInstaller.uninstall()
    case .ohMyPi, .pi:
      if let file = piFamilyExtensionFile(kind) {
        try? FileManager.default.removeItem(at: file)
      }
    case .opencode:
      if let file = openCodePluginFile() {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  /// 是否已安装。
  static func isInstalled(_ kind: AgentKind) -> Bool {
    switch kind {
    case .claudeCode:
      return HookInstaller.isInstalled()
    case .ohMyPi, .pi:
      guard let file = piFamilyExtensionFile(kind) else { return false }
      return FileManager.default.fileExists(atPath: file.path)
    case .opencode:
      guard let file = openCodePluginFile() else { return false }
      return FileManager.default.fileExists(atPath: file.path)
    }
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
    guard
      let source = Bundle.main.url(
        forResource: piFamilyExtensionResourceName,
        withExtension: piFamilyExtensionResourceExtension
      ),
      let contents = try? String(contentsOf: source, encoding: .utf8)
    else {
      logger.error("缺少内置的 pi 扩展资源，无法为 \(kind.rawValue, privacy: .public) 安装集成")
      return false
    }

    let rendered = contents.replacingOccurrences(of: agentToken, with: kind.rawValue)
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try rendered.write(to: destination, atomically: true, encoding: .utf8)
      return true
    } catch {
      logger.error("写入 pi 扩展失败：\(error.localizedDescription, privacy: .public)")
      return false
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
      return true
    } catch {
      logger.error("写入 OpenCode 插件失败：\(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}
