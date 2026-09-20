//
//  Localization.swift
//  ClaudeIsland
//
//  运行时语言切换。所有面向用户的文案都通过 `LocalizationManager` 查找，
//  它按当前选中的语言从对应的 `.lproj` bundle（由 Localizable.xcstrings 生成）
//  解析字符串。切换语言时会重新发布变更，因此观察该管理器的 SwiftUI 视图会重新渲染。
//

import Combine
import Foundation

/// 界面可以使用的语言。
///
/// `system` 跟随 macOS 的语言偏好；其余取值会把界面固定到某个本地化，
/// 不受系统设置影响。
///
/// 纯值类型、没有共享可变状态，因此整体 `nonisolated`：非隔离的产出者
/// （后台扫描器、错误描述、静态查表入口）也需要读取它的语言代码。
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    /// 原始值即 `.lproj` 语言代码；`system` 用哨兵值表示“跟随系统”。
    case system = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 随应用一起打包的 `.lproj` 语言代码（见 Localizable.xcstrings）。
    static let availableCodes = ["en", "zh-Hans"]

    /// 该语言实际使用的 `.lproj` 代码。
    var resolvedCode: String {
        self == .system ? Self.systemCode : rawValue
    }

    /// 当前 macOS 语言偏好下最匹配的受支持语言。
    static var systemCode: String {
        systemCode(for: Locale.preferredLanguages)
    }

    /// 按偏好顺序挑出最匹配的受支持语言（纯函数，便于测试）。
    /// 先精确匹配，再退化为按主语言子标签匹配，使 en-GB / zh-Hant 这类也能命中；
    /// 完全没有匹配时回退到英语。
    static func systemCode(for preferredLanguages: [String]) -> String {
        for preference in preferredLanguages {
            let code = preference.replacingOccurrences(of: "_", with: "-")
            if let exact = availableCodes.first(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                return exact
            }
            let primary = code.prefix { $0 != "-" }
            if let match = availableCodes.first(where: { $0.hasPrefix(primary) }) {
                return match
            }
        }
        return "en"
    }
}

/// 按选中语言解析本地化字符串，并在选择变化时通知观察者。
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// 界面渲染所用语言，持久化在 `AppSettings` 中。
    @Published private(set) var language: AppLanguage

    private init() {
        language = AppSettings.language
    }

    /// 选择语言并持久化该选择。
    func select(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        AppSettings.language = newLanguage
    }

    /// 与选中语言对应的 Locale，用于 SwiftUI 的格式化。
    var locale: Locale {
        Locale(identifier: language.resolvedCode)
    }

    /// 承载选中语言文案的 bundle。若该语言未打包，则回退到主 bundle
    /// （英语源文案）。
    private var bundle: Bundle { Self.bundle(for: language.resolvedCode) }

    /// `.lproj` bundle 解析：按语言代码取对应 bundle，未打包时回退到主 bundle
    /// （英语源文案）。只依赖传入的代码、不读任何可变状态，因此实例路径与
    /// 非隔离的静态路径共用同一份实现。
    nonisolated static func bundle(for code: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return .main
        }
        return languageBundle
    }

    /// 取得 `key` 对应的本地化字符串。key 即英语源文案。
    func t(_ key: String) -> String {
        LocalizationManager.t(key)
    }

    /// 取得 `key` 对应的本地化格式串，并代入 `arguments`。
    func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: LocalizationManager.t(key), locale: locale, arguments: arguments)
    }

    /// 非隔离的查表入口，供 `nonisolated` 类型（后台扫描器、静态工具、错误
    /// 描述）使用。语言直接取自持久化的 `AppSettings.language`：`select(_:)`
    /// 每次都把选择写回该偏好，因此这里不需要任何缓存快照，也就没有读到
    /// 陈旧语言的窗口。
    nonisolated static func t(_ key: String) -> String {
        bundle(for: AppSettings.language.resolvedCode)
            .localizedString(forKey: key, value: nil, table: nil)
    }

    /// 非隔离的格式化入口，语义与实例版本一致；locale 同样由持久化偏好推出。
    nonisolated static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: t(key),
            locale: Locale(identifier: AppSettings.language.resolvedCode),
            arguments: arguments)
    }

    /// 语言选择器中的语言名称。固定语言始终以其自身语言书写，便于用户辨认；
    /// `system` 则跟随界面当前语言。
    nonisolated func displayName(for language: AppLanguage) -> String {
        switch language {
        case .system: return Self.t("System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}
