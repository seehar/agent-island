//
//  NewAPIBalanceViewModel.swift
//  AgentIsland
//
//  「额度」页的状态：**账号列表**（可多个 New API 实例 / 账号）、当前选中的账号、
//  各账号两个槽位的读数快照，以及刷新中的标志。视图只读这里，不自己发请求、
//  也不自己拼口径。
//
//  刷新策略：**不轮询**——只有打开「额度」页时才联网（进页 30 秒节流一次 + 手动刷新）。
//  页眉的「更新于 HH:MM」就是快照里的 `refreshedAt`，用户因此知道读数有多新。
//  取数是**所有账号一起**（每账号最多四个 GET）：账号列表里要给每个账号显示余额，
//  只刷新选中的那个会让列表里的其它数字一直停在旧值。
//
//  请求矩阵（都只在页面打开时、30 秒节流一次）：
//  * 每账号：`/api/user/self`（账户余额 + 身份，要访问令牌）、`/api/usage/token/`（Key 额度，
//    要 `sk-`）、`/api/token/`（令牌列表，要访问令牌）、`/api/user/self/groups`（分组倍率，
//    要访问令牌）。
//  * `/api/status`（额度口径 + 实例版本）按 serverURL**去重**：实例级属性，同一台只查一次。
//  * 没填令牌的账号一个请求都不会发（逐槽位门禁，见 `NewAPIConfig`）。
//  * 后三路（令牌、分组、口径）都是**补足信息**：失败一律 fail-soft，保留上一轮的值。
//

import Combine
import Foundation
import os

/// 「额度」页上可编辑的账号字段。
///
/// 视图只按字段名取绑定（`field(_:)` / `setField(_:to:)`），不自己找数组下标——
/// 增删账号时下标会变，而字段名不会。
///
/// `CaseIterable` 且**顺序即凭据表单的行顺序**：视图按 `allCases.count` 推导表单高度，
/// 加字段时版面预算自动跟着长（不必再手工同步一处行数）。
nonisolated enum NewAPIAccountField: Sendable, CaseIterable {
    /// 备注名（显示在账号列表与选择行上）。
    case label
    case serverURL
    case apiKey
    case accessToken
    case userID
}

/// 「额度」页的视图模型。
@MainActor
final class NewAPIBalanceViewModel: ObservableObject {
    /// 取数失败的日志落点：页面上的行会显示原因，这里留给「为什么取不到」的长期排查。
    /// **不打印凭据**（只打主机名、端点代号、错误类型与服务器文案）。
    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Balance")

    // MARK: - 状态

    /// 账号列表（顺序即列表顺序）。**永远至少一个**：页面上的五行输入框画的是选中账号，
    /// 零账号会让版面没有内容、高度解析式也就落空了（删除按钮在只剩一个时禁用）。
    @Published private(set) var accounts: [NewAPIAccount]
    /// 当前选中的账号 id。
    @Published private(set) var selectedAccountID: UUID
    /// 各账号的读数。
    @Published private(set) var snapshot = NewAPIBalanceSnapshot()
    /// 正在拉取：页眉的刷新按钮据此禁用（图标同时降到最弱一级）。
    @Published private(set) var isRefreshing = false

    // MARK: - 依赖

    private let client: NewAPIBalanceClient
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    /// 每次刷新的自增序号：写回快照前必须仍是最新那一次——否则先发出的慢请求会覆盖掉
    /// 「用户改了配置后重新拉」回来的读数（与 `UsageStatsViewModel` 同一套防覆盖手法）。
    private var generation = 0
    /// 进页触发的刷新节流窗口（与统计索引器的 30 秒同口径）。
    private static let refreshThrottle: TimeInterval = 30

    // MARK: - 生命周期

    init(client: NewAPIBalanceClient = NewAPIBalanceClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults

        let stored = AppSettings.newAPIAccounts(defaults: defaults)
        // 空列表（全新安装 / 用户清空过）给一个空账号：页面上永远有账号可编辑。
        let loaded = stored.isEmpty ? [NewAPIAccount()] : stored
        accounts = loaded
        let storedSelection = AppSettings.newAPISelectedAccountID(defaults: defaults)
        if let storedSelection, loaded.contains(where: { $0.id == storedSelection }) {
            selectedAccountID = storedSelection
        } else {
            selectedAccountID = loaded[0].id
        }
    }

