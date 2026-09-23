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
    /// 显式启用集合（新口径）：不在集合里就是「关」。
    static let enabledAgents = "enabledAgents"
    /// 旧口径的禁用集合：只用于一次性迁移，不再写。
    static let legacyDisabledAgents = "disabledAgents"
    /// 逐 Agent 的配置根覆盖：`[AgentKind.rawValue: 绝对路径]`。
    static let agentRootOverrides = "agentRootOverrides"
    /// 「启用口径迁移」只做一次的标记。
    static let enablementMigrationMarker = "didMigrateAgentEnablement"
    /// 「旧口径 Claude 目录 → 通用覆盖表」迁移只做一次的标记。
    static let claudeDirMigrationMarker = "didMigrateClaudeDirectoryOverride"
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

  /// notch 是否监控某个 Agent CLI。
  ///
  /// **默认关闭**：应用不替用户接管任何工具，启用必须是一次显式动作（行内开关，
  /// 或「智能体」页的「全部启用并安装」）。历史上这里是「默认全开 + 禁用集合」，
  /// 升级用户由 `migrateAgentEnablementIfNeeded()` 换算一次。
  static func isAgentEnabled(_ kind: AgentKind) -> Bool {
    enabledAgents.contains(kind.rawValue)
  }

  static func setAgent(_ kind: AgentKind, enabled: Bool) {
    var enabledKinds = enabledAgents
    if enabled {
      enabledKinds.insert(kind.rawValue)
    } else {
      enabledKinds.remove(kind.rawValue)
    }
    enabledAgents = enabledKinds
  }

  private static var enabledAgents: Set<String> {
    get { Set(defaults.stringArray(forKey: Keys.enabledAgents) ?? []) }
    set { defaults.set(Array(newValue).sorted(), forKey: Keys.enabledAgents) }
  }

  // MARK: - 逐 Agent 配置目录

  /// 用户为某个 Agent 指定的配置根目录（绝对路径或 `~/…`）。nil = 自动检测。
  ///
  /// 优先级由各 Provider 决定（与环境变量的关系见 `AgentRootOverride`）：环境变量
  /// 仍然压过这里——那是工具自己的配置方式。
  static func agentRootOverride(_ kind: AgentKind) -> String? {
    let path = agentRootOverrides[kind.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
    return path.isEmpty ? nil : path
  }

  /// 写入/清除某个 Agent 的配置根目录；nil 或空白 = 恢复自动检测。
  static func setAgentRootOverride(_ kind: AgentKind, path: String?) {
    var overrides = agentRootOverrides
    let trimmed = path?.trimmingCharacters(in: .whitespaces) ?? ""
    if trimmed.isEmpty {
      overrides.removeValue(forKey: kind.rawValue)
    } else {
      overrides[kind.rawValue] = trimmed
    }
    agentRootOverrides = overrides

    // Claude 的目录有跨线程缓存（`ClaudePaths`），改完必须让它下次重新解析。
    if kind == .claudeCode { ClaudePaths.invalidateCache() }
  }

  private static var agentRootOverrides: [String: String] {
    get { defaults.dictionary(forKey: Keys.agentRootOverrides) as? [String: String] ?? [:] }
    set { defaults.set(newValue, forKey: Keys.agentRootOverrides) }
  }

  // MARK: - 启用口径迁移（只做一次）

  /// 把「默认全开 + 禁用集合」的旧口径换算成「显式启用集合」。
  ///
  /// 两条都不该发生：① 升级用户原本在监控的 Agent 因为换口径而掉线；② 本特性新接入的
  /// 那 13 个 Agent 因为「旧口径默认全开」而被动接管用户的机器。因此迁移只保留
  /// **改口径之前就默认启用**的那几个（`AgentKind.defaultEnabledBeforeOptIn`）里、
  /// 用户没有显式关掉的那些。
  ///
  /// 全新安装（偏好域里没有任何我们的键）什么都不迁：保持「默认关闭」。
  /// - Parameter hadPreviousInstall: **本机此前是否运行过本应用**（含改名前的版本）。
  ///   必须由调用方在**任何本次写入之前**判定并传进来——见 `hadPreviousInstallFootprint`。
  static func migrateAgentEnablementIfNeeded(hadPreviousInstall: Bool) {
    guard defaults.object(forKey: Keys.enablementMigrationMarker) == nil else { return }

    enabledAgents = enablementAfterMigration(
      legacyDisabled: defaults.stringArray(forKey: Keys.legacyDisabledAgents) ?? [],
      isFreshInstall: !hadPreviousInstall
    )
    // 旧键到此已经换算完，删掉它：留着会让 `defaults read` 里同时出现「禁用集合（空）」
    // 与「启用集合」，读起来像是「全都启用」——与新口径正好相反。
    defaults.removeObject(forKey: Keys.legacyDisabledAgents)
    // 标记最后写：中途崩掉时宁可下次重新换算，也不要留下「标记已写、集合为空」（那样
    // 用户会得到一个「全都关着」的既成事实，且再也不会自动换算）。
    defaults.set(true, forKey: Keys.enablementMigrationMarker)
  }

  /// 本机此前是否运行过本应用（或其改名前的版本）。
  ///
  /// 判据**不能**是「偏好域里有没有键」：
  /// - 同一次启动里，改名迁移会**无条件**写下 `didMigrateFromLegacyBundle`，所以那个标记
  ///   出现在域里不代表以前跑过（本仓曾因此把全新安装判成升级，白白接管了 4 个工具）；
  /// - Sparkle 的 `SU*` 键也不能用：`updater.start()` 在同一个进程里更早就跑过了。
  ///
  /// 改用**磁盘上的集成足迹**：上一个版本启动时会装集成（共享脚本 / 扩展 / 插件文件），
  /// 这些文件才是「跑过」的硬证据。而一个从没装过集成、也没改过设置的旧用户，本来就没有
  /// 在监控的对象——当作全新安装（什么都不启用）反而是对的。
  static func hadPreviousInstallFootprint(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    if hasInstallFootprintFiles(home: home) { return true }
    // 改名前的偏好域里有东西也算（老用户可能把集成删了，但设置还在）。
    guard let legacy = UserDefaults(suiteName: legacyBundleIdentifier),
      let values = legacy.persistentDomain(forName: legacyBundleIdentifier)
    else { return false }
    return !values.isEmpty
  }

  /// 集成足迹的**纯文件判据**（按给的 home 查，便于用临时目录单测）。
  static func hasInstallFootprintFiles(home: URL) -> Bool {
    let footprints = [
      ".agent-island/hooks/agent-island-state.py",  // 现行的共享脚本
      ".claude/hooks/agent-island-state.py",  // 旧落点（本批之前）
      ".claude/hooks/claude-island-state.py",  // 改名前的脚本名
      ".omp/agent/extensions/agent-island-state.ts",
      ".pi/agent/extensions/agent-island-state.ts",
      ".config/opencode/plugins/agent-island-state.js",
    ]
    let fm = FileManager.default
    return footprints.contains { fm.fileExists(atPath: home.appendingPathComponent($0).path) }
  }

  /// 旧口径的 Claude 配置目录（`claudeDirectoryName`：绝对路径，或家目录下的一个名字）
  /// 换算成通用覆盖表里的一条。
  ///
  /// `.claude`（旧口径的默认值）与空值都等于「自动检测」，因此不进覆盖表——进去了会让
  /// 界面一直显示「自定义目录」，而它其实只是默认值。
  static func claudeOverrideAfterMigration(legacyDirectoryName: String) -> String? {
    let trimmed = legacyDirectoryName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != ".claude" else { return nil }
    return trimmed.hasPrefix("/") ? trimmed : "~/" + trimmed
  }

  /// 把旧口径的 Claude 目录搬进通用覆盖表（只做一次）。
  ///
  /// 不迁的话，界面行会显示「自动检测」而 `ClaudePaths` 仍按旧键解析到别处——
  /// 「显示与生效不一致」是这类设置最讨厌的一种 bug。
  static func migrateClaudeDirectoryOverrideIfNeeded() {
    guard defaults.object(forKey: Keys.claudeDirMigrationMarker) == nil else { return }
    defaults.set(true, forKey: Keys.claudeDirMigrationMarker)
    guard agentRootOverride(.claudeCode) == nil else { return }
    guard
      let migrated = claudeOverrideAfterMigration(
        legacyDirectoryName: defaults.string(forKey: Keys.claudeDirectoryName) ?? "")
    else { return }
    setAgentRootOverride(.claudeCode, path: migrated)
  }

  /// 迁移的**纯函数**部分：旧口径的禁用集合 + 「是否全新安装」→ 新的启用集合。
  ///
  /// 抽出来是为了能单测：这条口径一旦算错，用户的监控列表会被静默改掉（升级用户掉线，
  /// 或全新安装被被动接管）。签名保持纯数据进出，不碰 UserDefaults。
  static func enablementAfterMigration(legacyDisabled: [String], isFreshInstall: Bool) -> Set<String> {
    // 全新安装：什么都不启用（「默认关闭」）。
    guard !isFreshInstall else { return [] }
    let disabled = Set(legacyDisabled)
    return Set(
      AgentKind.defaultEnabledBeforeOptIn
        .filter { !disabled.contains($0.rawValue) }
        .map(\.rawValue)
    )
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
