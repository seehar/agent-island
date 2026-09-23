//
//  Localization.swift
//  AgentIsland
//
//  运行时语言切换。所有面向用户的文案都通过 `LocalizationManager` 查找，
//  它按当前选中的语言从对应的 `.lproj` bundle（由 Localizable.xcstrings 生成）
//  解析字符串。切换语言时会重新发布变更，因此观察该管理器的 SwiftUI 视图会重新渲染。
//
//  两条路径的分工：
//  * 文案一律走 `t(_:)`。SwiftUI 的 `LocalizedStringKey`（`Text("…")` 字面量、`Label`
//    等）由平台按 `Bundle.main` 的语言解析，既读不到这里的 `.lproj` 覆盖，也不受本
//    文件控制——所以界面文案必须写成 `Text(l10n.t("…"))`。
//  * 数字、日期、度量衡的默认格式化读环境里的 `\.locale`，由根视图的 `LocalizedRoot`
//    注入，使格式与界面语言一致，而不是跟随系统。
//

import Combine
import Foundation
import SwiftUI

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
    ///
    /// 交给平台算法——CFBundle 解析 `.lproj` 用的是同一套：它认同同一个书写系统内的
    /// 变体（en-GB → en、zh → zh-Hans），但不会把「繁体中文」当成「简体中文」
    /// （zh-Hant 不在支持列表里，按平台语义回退到英语）。自己按主语言子标签兜底会
    /// 让繁体用户拿到简体，而同一界面上由平台解析的部分仍是英语，两种语言混排。
    static func systemCode(for preferredLanguages: [String]) -> String {
        Bundle.preferredLocalizations(from: availableCodes, forPreferences: preferredLanguages).first
            ?? "en"
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

    /// 语言代码 → `.lproj` bundle 的查找表。
    ///
    /// 查表落在界面渲染路径上，而每次 `path(forResource:)` + `Bundle(path:)` 都要做
    /// 文件系统探测（实测约为缓存命中的 8 倍）。语言集合随应用打包、运行期不会变，
    /// 因此启动时解析一次即可，既省开销也不需要失效逻辑。
    private nonisolated static let localizedBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for code in AppLanguage.availableCodes {
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            bundles[code] = bundle
        }
        return bundles
    }()

    /// `.lproj` bundle 解析：按语言代码取对应 bundle，未打包时回退到主 bundle
    /// （英语源文案）。只依赖传入的代码、不读任何可变状态，因此实例路径与
    /// 非隔离的静态路径共用同一份实现。
    nonisolated static func bundle(for code: String) -> Bundle {
        localizedBundles[code] ?? .main
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

    /// 按**指定**语言代码查表（非隔离）。
    ///
    /// 给「语言要显式传参」的调用点用（见 `UsageStatsFormat.presetTitle`）：它走的是同一个
    /// `.lproj` 查表，因此不会像 `NSLocalizedString` 那样读系统语言；把解析放在这里而不是
    /// 让调用方自己碰 `bundle(for:).localizedString(forKey:)`，也免得本地化守卫把它误判成
    /// 「绕过自研查表」。
    nonisolated static func t(_ key: String, languageCode: String) -> String {
        bundle(for: languageCode).localizedString(forKey: key, value: nil, table: nil)
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
    ///
    /// 「跟随系统」用**独立键**：它曾与通用页「System」分组标题共用 `System` 一键，
    /// 中文界面下分组标题因此渲染成「跟随系统」（与组内内容不符）。键是英文源文案，
    /// 两处同义不同用，必须分开。
    nonisolated func displayName(for language: AppLanguage) -> String {
        switch language {
        case .system: return Self.t("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// 把界面语言注入 SwiftUI 环境里的 `\.locale`，挂在窗口根视图上。
///
/// 文案本身不走环境：`LocalizedStringKey` 由平台按 `Bundle.main` 的语言解析，读不到
/// 本文件的 `.lproj` 覆盖，所以文案仍旧一律走 `t(_:)`。这里管的是另一半——
/// 数字、日期、度量衡的默认格式化读环境 `\.locale`，不注入就会跟着系统语言走，
/// 出现「界面中文、数字英文」这类混排。
///
/// 注入的是 `l10n.locale`（形如 `en` / `zh-Hans`）而不是环境原本带区域信息的标识：
/// 后者会随 macOS 区域设置变化，白白让读取它的视图失效重建。
struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 根视图内容。构建器属性直接存住已构造的视图，而不是存闭包：
    /// 闭包会捕获宿主视图控制器，形成 hostingView → 闭包 → 宿主 的引用环。
    @ViewBuilder var content: Content

    var body: some View {
        content.environment(\.locale, l10n.locale)
    }
}