    /// 进「额度」页时调用：30 秒内不重复拉；一个能查的账号都没有、或跑在测试宿主里就直接返回。
    func onAppear() {
        guard !AppEnvironment.isRunningTests else { return }
        guard accounts.contains(where: { $0.config.isConfigured }) else { return }
        if let last = snapshot.refreshedAt,
            Date().timeIntervalSince(last) < Self.refreshThrottle
        {
            return
        }
        refresh()
    }

    /// 提交配置（输入框回车）：当前账号的读数作废再重拉——地址或凭据改了，旧数字不再可信。
    ///
    /// 同时在途的那次请求也要作废：它用的是旧配置，回来只会覆盖新读数。
    func commitConfig() {
        refreshTask?.cancel()
        isRefreshing = false
        generation += 1

        var pending = snapshot
        pending.readings[selectedAccountID] = NewAPIAccountReading(account: .loading, key: .loading)
        snapshot = pending
        refresh()
    }

    /// 拉一次全部账号（页眉刷新按钮与 `onAppear` 共用）。已经在拉就忽略。
    func refresh() {
        guard !isRefreshing else { return }
        persist()

        // 一个能查的都没有：不发请求，但每行要说清「缺什么」——只填了地址的用户看到的是
        // 「需要 API Key / 需要访问令牌」，而不是笼统的「未配置」。
        guard accounts.contains(where: { $0.config.isConfigured }) else {
            snapshot = Self.unavailableSnapshot(for: accounts)
            return
        }

        generation += 1
        let generation = generation
        var pending = snapshot
        // 还没读过数的账号先给「正在拉取」：首次打开页面时不会先闪一下「未配置」。
        for account in accounts where pending.readings[account.id] == nil {
            pending.readings[account.id] = Self.pendingReading(for: account.config)
        }
        let previous = pending
        let accounts = accounts
        snapshot = pending
        isRefreshing = true
        let client = client

        refreshTask = Task { [weak self] in
            // 先取实例级的公开设置（`/api/status`：额度显示口径 + 版本）。这是**实例级**
            // 属性，按服务器去重、每台只查一次；余额本身与它无关，因此取不到就保留这个账号
            // 上一次已知的值，不当作失败。
            var configByServer: [String: NewAPIConfig] = [:]
            for account in accounts where account.config.isConfigured {
                configByServer[Self.serverKey(account.config)] = account.config
            }
            var statuses: [String: NewAPISiteStatus] = [:]
            await withTaskGroup(of: (String, NewAPISiteStatus?).self) { group in
                for (server, config) in configByServer {
                    group.addTask { (server, try? await client.siteStatus(config)) }
                }
                for await (server, status) in group {
                    if let status { statuses[server] = status }
                }
            }

            var readings: [UUID: NewAPIAccountReading] = [:]
            await withTaskGroup(of: (UUID, NewAPIAccountReading).self) { group in
                for account in accounts {
                    let config = account.config
                    let carried = previous[account.id]
                    group.addTask {
                        var reading = await Self.read(
                            config: config, previous: carried, client: client)
                        let status = statuses[Self.serverKey(config)]
                        reading.siteCurrency = status?.currency ?? carried.siteCurrency
                        reading.siteVersion = status?.version ?? carried.siteVersion
                        return (account.id, reading)
                    }
                }
                for await (id, reading) in group { readings[id] = reading }
            }

            guard let self, self.generation == generation else { return }
            for (index, account) in accounts.enumerated() {
                let reading = readings[account.id]
                // 页面上的行会显示原因；日志只补一层「哪个账号、哪个槽位」，方便用户回头查。
                // 账号名取**解析得出的主机名**，解析不出来就退回序号：地址框里可能是用户
                // 粘错的任意内容（甚至凭据），日志是 public 的，绝不能原样透出。
                let host = URL(string: account.config.trimmedServerURL)?.host() ?? ""
                let name = host.isEmpty ? "账号 \(index + 1)" : host
                if case .failed(let reason, _) = reading?.key {
                    Self.logger.warning(
                        "额度取数失败（\(name, privacy: .public) key）：\(reason, privacy: .public)")
                }
                if case .failed(let reason, _) = reading?.account {
                    Self.logger.warning(
                        "额度取数失败（\(name, privacy: .public) account）：\(reason, privacy: .public)")
                }
            }

            // 取数期间被删掉的账号不写回（它的 id 已经不在列表里）。
            let liveIDs = Set(self.accounts.map(\.id))
            var next = self.snapshot
            next.readings = readings.filter { liveIDs.contains($0.key) }
            // 全部失败时保留上一次成功的时间：页眉显示的是「上次成功」，不是一次失败请求的时间。
            next.refreshedAt = next.hasFreshValue ? Date() : previous.refreshedAt
            self.snapshot = next
            self.isRefreshing = false
        }
    }

