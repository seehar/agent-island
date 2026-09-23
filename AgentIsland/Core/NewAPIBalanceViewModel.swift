//
//  NewAPIBalanceViewModel.swift
//  AgentIsland
//
//  「额度」页的状态：四项配置的文本（绑定到页面上的四个输入框）、两个槽位的读数快照、
//  以及刷新中的标志。视图只读这里，不自己发请求、也不自己拼口径。
//
//  刷新策略：**不轮询**——只有打开「额度」页时才联网（进页 30 秒节流一次 + 手动刷新）。
//  页眉的「更新于 HH:MM」就是快照里的 `refreshedAt`，用户因此知道读数有多新。
//

import Combine
import Foundation
import os

/// 「额度」页的视图模型。
@MainActor
final class NewAPIBalanceViewModel: ObservableObject {
    /// 取数失败的日志落点：页面上的行会显示原因，这里留给「为什么取不到」的长期排查。
    /// **不打印凭据**（只打端点代号、错误类型与服务器文案）。
    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Balance")

    // MARK: - 状态

    @Published private(set) var snapshot = NewAPIBalanceSnapshot()
    /// 正在拉取：页眉的刷新按钮据此禁用（图标同时降到最弱一级）。
    @Published private(set) var isRefreshing = false

    /// 四个输入框的绑定源。回车（或点刷新）时写回偏好域。
    @Published var serverURL: String
    @Published var apiKey: String
    @Published var accessToken: String
    @Published var userID: String

    // MARK: - 依赖

    private let client: NewAPIBalanceClient
    private var refreshTask: Task<Void, Never>?
    /// 每次刷新的自增序号：写回快照前必须仍是最新那一次——否则先发出的慢请求会覆盖掉
    /// 「用户改了配置后重新拉」回来的读数（与 `UsageStatsViewModel` 同一套防覆盖手法）。
    private var generation = 0
    /// 进页触发的刷新节流窗口（与统计索引器的 30 秒同口径）。
    private static let refreshThrottle: TimeInterval = 30

    // MARK: - 生命周期

    init(client: NewAPIBalanceClient = NewAPIBalanceClient()) {
        self.client = client
        serverURL = AppSettings.newAPIServerURL
        apiKey = AppSettings.newAPIKey
        accessToken = AppSettings.newAPIAccessToken
        userID = AppSettings.newAPIUserID
    }

    /// 进「额度」页时调用：30 秒内不重复拉；没配或跑在测试宿主里就直接返回。
    func onAppear() {
        guard !AppEnvironment.isRunningTests else { return }
        guard config().isConfigured else { return }
        if let last = snapshot.refreshedAt,
            Date().timeIntervalSince(last) < Self.refreshThrottle
        {
            return
        }
        refresh()
    }

    /// 提交配置（输入框回车）：清掉旧读数再从新配置拉一次。
    ///
    /// 同时在途的那次请求要作废——它用的是旧配置，回来只会覆盖新读数。
    func commitConfig() {
        refreshTask?.cancel()
        isRefreshing = false
        generation += 1
        snapshot = NewAPIBalanceSnapshot(account: .loading, key: .loading, refreshedAt: nil)
        refresh()
    }

    /// 拉一次（页眉刷新按钮与 `onAppear` 共用）。已经在拉就忽略。
    func refresh() {
        guard !isRefreshing else { return }
        persist()

        let config = config()
        guard config.isConfigured else {
            // 没配就什么都不发：两个槽位回到「未配置」，也不留旧读数（旧读数对不上新配置）。
            snapshot = NewAPIBalanceSnapshot()
            return
        }

        generation += 1
        let generation = generation
        var pending = snapshot
        // 还没读过数的槽位先给「正在拉取」：首次打开页面时不会先闪一下「未配置」。
        if pending.key == .notConfigured { pending.key = .loading }
        if pending.account == .notConfigured { pending.account = .loading }
        snapshot = pending
        let previous = pending
        isRefreshing = true
        let client = client

        refreshTask = Task { [weak self] in
            // 两个端点互不影响：一个失败（或没配访问令牌）不该影响另一个的读数。
            async let key = Self.reading(previous: previous.key, needsAuth: false) {
                try await client.keyUsage(config)
            }
            async let account = Self.reading(
                previous: previous.account, needsAuth: !config.canReadAccount
            ) {
                try await client.accountUsage(config)
            }
            let readings = await (key: key, account: account)

            guard let self, self.generation == generation else { return }
            // 页面上的行会显示原因；日志只补一层「什么时候、哪个槽位」，方便用户回头查。
            if case .failed(let reason, _) = readings.key {
                Self.logger.warning("额度取数失败（key）：\(reason, privacy: .public)")
            }
            if case .failed(let reason, _) = readings.account {
                Self.logger.warning("额度取数失败（account）：\(reason, privacy: .public)")
            }
            self.snapshot = NewAPIBalanceSnapshot(
                account: readings.account,
                key: readings.key,
                // 两个槽位都失败时保留上一次成功的时间：页眉显示的是「上次成功」，不是
                // 一次失败请求的时间。
                refreshedAt: readings.key.lastValue != nil || readings.account.lastValue != nil
                    ? Date() : previous.refreshedAt)
            self.isRefreshing = false
        }
    }

    // MARK: - 私有

    /// 把输入框里的原文写回偏好域。`refresh()` 会先调它：保证「查的」与「存的」一致。
    private func persist() {
        AppSettings.newAPIServerURL = serverURL
        AppSettings.newAPIKey = apiKey
        AppSettings.newAPIAccessToken = accessToken
        AppSettings.newAPIUserID = userID
    }

    private func config() -> NewAPIConfig {
        NewAPIConfig(
            serverURL: serverURL, apiKey: apiKey, accessToken: accessToken, userID: userID)
    }

    /// 把一个可能抛错的取数操作折成一个槽位的读数；失败时保留上一次成功的数值。
    private nonisolated static func reading(
        previous: NewAPIBalanceReading,
        needsAuth: Bool,
        operation: @Sendable () async throws -> NewAPIBalanceValue
    ) async -> NewAPIBalanceReading {
        if needsAuth { return .needsAccessToken }
        do {
            return .value(try await operation())
        } catch let error as NewAPIBalanceError {
            return .failed(reason: error.reason, value: previous.lastValue)
        } catch {
            return .failed(reason: NewAPIBalanceError.transport.reason, value: previous.lastValue)
        }
    }
}
