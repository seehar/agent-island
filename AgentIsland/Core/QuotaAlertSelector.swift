//
//  QuotaAlertSelector.swift
//  AgentIsland
//
//  余额提醒的阈值（「低于多少钱提醒」）。**金额由用户自己填**——预设档位表达不了
//  「我这张卡只剩 3 块 5 就该提醒」这类需求，而额度页上的数字本来就是连续的。
//
//  阈值是**显示口径的数字**：就是额度页上印出来的那个量（`NewAPIBalanceFormat`）。
//  这样用户设的「5」与他在列表里看到的「$5.32」是同一个量，不必心算站点那套
//  `quota ÷ quota_per_unit × 汇率` 的换算；代价是同一个阈值在两个显示口径不同的
//  实例上含义不同（`quotaAlertBelow` 只存一个数）。
//
//  0（或留空）= 关闭：不提醒，也**一个请求都不发**（后台慢轮询的门就是它，
//  见 `NewAPIBalanceViewModel` 头注释）。
//

import Combine
import Foundation

/// 余额提醒阈值的持久化。与 `NotchWidthSelector` / `NotchHeightSelector` 同族：
/// 视图与视图模型都要读同一个实例，改了值必须重发布（否则「改了设置没生效」）。
@MainActor
final class QuotaAlertSelector: ObservableObject {
    static let shared = QuotaAlertSelector()

    /// 阈值上限。额度提醒设到接近百万没有意义，而输入框只收 6 位整数（外加一位溢出位，
    /// 见 `sanitized`）——上限因此正好是六位数里最大的那个。超出部分**夹紧**到它，
    /// 而不是把多出来的位丢掉（丢位会让 `1000000` 静默变成 `100000`，差 10 倍）。
    nonisolated static let maximumAmount: Double = 999_999

    /// 偏好键。**与已废弃的枚举键 `quotaAlertThreshold` 不同名**：那个键存的是
    /// `off/one/five/…` 这类档位字符串，同一个键换类型会让后来读代码的人以为
    /// 这里能读到旧的档位值。旧键没有任何读取方（改名发生在未发布的提交里）。
    nonisolated static let key = "quotaAlertBelow"

    /// 当前阈值（显示口径的金额）。0 = 关闭。
    @Published private(set) var amount: Double = 0

    private let defaults: UserDefaults

    /// 默认读写标准偏好域；测试传独立域，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.key)
        amount = Self.clamped(stored)
    }

    /// 是否设了阈值（判断侧与轮询门都问它，不自己判一遍 `amount > 0`）。
    var isEnabled: Bool { amount > 0 }

    /// 判断侧要的阈值；关闭态是 nil（`QuotaAlertPolicy` 把 nil 当「永不判低」）。
    var threshold: Double? { amount > 0 ? amount : nil }

    /// 键入一个阈值（输入框里逐字符生效）。非法 / 空文本按「关闭」处理——那正是
    /// 用户清空输入框的意思。
    func setAmount(fromText text: String, decimalSeparator: Character? = nil) {
        setAmount(Self.sanitized(text, decimalSeparator: decimalSeparator))
    }

    /// 直接写入一个阈值（夹进 [0, maximumAmount]，保留两位小数）。
    ///
    /// 值没变就直接返回：输入框是**逐字符**生效的，每次落盘都会让视图模型那一侧的
    /// 订阅白跑一遍（起停轮询本身是空操作，但没必要）。
    func setAmount(_ value: Double) {
        let clamped = Self.clamped(value)
        guard clamped != amount else { return }
        amount = clamped
        defaults.set(clamped, forKey: Self.key)
    }

    // MARK: - 数值归一（纯函数，可单测）

    /// 夹紧到一个可用的阈值。
    nonisolated static func clamped(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min((value * 100).rounded() / 100, maximumAmount)
    }

    /// 输入框文本 → 金额。只认 ASCII 数字与一个小数点（最多两位小数、整数部分最多 7 位）；
    /// 没有数字时给 0（= 关闭）。
    ///
    /// - Parameters:
    ///   - text: 输入框里的原文。
    ///   - decimalSeparator: 环境 locale 的小数点（法语等 locale 下是 `,`）。`.` 与它
    ///     都算小数点——用户的键盘只会打出自己 locale 的那个。
    ///
    /// 逗号只在「逗号是小数点」的 locale 下当小数点：`5,000` 在德语下是 5、在英语下是
    /// 5000（各自都是当地读法）。两种 locale 的差别因此落在「用户自己怎么读」上，
    /// 而不是我们的猜测上。
    nonisolated static func sanitized(
        _ text: String, decimalSeparator: Character? = nil
    ) -> Double {
        let separators = Set([Character("."), decimalSeparator].compactMap { $0 })

        var integer = ""
        var fraction = ""
        var seenSeparator = false
        for character in text {
            if separators.contains(character) {
                guard !seenSeparator else { continue }
                seenSeparator = true
                continue
            }
            guard character.isASCII, character.isNumber else { continue }
            if seenSeparator {
                guard fraction.count < 2 else { continue }
                fraction.append(character)
            } else {
                // 7 位而不是 6 位：上限是 999,999，多出来的这一位让「敲得进去的值」有机会
                // 走到夹紧那一步（`clamped`），而不是在解析时就被丢掉一位。
                guard integer.count < 7 else { continue }
                integer.append(character)
            }
        }

        guard !integer.isEmpty || !fraction.isEmpty else { return 0 }
        let normalized =
            (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        return clamped(Double(normalized) ?? 0)
    }

    /// 金额 → 输入框文本（关闭态给空串，由占位符写「关闭」）。
    ///
    /// **不做千位分组**：输入框要能原样解析回去，而 `1,000` 在逗号是小数点的 locale 下
    /// 会被读成 1（见 `sanitized`）——这是本函数与 `NewAPIBalanceFormat.money` 唯一的差别。
    nonisolated static func text(from amount: Double, locale: Locale) -> String {
        guard amount > 0 else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: clamped(amount)))
            ?? String(format: "%.2f", clamped(amount))
    }
}

/// 判断侧要的阈值数值（`nonisolated`：后台轮询里读偏好域）。
nonisolated enum QuotaAlertPreference {
    /// 当前阈值（显示口径的数字）；留空（= 0）为 nil。
    ///
    /// 读的是**偏好域**而不是 `QuotaAlertSelector.shared`：视图模型带着可注入的
    /// `defaults`（用例要指向临时域），轮询循环每轮都问一次这里，因此设置里改了阈值
    /// 下一轮就换了口径，不必重启应用。
    static func value(defaults: UserDefaults = .standard) -> Double? {
        let stored = QuotaAlertSelector.clamped(defaults.double(forKey: QuotaAlertSelector.key))
        return stored > 0 ? stored : nil
    }
}
