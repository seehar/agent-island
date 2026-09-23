//
//  NewAPIBalance.swift
//  AgentIsland
//
//  New API 额度读数的数据模型：查询配置、一个槽位的数值与状态、以及一次刷新的整份快照。
//  纯值类型（`Equatable` / `Sendable`），不含网络也不含文案——失败原因是客户端映射好的
//  字符串（见 `NewAPIBalanceClient`），因此这里不做本地化、不读偏好域。
//

import Foundation

/// 一次查询需要的配置。
///
/// 四个字段都是用户手输的原文；`trimmed…` 系列是去空白后的实际取值——文本框里粘贴进来的
/// 凭据常带一个尾换行，直接拼进请求头会让服务端认不出来。
nonisolated struct NewAPIConfig: Equatable, Sendable {
    /// 服务器地址，形如 `https://api.example.com`（可带路径前缀，尾斜杠会被去掉）。
    var serverURL: String
    /// API Key（`sk-…`）：查当前 Key 的额度用它。
    var apiKey: String
    /// 用户访问令牌：查账户余额用它（`/api/user/self` 不接受 `sk-`）。
    var accessToken: String
    /// 用户 ID：旧版 New API 查账户余额时要求 `New-Api-User` 头，新版忽略它。
    var userID: String

    var trimmedServerURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAccessToken: String { accessToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUserID: String { userID.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 至少能查 Key 额度：地址与 Key 齐备。
    var isConfigured: Bool {
        !trimmedServerURL.isEmpty && !trimmedAPIKey.isEmpty
    }

    /// 账户槽能不能查：地址与 Key 齐备，且填了访问令牌。
    var canReadAccount: Bool {
        isConfigured && !trimmedAccessToken.isEmpty
    }
}

/// 一个槽位的读数数值。
///
/// `available` 的口径两个端点不同名但同义（都是**剩余**）：Key 端点给 `total_available`，
/// 账户端点给 `quota`——官方文档里「当前余额」就是它，**不要**再拿 `used_quota` 去减。
nonisolated struct NewAPIBalanceValue: Equatable, Sendable {
    /// 剩余额度。
    var available: Double
    /// 已用额度（Key = `total_used`，账户 = `used_quota`）。
    var used: Double
    /// 总额度：只有 Key 端点给（`total_granted` = 剩余 + 已用）；账户端点没有这个数。
    var granted: Double?
    /// 不限额度（Key 的 `unlimited_quota`）：数值仍会返回，但语义上不该报数。
    var unlimited: Bool
}

/// 一个槽位（账户 / Key）的读数状态。
nonisolated enum NewAPIBalanceReading: Equatable, Sendable {
    /// 没配服务器地址或 Key：连查都不查。
    case notConfigured
    /// 地址与 Key 齐备，但账户槽没填访问令牌。
    case needsAccessToken
    /// 正在拉取（首次，或配置刚改过）。
    case loading
    /// 拿到读数。
    case value(NewAPIBalanceValue)
    /// 失败：原因 + 上一次成功的数值（有就继续显示，免得一次网络抖动把数字擦掉）。
    case failed(reason: String, value: NewAPIBalanceValue?)

    /// 上一次成功的数值：`value` 与「失败但留着旧值」两种都能取到。
    var lastValue: NewAPIBalanceValue? {
        switch self {
        case .value(let value): return value
        case .failed(_, let value): return value
        case .notConfigured, .needsAccessToken, .loading: return nil
        }
    }
}

/// 一次刷新的整份读数。
nonisolated struct NewAPIBalanceSnapshot: Equatable, Sendable {
    /// 账户余额槽（`/api/user/self`）。
    var account: NewAPIBalanceReading = .notConfigured
    /// 当前 Key 额度槽（`/api/usage/token/`）。
    var key: NewAPIBalanceReading = .notConfigured
    /// 最后一次「至少一个槽位拿到数值」的时刻。两个槽位全失败时保留旧值——页眉因此如实
    /// 显示的是「上次成功」的时间，而不是一次失败请求的时间。
    var refreshedAt: Date?
}
