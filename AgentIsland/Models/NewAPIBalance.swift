//
//  NewAPIBalance.swift
//  AgentIsland
//
//  New API 额度读数的数据模型：一个账号（身份 + 凭据）、两个槽位的数值与状态、
//  以及一次刷新的整份快照。纯值类型（`Equatable` / `Sendable`），不含网络也不含文案——
//  失败原因是客户端映射好的字符串（见 `NewAPIBalanceClient`），因此这里不做本地化、
//  不读偏好域。
//
//  「一个实例几个账号」的形态：**一个账号一条**（`NewAPIAccount`），读数按账号 id 存
//  （见 `NewAPIBalanceSnapshot.readings`）。界面上一次只看一个账号的详细读数，
//  但每个账号的余额都在账号列表里各占一行。
//

import Foundation

/// 一次查询需要的配置。
///
/// 五个字段都是用户手输的原文；`trimmed…` 系列是去空白后的实际取值——文本框里粘贴进来的
/// 凭据常带一个尾换行，直接拼进请求头会让服务端认不出来。
nonisolated struct NewAPIConfig: Codable, Equatable, Sendable {
    /// 服务器地址，形如 `https://api.example.com`（可带路径前缀，尾斜杠会被去掉）。
    var serverURL: String = ""
    /// API Key（`sk-…`）：查当前 Key 的额度用它。
    var apiKey: String = ""
    /// 用户访问令牌：查账户余额用它（`/api/user/self` 不接受 `sk-`）。
    var accessToken: String = ""
    /// 用户 ID：旧版 New API 查账户余额时要求 `New-Api-User` 头，新版忽略它。
    var userID: String = ""

    init(
        serverURL: String = "", apiKey: String = "", accessToken: String = "", userID: String = ""
    ) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.userID = userID
    }

    /// 每个键都按可选解：这份结构落在**用户凭据**上，将来加/改字段时宁可少读一个值，
    /// 也不要整份账号列表解不出来——解不出来会被当成「全新安装」，把用户已存的账号
    /// 静默换成一张空表（Swift 合成的 `init(from:)` 对新增的非可选字段正是这种后果）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        userID = try container.decodeIfPresent(String.self, forKey: .userID) ?? ""
    }

    var trimmedServerURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAccessToken: String { accessToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUserID: String { userID.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 服务器地址填了没有：两个槽位的取数都要求它。
    var hasServer: Bool {
        !trimmedServerURL.isEmpty
    }

    /// Key 槽能不能查：地址与 Key 齐备。
    var canReadKey: Bool {
        hasServer && !trimmedAPIKey.isEmpty
    }

    /// 账户槽能不能查：地址与访问令牌齐备。
    var canReadAccount: Bool {
        hasServer && !trimmedAccessToken.isEmpty
    }

    /// **至少一个**槽位能查：视图模型据此决定要不要发请求。
    ///
    /// 这里的口径踩过坑：曾经要求「地址 + API Key」才算配好（账户槽另加令牌），于是
    /// 只填了访问令牌的用户在页面上看到的是两行「未配置」——连 `/api/user/self` 都
    /// 没发出去，看起来就是「访问令牌没用」。两个端点各要各的凭据，门禁必须分开。
    var isConfigured: Bool {
        canReadKey || canReadAccount
    }
}

/// 实例把额度显示成什么（`/api/status` 的公开设置，不需要凭据）。
///
/// 额度是 New API 的**内部单位**，站点自己决定显示口径：美元 / 人民币 / 自定义货币 /
/// 直接显示 token 数。应用照抄站点自己的换算（`quota ÷ quotaPerUnit × 汇率`）——这组值
/// 就是服务端给的，平台页面用的是同一套规则（实例前端 bundle 里的 `renderQuota`），
/// 因此两边数字一致，也不需要应用自己反推汇率。
nonisolated struct NewAPICurrency: Equatable, Sendable {
    /// 站点当前的显示类型。
    var displayType: NewAPICurrencyDisplayType = .usd
    /// 站点是否把额度显示成货币；关掉时页面直接写内部单位。
    var displayInCurrency: Bool = false
    /// 一个货币单位等于多少额度（站点设置，常见 500000）。
    var quotaPerUnit: Double = 500_000
    /// 美元对本币的汇率（`CNY` 用它）。
    var usdExchangeRate: Double = 1
    /// 自定义货币符号（`CUSTOM` 用它）。
    var customSymbol: String = ""
    /// 自定义货币的汇率（`CUSTOM` 用它）。
    var customExchangeRate: Double = 1

    /// 还不知道站点口径时的默认值：按内部单位显示（与改造前完全一致）。
    static let rawQuota = NewAPICurrency()
}

/// `/api/status` 里的 `quota_display_type`。不认识的类型按美元兜底（实例前端也这么兜底）。
nonisolated enum NewAPICurrencyDisplayType: String, Sendable {
    case usd = "USD"
    case cny = "CNY"
    case custom = "CUSTOM"
    case tokens = "TOKENS"

    init(siteValue: String?) {
        self = NewAPICurrencyDisplayType(rawValue: siteValue ?? "") ?? .usd
    }
}

/// 一个账号的两个槽位。两个端点各要各的凭据，因此「缺什么」必须按槽位算。
nonisolated enum NewAPISlot: Sendable {
    /// 账户余额（`/api/user/self`，要访问令牌）。
    case account
    /// 当前 Key 额度（`/api/usage/token/`，要 `sk-` 开头的 Key）。
    case key

    /// 这个槽位缺什么；能查就是 nil（不发请求、也不算失败）。
    func missing(in config: NewAPIConfig) -> NewAPIBalanceReading? {
        guard config.hasServer else { return .notConfigured }
        switch self {
        case .key: return config.canReadKey ? nil : .needsAPIKey
        case .account: return config.canReadAccount ? nil : .needsAccessToken
        }
    }
}

/// 一个 New API 账号：身份 + 显示名 + 凭据。
///
/// `id` 是**读数与选中态的键**：改地址/令牌不会换 id，因此改完凭据只需重拉，
/// 不必重建账号条目。偏好域里存的就是这个类型（见 `AppSettings.newAPIAccounts`）。
nonisolated struct NewAPIAccount: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 用户写的备注名；空则用服务器主机名（见 `displayName`）。
    var label: String
    var config: NewAPIConfig

    init(id: UUID = UUID(), label: String = "", config: NewAPIConfig = NewAPIConfig()) {
        self.id = id
        self.label = label
        self.config = config
    }

    /// 与 `NewAPIConfig` 同一套容错口径（见那里的注释）：缺 id 就补一个新的，
    /// 缺 config 就当空账号——都不该让整份列表解不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        config = try container.decodeIfPresent(NewAPIConfig.self, forKey: .config) ?? NewAPIConfig()
    }

    /// 有没有填过任何东西：空账号不进请求，也不必在列表里报「未配置」以外的状态。
    var isBlank: Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && config.trimmedServerURL.isEmpty && config.trimmedAPIKey.isEmpty
            && config.trimmedAccessToken.isEmpty && config.trimmedUserID.isEmpty
    }

    /// 列表与选择行上的显示名：备注名 → 服务器主机名 → 空串（界面按序号兜底）。
    var displayName: String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty { return trimmedLabel }
        return Self.host(from: config.trimmedServerURL)
    }

    /// 从服务器地址里取主机名（`https://a.example.com/sub` → `a.example.com`）。
    /// 解析不出主机时退回原文——界面上宁可显示用户填的东西，也不要空着。
    static func host(from serverURL: String) -> String {
        guard let host = URL(string: serverURL)?.host(), !host.isEmpty else { return serverURL }
        return host
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
    /// 连服务器地址都没填：不发请求。
    case notConfigured
    /// 地址填了，但账户槽没填访问令牌。
    case needsAccessToken
    /// 地址填了，但 Key 槽没填 API Key（账户槽有令牌时，账户那行照样会出数）。
    case needsAPIKey
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
        case .notConfigured, .needsAccessToken, .needsAPIKey, .loading: return nil
        }
    }
}

