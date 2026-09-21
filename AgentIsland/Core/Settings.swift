//
//  Settings.swift
//  AgentIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
  case none = "None"
  case pop = "Pop"
  case ping = "Ping"
  case tink = "Tink"
  case glass = "Glass"
  case blow = "Blow"
  case bottle = "Bottle"
  case frog = "Frog"
  case funk = "Funk"
  case hero = "Hero"
  case morse = "Morse"
  case purr = "Purr"
  case sosumi = "Sosumi"
  case submarine = "Submarine"
  case basso = "Basso"

  /// The system sound name to use with NSSound, or nil for no sound
  var soundName: String? {
    self == .none ? nil : rawValue
  }
}

/// 应用不可达（AgentIsland 没开）时闸门怎么办。
///
/// 这一档只在「无人可问」时生效；「问了没答」（超时）永远是拒绝——omp 生效的
/// `approvalMode` 已是 yolo，超时放行等于静默执行任意命令。
nonisolated enum ApprovalDegradation: String, CaseIterable, PreferenceOption {
  /// 一律拒绝：把 agent 当生产工具，宁可停下也不误执行。
  case strict
  /// 放行 + 记录 + 刘海事后展示；已知危险命令仍然拒绝。（默认）
  case notifyOnly = "notify-only"
  /// 只放行只读工具，写 / 执行一律拒绝。
  ///
  /// 注意：只读档（read/glob/grep…）在闸门之前就放行了，能走到闸门的都是写 / 执行档，
  /// 因此实际效果与 `strict` 相同——差别只在与用户心智模型对齐。
  case readOnlyAllow = "read-only-allow"

  /// 偏好域里的键。与 `AppSettings.Keys.approvalDegradation` 是同一个键——
  /// 档位既可以走偏好骨架读写，也可以走 AppSettings 的既有入口，两条路径落同一处。
  static let preferenceKey = "approvalDegradation"

  /// 默认档：不打断工作，同时危险命令仍有底线。
  static var defaultValue: ApprovalDegradation { .notifyOnly }
}

/// 降级档的设置行载体（`EnumPreference` 的骨架 + 行内展开状态，见 BehaviorPreferences）。
typealias ApprovalDegradationSelector = EnumPreference<ApprovalDegradation>