    // MARK: - 账号

    /// 当前选中的账号（下标落到列表之外时回落第一个）。
    var selectedAccount: NewAPIAccount { accounts[selectedIndex] }

    /// 只剩一个账号时不给删：页面上永远留着一个可编辑的账号（见 `accounts`）。
    var canRemoveSelectedAccount: Bool { accounts.count > 1 }

    /// 某个账号的读数；没查过时是「未配置」。
    func reading(for account: NewAPIAccount) -> NewAPIAccountReading {
        snapshot[account.id]
    }

    /// 当前选中账号的读数。
    var selectedReading: NewAPIAccountReading { snapshot[selectedAccountID] }

    func selectAccount(_ id: UUID) {
        guard id != selectedAccountID, accounts.contains(where: { $0.id == id }) else { return }
        selectedAccountID = id
        AppSettings.setNewAPISelectedAccountID(id, defaults: defaults)
    }

    /// 新增一个空账号并选中它：页面随即切到它的输入框，填完回车即可取数。
    func addAccount() {
        let account = NewAPIAccount()
        accounts = accounts + [account]
        selectedAccountID = account.id
        persist()
    }

    /// 删掉当前选中的账号；只剩一个时不动。
    func removeSelectedAccount() {
        guard canRemoveSelectedAccount else { return }
        let removed = selectedAccountID
        accounts = accounts.filter { $0.id != removed }
        selectedAccountID = accounts[0].id

        var next = snapshot
        next.readings.removeValue(forKey: removed)
        snapshot = next
        persist()
    }

    // MARK: - 字段读写（输入框绑定）

    /// 当前选中账号的某个字段。
    func field(_ field: NewAPIAccountField) -> String {
        let account = selectedAccount
        switch field {
        case .label: return account.label
        case .serverURL: return account.config.serverURL
        case .apiKey: return account.config.apiKey
        case .accessToken: return account.config.accessToken
        case .userID: return account.config.userID
        }
    }

    /// 写某个字段（输入框每敲一下都会走到这里）并落盘。
    ///
    /// 每次按键就写偏好域，而不是等回车：用户填了地址/令牌却直接点走（没按回车）时，
    /// 关掉面板再进来不该看到空框。取数仍由回车 / 刷新触发，打字不会连打网络。
    func setField(_ field: NewAPIAccountField, to value: String) {
        let index = selectedIndex
        var updated = accounts
        switch field {
        case .label: updated[index].label = value
        case .serverURL: updated[index].config.serverURL = value
        case .apiKey: updated[index].config.apiKey = value
        case .accessToken: updated[index].config.accessToken = value
        case .userID: updated[index].config.userID = value
        }
        guard updated[index] != accounts[index] else { return }
        accounts = updated
        persist()
    }

    // MARK: - 私有

    private var selectedIndex: Int {
        accounts.firstIndex { $0.id == selectedAccountID } ?? 0
    }

    /// 实例级属性的去重键：与客户端拼端点时同一套归一（去空白 + 去尾斜杠）。
    ///
    /// 不归一的话，`https://h` 与 `https://h/` 会被当成两台实例 ⇒ `/api/status` 多打一次，
    /// 而它们其实是同一台（客户端拼端点时也把尾斜杠去掉）。**构建与查表必须用同一个键**，
    /// 否则归一过的那批账号反而查不到刚取回来的口径。
    private nonisolated static func serverKey(_ config: NewAPIConfig) -> String {
        var server = config.trimmedServerURL
        while server.hasSuffix("/") { server.removeLast() }
        return server
    }

    /// 把账号列表与选中账号写回偏好域。
    private func persist() {
        AppSettings.setNewAPIAccounts(accounts, defaults: defaults)
        AppSettings.setNewAPISelectedAccountID(selectedAccountID, defaults: defaults)
    }

    /// 还没读过数时的占位：能查的槽先给「正在拉取」，缺凭据的槽如实说缺什么。
    ///
    /// `?? .loading` 是防御性兜底（调用点保证至少有一个槽能查时才会走到这里）。
    ///
    /// 非 `private`：用例直接钉住「缺凭据的槽在起手占位里就说缺什么，而不是先显示
    /// 『加载中…』到本轮结束」（那个槽根本没发请求）。
    nonisolated static func pendingReading(for config: NewAPIConfig) -> NewAPIAccountReading {
        NewAPIAccountReading(
            account: NewAPISlot.account.missing(in: config) ?? .loading,
            key: NewAPISlot.key.missing(in: config) ?? .loading)
    }