/// 一个账号的整份读数：两个槽位各一条。
nonisolated struct NewAPIAccountReading: Equatable, Sendable {
    /// 账户余额槽（`/api/user/self`）。
    var account: NewAPIBalanceReading = .notConfigured
    /// 当前 Key 额度槽（`/api/usage/token/`）。
    var key: NewAPIBalanceReading = .notConfigured
    /// 这台实例的额度显示口径（`/api/status`）；还没查到 / 查不到时是「按内部单位」。
    var siteCurrency: NewAPICurrency = .rawQuota

    /// 有没有任何一个槽位拿到过数值。
    var hasValue: Bool {
        account.lastValue != nil || key.lastValue != nil
    }
}

/// 一次刷新的整份读数：**每个账号一份**，按账号 id 查。
nonisolated struct NewAPIBalanceSnapshot: Equatable, Sendable {
    /// 各账号的读数；缺条目 = 这个账号还没查过（等同于「未配置」）。
    var readings: [UUID: NewAPIAccountReading] = [:]
    /// 最后一次「至少一个槽位拿到数值」的时刻。全部失败时保留旧值——页眉因此如实
    /// 显示的是「上次成功」的时间，而不是一次失败请求的时间。
    var refreshedAt: Date?

    /// 取某个账号的读数；没查过时给「未配置」而不是失败态。
    subscript(account: UUID) -> NewAPIAccountReading {
        readings[account] ?? NewAPIAccountReading()
    }

    /// 本轮有没有哪个槽位**真的取到了新数值**：`.value` 是新取到的，而 `.failed` 里带的
    /// 是上一轮的旧值（不算）。页眉据此决定要不要推进「更新于」——本轮全失败时时间戳
    /// 必须停在「上次成功」，否则用户会以为数字是刚拉的。
    var hasFreshValue: Bool {
        readings.values.contains { reading in
            if case .value = reading.account { return true }
            if case .value = reading.key { return true }
            return false
        }
    }
}