nonisolated enum AppSettings {
  private static let defaults = UserDefaults.standard

  // MARK: - Keys

  private enum Keys {
    static let notificationSound = "notificationSound"
    static let claudeDirectoryName = "claudeDirectoryName"
    static let language = "language"
    static let disabledAgents = "disabledAgents"
    static let approvalGateAgents = "approvalGateAgents"
    static let approvalDegradation = "approvalDegradation"
    static let ompGateConfigBackupPath = "ompGateConfigBackupPath"
    static let ompGateConfigOriginalTimeout = "ompGateConfigOriginalTimeout"
    static let ompGateConfigAppliedAt = "ompGateConfigAppliedAt"
  }

  // MARK: - Notification Sound

  /// The sound to play when Claude finishes and is ready for input
  static var notificationSound: NotificationSound {
    get {
      guard let rawValue = defaults.string(forKey: Keys.notificationSound),
        let sound = NotificationSound(rawValue: rawValue)
      else {
        return .pop  // Default to Pop
      }
      return sound
    }
    set {
      defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
    }
  }

  // MARK: - Language

  /// 界面所用语言，默认跟随系统语言。
  static var language: AppLanguage {
    get {
      guard let rawValue = defaults.string(forKey: Keys.language),
        let language = AppLanguage(rawValue: rawValue)
      else {
        return .system
      }
      return language
    }
    set {
      defaults.set(newValue.rawValue, forKey: Keys.language)
    }
  }

  // MARK: - Agents

  /// notch 是否监控某个 Agent CLI。默认全部启用，新装应用即可自动接管
  /// 用户已在使用的那一个。
  static func isAgentEnabled(_ kind: AgentKind) -> Bool {
    !disabledAgents.contains(kind.rawValue)
  }

  static func setAgent(_ kind: AgentKind, enabled: Bool) {
    var disabled = disabledAgents
    if enabled {
      disabled.remove(kind.rawValue)
    } else {
      disabled.insert(kind.rawValue)
    }
    disabledAgents = disabled
  }

  private static var disabledAgents: Set<String> {
    get { Set(defaults.stringArray(forKey: Keys.disabledAgents) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: Keys.disabledAgents) }
  }

  // MARK: - Claude Directory

  /// The name of the Claude config directory under the user's home folder.
  /// Defaults to ".claude" (standard Claude Code installation).
  /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
  static var claudeDirectoryName: String {
    get {
      let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
      return value.isEmpty ? ".claude" : value
    }
    set {
      defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
    }
  }

  // MARK: - 审批闸门

  /// 某个 Agent 是否在刘海上审批它的工具调用。默认关：只有用户显式打开后才有闸门。
  /// 只有装了「闸门版扩展」的 Agent（omp / pi）才有意义，见 `AgentIntegrationInstaller`。
  static func isApprovalGateEnabled(_ kind: AgentKind) -> Bool {
    approvalGateAgents.contains(kind.rawValue)
  }

  static func setApprovalGate(_ kind: AgentKind, enabled: Bool) {
    var agents = approvalGateAgents
    if enabled {
      agents.insert(kind.rawValue)
    } else {
      agents.remove(kind.rawValue)
    }
    approvalGateAgents = agents
  }

  private static var approvalGateAgents: Set<String> {
    get { Set(defaults.stringArray(forKey: Keys.approvalGateAgents) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: Keys.approvalGateAgents) }
  }

  /// 闸门问什么（写/执行档要不要阻塞等人点按）；默认「都问」。
  /// 随扩展文件下发（写进闸门版扩展文件头的标记与策略常量），不写用户的 agent 配置。
  /// 读写走偏好骨架（`PreferenceStore`），设置行里改档位与本入口落同一处。
  static var approvalAskScope: ApprovalAskScope {
    get { PreferenceStore.read(ApprovalAskScope.self, defaults: defaults) }
    set { PreferenceStore.write(newValue, defaults: defaults) }
  }

  /// 应用不可达时闸门怎么办；默认 `notify-only`。
  /// 随扩展文件下发（写进扩展里的策略常量），不写用户的 agent 配置。
  /// 读写走偏好骨架（`PreferenceStore`），设置行里改档位与本入口落同一处。
  static var approvalDegradation: ApprovalDegradation {
    get { PreferenceStore.read(ApprovalDegradation.self, defaults: defaults) }
    set { PreferenceStore.write(newValue, defaults: defaults) }
  }

  // MARK: - omp 配置写入记录

  /// `~/.omp/agent/config.yml` 的备份路径（关闭闸门时据此还原）。
  static var ompGateConfigBackupPath: String? {
    get { defaults.string(forKey: Keys.ompGateConfigBackupPath) }
    set { defaults.set(newValue, forKey: Keys.ompGateConfigBackupPath) }
  }

  /// 写入前 `extensionHandlers.toolCallTimeoutMs` 的原值（界面展示与还原核对用）。
  static var ompGateConfigOriginalTimeout: String? {
    get { defaults.string(forKey: Keys.ompGateConfigOriginalTimeout) }
    set { defaults.set(newValue, forKey: Keys.ompGateConfigOriginalTimeout) }
  }

  /// 写入时间。
  static var ompGateConfigAppliedAt: Date? {
    get { defaults.object(forKey: Keys.ompGateConfigAppliedAt) as? Date }
    set { defaults.set(newValue, forKey: Keys.ompGateConfigAppliedAt) }
  }

  // MARK: - 改名迁移

  /// 改名前的 bundle id。偏好域跟着 bundle id 走，改名后是一个全新的空域，
  /// 因此第一次在新域启动时把旧域里用户设过的键搬过来，否则用户的设置会「丢」。
  private static let legacyBundleIdentifier = "com.celestial.ClaudeIsland"

  /// 迁移只做一次的标记，写在**新**域里。
  private static let migrationMarkerKey = "didMigrateFromLegacyBundle"

  /// 把旧 bundle id 域里的用户键搬进当前域（只搬当前域还没有的键，系统键不动）。
  static func migrateLegacyDefaultsIfNeeded() {
    guard !defaults.bool(forKey: migrationMarkerKey) else { return }
    defaults.set(true, forKey: migrationMarkerKey)

    guard let legacy = UserDefaults(suiteName: legacyBundleIdentifier),
      let legacyValues = legacy.persistentDomain(forName: legacyBundleIdentifier)
    else { return }

    for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
      // 系统与 Sparkle 的运行期键不属于用户设置。
      guard !key.hasPrefix("NS"), !key.hasPrefix("Apple"), !key.hasPrefix("SU") else { continue }
      defaults.set(value, forKey: key)
    }
  }
}