    /// 一个能查的账号都没有时的读数：每个槽位写清「缺什么」。
    ///
    /// `?? .notConfigured` 同样是防御性兜底（这个分支里没有任何槽能查，`missing` 必非 nil）。
    private nonisolated static func unavailableSnapshot(
        for accounts: [NewAPIAccount]
    ) -> NewAPIBalanceSnapshot {
        var readings: [UUID: NewAPIAccountReading] = [:]
        for account in accounts {
            readings[account.id] = NewAPIAccountReading(
                account: NewAPISlot.account.missing(in: account.config) ?? .notConfigured,
                key: NewAPISlot.key.missing(in: account.config) ?? .notConfigured)
        }
        return NewAPIBalanceSnapshot(readings: readings, refreshedAt: nil)
    }

    /// 拉一个账号的取数：两个槽位，加上由账户身份派生的「分组倍率」与「令牌」两路。
    ///
    /// 四路互不影响：一个失败（或缺凭据）不该影响别的读数。两个槽位之外的都只是**补足
    /// 信息**（详情卡用），失败一律 fail-soft：保留上一轮的值，绝不把余额标成失败。
    private nonisolated static func read(
        config: NewAPIConfig,
        previous: NewAPIAccountReading,
        client: NewAPIBalanceClient
    ) async -> NewAPIAccountReading {
        async let account = reading(
            previous: previous.account,
            missing: NewAPISlot.account.missing(in: config),
            value: { payload in payload.value }
        ) {
            try await client.accountUsage(config)
        }
        async let key = reading(
            previous: previous.key,
            missing: NewAPISlot.key.missing(in: config),
            value: { value in value }
        ) {
            try await client.keyUsage(config)
        }
        let (accountSlot, keySlot) = await (account, key)

        var reading = NewAPIAccountReading(account: accountSlot.reading, key: keySlot.reading)
        // 身份也 fail-soft：本轮没拿到（网络失败）时保留上一轮已知的。
        reading.identity = accountSlot.fetched?.identity ?? previous.identity

        // 分组与令牌都要访问令牌（两路都从账户端点的身份来），因此只在**本轮真的拿到身份**
        // 时才发；两路并发，且都允许失败（老实例根本没有这两个端点，404 是常态）。
        if let identity = accountSlot.fetched?.identity {
            async let groups = try? await client.userGroups(config)
            async let tokens = try? await client.tokenItems(config)
            let (fetchedGroups, fetchedTokens) = await (groups, tokens)
            // 取不到（404 / 网络失败）→ 保留上一轮的值；取到了但表里没有对应项
            // （分组表里没这个分组、列表里没这条 `sk-`）→ 如实置空，别把旧值当现值。
            if let fetchedGroups {
                reading.groupRatio = fetchedGroups[identity.group]
            } else {
                reading.groupRatio = previous.groupRatio
            }
            if let fetchedTokens {
                reading.token = fetchedTokens.first { $0.matches(apiKey: config.trimmedAPIKey) }
            } else {
                reading.token = previous.token
            }
        }
        return reading
    }

    /// 把一个可能抛错的取数操作折成「槽位读数 + 取到的原值」；失败时保留上一次成功的数值。
    ///
    /// `value` 把取到的原值摊成槽位数值（账户端点的原值里还带着身份，见 `read`）；
    /// 返回的 `fetched` 只在成功时有值，缺凭据 / 失败都是 nil。
    ///
    /// `missing` 非空表示这个槽连请求都不该发（缺服务器地址或缺该端点的凭据）——
    /// 那不是失败，页面上要写清缺哪一样。
    private nonisolated static func reading<T: Sendable>(
        previous: NewAPIBalanceReading,
        missing: NewAPIBalanceReading?,
        value: @Sendable (T) -> NewAPIBalanceValue,
        operation: @Sendable () async throws -> T
    ) async -> (reading: NewAPIBalanceReading, fetched: T?) {
        if let missing { return (missing, nil) }
        do {
            let fetched = try await operation()
            return (.value(value(fetched)), fetched)
        } catch let error as NewAPIBalanceError {
            return (.failed(reason: error.reason, value: previous.lastValue), nil)
        } catch {
            return (
                .failed(reason: NewAPIBalanceError.transport.reason, value: previous.lastValue),
                nil
            )
        }
    }
}
