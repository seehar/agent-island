//
//  Settings.swift
//  ClaudeIsland
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

nonisolated enum AppSettings {
  private static let defaults = UserDefaults.standard

  // MARK: - Keys

  private enum Keys {
    static let notificationSound = "notificationSound"
    static let claudeDirectoryName = "claudeDirectoryName"
    static let language = "language"
    static let disabledAgents = "disabledAgents"
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
}
