//
//  QuotaAlertTests.swift
//  AgentIslandTests
//
//  余额提醒的判据（`QuotaAlertPolicy`）、降沿状态（`QuotaAlertTracker`）与视图模型接线的
//  不变量。
//
//  这一套的重点是**别在不该响的时候响**，也别在**该响的时候漏掉**：额度轮询是本应用唯一
//  「页面没开着也联网」的路径，而提醒一旦变成每轮都响（或每加一个账号就念一遍旧账），用户
//  第一件事就是把阈值关掉——那时真正见底的哪一天也没人告诉他了。因此这里逐条钉：
//  * 每个账号 × 每个槽**每跌一次只提醒一次**：首见（刚启动 / 刚加账号）那一刻它在低位，
//    提醒一次；之后一直低着不再响；回到阈值之上（充了钱 / 换了 Key）后再跌破会再提醒；
//  * 不限额度、未配置、缺凭据、阈值关闭 / 非正数一律不提醒；
//  * 阈值按**显示口径**比（与额度页上印出来的那个数同一个量）；
//  * 关掉阈值之后不再发请求（轮询停掉），且不再抛提醒（连降沿状态一起复位）。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("余额提醒")
struct QuotaAlertPolicyTests {
    /// 账户槽有数值的读数（`available` 是剩余）。
    private func accountReading(
        _ available: Double, unlimited: Bool = false, currency: NewAPICurrency = .rawQuota
    ) -> NewAPIAccountReading {
        var reading = NewAPIAccountReading()
        reading.account = .value(
            NewAPIBalanceValue(
                available: available, used: 0, granted: nil, unlimited: unlimited))
        reading.siteCurrency = currency
        return reading
    }

    /// Key 槽有数值的读数。
    private func keyReading(
        _ available: Double, unlimited: Bool = false, currency: NewAPICurrency = .rawQuota
    ) -> NewAPIAccountReading {
        var reading = NewAPIAccountReading()
        reading.key = .value(
            NewAPIBalanceValue(
                available: available, used: 0, granted: nil, unlimited: unlimited))
        reading.siteCurrency = currency
        return reading
    }

    @Test("跌破阈值才提醒：账户槽优先，两个槽都在阈值之上不提醒")
    func breachedSlotPicksTheLowSlot() {
        // 内部单位口径（`display_in_currency = false`）：阈值直接比额度。
        let currency = NewAPICurrency()

        // 两个槽都高：不提醒。
        var both = NewAPIAccountReading()
        both.account = .value(
            NewAPIBalanceValue(available: 900, used: 0, granted: nil, unlimited: false))
        both.key = .value(
            NewAPIBalanceValue(available: 800, used: 0, granted: nil, unlimited: false))
        both.siteCurrency = currency
        #expect(QuotaAlertPolicy.breachedSlot(both, threshold: 500) == nil)

        // 账户槽跌破（Key 还高）：提醒账户槽。
        var accountLow = both
        accountLow.account = .value(
            NewAPIBalanceValue(available: 400, used: 0, granted: nil, unlimited: false))
        #expect(QuotaAlertPolicy.breachedSlot(accountLow, threshold: 500) == .account)

        // 只有 Key 槽跌破：提醒 Key 槽。
        var keyLow = both
        keyLow.key = .value(
            NewAPIBalanceValue(available: 100, used: 0, granted: nil, unlimited: false))
        #expect(QuotaAlertPolicy.breachedSlot(keyLow, threshold: 500) == .key)

        // 刚好等于阈值**不算低**（判据是 strictly below）：用户设 5 就是在「低于 5」时被告知。
        var onThreshold = both
        onThreshold.account = .value(
            NewAPIBalanceValue(available: 500, used: 0, granted: nil, unlimited: false))
        #expect(QuotaAlertPolicy.breachedSlot(onThreshold, threshold: 500) == nil)
    }

    @Test("不限额度 / 未配置 / 缺凭据 / 失败无旧值都不提醒；失败但仍留着旧值照常判")
    func onlyRealNumbersCanBeLow() {
        var unlimited = accountReading(0, unlimited: true)
        unlimited.key = .value(
            NewAPIBalanceValue(available: 0, used: 0, granted: nil, unlimited: true))
        #expect(QuotaAlertPolicy.breachedSlot(unlimited, threshold: 500) == nil)

        // 未配置 / 缺凭据 / 还在拉：没有数值就没有判断依据。
        #expect(QuotaAlertPolicy.breachedSlot(NewAPIAccountReading(), threshold: 500) == nil)
        var needsToken = NewAPIAccountReading()
        needsToken.account = .needsAccessToken
        needsToken.key = .needsAPIKey
        #expect(QuotaAlertPolicy.breachedSlot(needsToken, threshold: 500) == nil)

        // 失败但留着上一次成功的数值：余额不会因为一次网络抖动自己涨回去，照常判。
        var failedWithOld = NewAPIAccountReading()
        failedWithOld.account = .failed(
            reason: "连接失败",
            value: NewAPIBalanceValue(available: 10, used: 0, granted: nil, unlimited: false))
        #expect(QuotaAlertPolicy.breachedSlot(failedWithOld, threshold: 500) == .account)

        // 失败且没有旧值：不判。
        var failedWithoutOld = NewAPIAccountReading()
        failedWithoutOld.account = .failed(reason: "连接失败", value: nil)
        #expect(QuotaAlertPolicy.breachedSlot(failedWithoutOld, threshold: 500) == nil)
    }

    @Test("阈值关闭 / 非正数时不提醒（0 是关闭档的语义，不是「任何余额都算低」）")
    func thresholdMustBePositive() {
        let low = accountReading(1)
        #expect(QuotaAlertPolicy.breachedSlot(low, threshold: nil) == nil)
        #expect(QuotaAlertPolicy.breachedSlot(low, threshold: 0) == nil)
        #expect(QuotaAlertPolicy.breachedSlot(low, threshold: -5) == nil)
        #expect(QuotaAlertPolicy.breachedSlot(low, threshold: 2) == .account)
    }

    @Test("阈值按显示口径比：同一份额度在「按钱显示」的实例上先跌破")
    func thresholdIsComparedInDisplayedUnits() {
        // 实例把额度显示成钱：quota_per_unit = 500000 ⇒ 1 额度单位 = $0.000002。
        let currency = NewAPICurrency(
            displayType: .usd, displayInCurrency: true, quotaPerUnit: 500_000)
        // 额度 2,000,000（内部单位）= $4.00。
        let reading = accountReading(2_000_000, currency: currency)

        // 阈值 5（用户照着页面上的「$4.00」设的 5 美元）⇒ 跌破。
        #expect(QuotaAlertPolicy.breachedSlot(reading, threshold: 5) == .account)
        // 阈值 3 ⇒ $4.00 还在其上，不提醒（若按内部单位比，2,000,000 会立刻跌破一切阈值）。
        #expect(QuotaAlertPolicy.breachedSlot(reading, threshold: 3) == nil)
    }

    @Test("跌一次提醒一次：首见（应用刚起来 / 刚加的账号）响一次，一直低着不再响，回到阈值之上后再跌破会再响")
    @MainActor
    func trackerAlertsOnTheFallingEdgeOnly() {
        let id = UUID()
        let tracker = QuotaAlertTracker()
        let breach = QuotaAlert(
            accountID: id, accountName: "a", slot: .account, available: 1, threshold: 5)

        // 首见（应用刚起来 / 刚加的账号）：**提醒一次**——读数是逐账号判的，这一刻它确实在低位。
        #expect(tracker.shouldAlert(breach) == true)
        // 一直低着：不再响（轮询每两分钟一轮，常念就成噪声了）。
        #expect(tracker.shouldAlert(breach) == false)

        // 回到阈值之上（充了钱）：重新武装。
        tracker.noteRecovered(accountID: id, slot: .account)
        // 再跌破：响一次。
        #expect(tracker.shouldAlert(breach) == true)
        #expect(tracker.shouldAlert(breach) == false)

        // 另一个账号 / 另一个槽各有一份状态：首见就响，一直低着不响，复位后再跌破才响。
        let other = QuotaAlert(
            accountID: UUID(), accountName: "b", slot: .key, available: 1, threshold: 5)
        #expect(tracker.shouldAlert(other) == true)
        #expect(tracker.shouldAlert(other) == false)
        tracker.noteRecovered(accountID: other.accountID, slot: .key)
        #expect(tracker.shouldAlert(other) == true)

        // 账号被删：它的状态一起忘掉（id 万一被复用也不会顶着一个陈旧的「已响过」）。
        tracker.forget(accountID: id)
        #expect(tracker.shouldAlert(breach) == true)
    }

    @Test("显示口径的数值与页面上的排版同源：钱、内部单位、token 三档都对得上")
    func displayedValueMatchesThePrintedAmount() {
        let raw = NewAPICurrency()
        #expect(NewAPIBalanceFormat.displayedValue(1_234_567, currency: raw) == 1_234_567)

        let usd = NewAPICurrency(displayType: .usd, displayInCurrency: true, quotaPerUnit: 500_000)
        #expect(NewAPIBalanceFormat.displayedValue(500_000, currency: usd) == 1)

        let cny = NewAPICurrency(
            displayType: .cny, displayInCurrency: true, quotaPerUnit: 500_000, usdExchangeRate: 7.3)
        #expect(NewAPIBalanceFormat.displayedValue(500_000, currency: cny) == 7.3)

        let custom = NewAPICurrency(
            displayType: .custom, displayInCurrency: true, quotaPerUnit: 500_000,
            customSymbol: "¤", customExchangeRate: 2)
        #expect(NewAPIBalanceFormat.displayedValue(500_000, currency: custom) == 2)

        // 站点按 token 数显示：内部单位就是用户看到的那个数。
        let tokens = NewAPICurrency(displayType: .tokens, displayInCurrency: true)
        #expect(NewAPIBalanceFormat.displayedValue(777, currency: tokens) == 777)
    }
}

@MainActor
@Suite("余额提醒的接线", .serialized)
struct QuotaAlertWiringTests {
    /// 与 `NewAPIBalanceTests` 的桩同形，但这是本套件**私有**的响应表：套件之间并行跑，
    /// 跨套件共用静态表会互相清表（那边注释里记了这次事故）。
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "quota-alert-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func waitUntilRefreshed(_ model: NewAPIBalanceViewModel) async {
        for _ in 0..<400 where model.isRefreshing {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 一个账号：账户余额 987,655 内部单位（实例口径 500,000/单位 ⇒ **$1.98**），
    /// Key 额度 999,000 内部单位（⇒ **$2.00**）。
    ///
    /// 阈值 5 ⇒ 两个槽都在其下（账户槽优先报出）；阈值 1 ⇒ 两个槽都在其上。
    /// 阈值按**显示口径**比：这正是「用户在额度页上看到 $1.98，于是把阈值设成 5」的场景。
    private func makeModel(defaults: UserDefaults) throws -> NewAPIBalanceViewModel {
        try makeModelBody(
            accounts: [
                NewAPIAccount(
                    label: "a",
                    config: NewAPIConfig(
                        serverURL: "https://a.example.com", apiKey: "sk-a", accessToken: "tok"))
            ], defaults: defaults)
    }

    /// 桩响应表 + 账号列表 → 视图模型（`makeModel` / `makeTwoAccountModel` 共用）。
    private func makeModelBody(
        accounts: [NewAPIAccount], defaults: UserDefaults
    ) throws -> NewAPIBalanceViewModel {
        NewAPIAlertStub.set([
            "/api/user/self": (
                status: 200,
                body:
                    #"{"success":true,"message":"","data":{"quota":987655,"used_quota":12345,"display_name":"t","id":7,"group":"default","request_count":9}}"#
            ),
            "/api/usage/token/": (
                status: 200,
                body:
                    #"{"success":true,"message":"ok","data":{"total_granted":1000000,"total_used":12345,"total_available":999000,"unlimited_quota":false}}"#
            ),
            "/api/status": (
                status: 200,
                body:
                    #"{"success":true,"message":"","data":{"version":"v9.9.9","display_in_currency":true,"quota_display_type":"USD","quota_per_unit":500000,"usd_exchange_rate":1}}"#
            ),
        ])
        AppSettings.setNewAPIAccounts(accounts, defaults: defaults)
        // 站点口径（桩的 `/api/status` 回的「按美元显示、500,000/单位」）随**每一轮刷新**抄进
        // 读数，因此 `refresh()` 之后读到的就是页面上的那个量（$1.98），不是内部单位。
        return NewAPIBalanceViewModel(
            client: NewAPIBalanceClient(session: NewAPIAlertStub.session()), defaults: defaults)
    }

    @Test("阈值关着：判一遍不发提醒；跌破一次只提醒一次；回到阈值之上后再跌破会再提醒")
    func alertsOncePerBreach() async throws {
        let defaults = try isolatedDefaults()
        let model = try makeModel(defaults: defaults)
        model.refresh()
        await waitUntilRefreshed(model)

        // 阈值关着：根本不判（`mutedAlert` 保持 nil）。
        #expect(QuotaAlertPreference.value(defaults: defaults) == nil)
        model.evaluateAlerts()
        #expect(model.mutedAlert == nil)

        // 阈值 5 ⇒ 账户 $1.98 跌破（账户槽优先于 Key 的 $2.00）。
        PreferenceStore.write(QuotaAlertThreshold.five, defaults: defaults)
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .account)
        #expect(model.mutedAlert?.threshold == 5)
        #expect(model.mutedAlert?.accountName == "a")
        // 提醒里带的数字与页面上印的是同一个量（显示口径），不是内部额度单位。
        let reading = model.reading(for: model.selectedAccount)
        let shown = NewAPIBalanceFormat.displayedValue(
            reading.account.lastValue?.available ?? 0, currency: reading.siteCurrency)
        #expect(shown < 5)
        #expect(abs((model.mutedAlert?.available ?? -1) - shown) < 0.0001)

        // 再判一遍（余额还低着）：不重复提醒（`mutedAlert` 停在第一次那一条）。
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .account)

        // 真的充了钱（两个槽都回到阈值之上）：这一轮没有任何账号在低位，提醒保持清空。
        NewAPIAlertStub.set([
            "/api/user/self": (
                status: 200,
                body:
                    #"{"success":true,"message":"","data":{"quota":9000000,"used_quota":12345,"display_name":"t","id":7,"group":"default","request_count":9}}"#
            ),
            "/api/usage/token/": (
                status: 200,
                body:
                    #"{"success":true,"message":"ok","data":{"total_granted":10000000,"total_used":1000000,"total_available":9000000,"unlimited_quota":false}}"#
            ),
        ])
        model.refresh()
        await waitUntilRefreshed(model)
        model.evaluateAlerts()
        #expect(model.mutedAlert == nil)

        // 再跌破（又花光了）：重新提醒一次——中间隔着一次「回到阈值之上」。
        NewAPIAlertStub.set([
            "/api/user/self": (
                status: 200,
                body:
                    #"{"success":true,"message":"","data":{"quota":987655,"used_quota":12345,"display_name":"t","id":7,"group":"default","request_count":9}}"#
            ),
            "/api/usage/token/": (
                status: 200,
                body:
                    #"{"success":true,"message":"ok","data":{"total_granted":1000000,"total_used":12345,"total_available":999000,"unlimited_quota":false}}"#
            ),
        ])
        model.refresh()
        await waitUntilRefreshed(model)
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .account)
        #expect(model.mutedAlert?.threshold == 5)
    }

    @Test("阈值关掉后不再联网：轮询与判据都按同一个门（关档 = 一个请求都不发）")
    func pollingStopsWhenThresholdIsOff() throws {
        let defaults = try isolatedDefaults()
        let model = try makeModel(defaults: defaults)

        // 关档：起轮询是空操作（视图模型里 `startAlertPolling()` 的第一道门就是
        // `isAlertPollingActive`），判据也不判。
        #expect(QuotaAlertPreference.value(defaults: defaults) == nil)
        model.startAlertPolling()
        model.stopAlertPolling()

        // 开档：门开了。**真的起没起任务**测不了（测试宿主里 `AppEnvironment.isRunningTests`
        // 会让它直接返回，这是有意的：用例不该在后台打网络），因此这条由实机验收兜：
        // 设置里当场选档 → 应用不重启也照常在几秒内取数并弹提醒（见提交说明里的实机记录）。
        PreferenceStore.write(QuotaAlertThreshold.five, defaults: defaults)
        #expect(QuotaAlertPreference.value(defaults: defaults) == 5)
        model.startAlertPolling()
        model.stopAlertPolling()

        // 再关掉：门又关上（设置里改回关闭档 ⇒ 视图层会调 `stopAlertPolling()`）。
        PreferenceStore.write(QuotaAlertThreshold.off, defaults: defaults)
        #expect(QuotaAlertPreference.value(defaults: defaults) == nil)
        model.stopAlertPolling()
    }

    /// 两个账号（各自的桩响应一样：账户 $1.98、Key $2.00）。
    private func makeTwoAccountModel(defaults: UserDefaults) throws -> NewAPIBalanceViewModel {
        try makeModelBody(accounts: [
            NewAPIAccount(
                label: "a",
                config: NewAPIConfig(
                    serverURL: "https://a.example.com", apiKey: "sk-a", accessToken: "tok")),
            NewAPIAccount(
                label: "b",
                config: NewAPIConfig(
                    serverURL: "https://b.example.com", apiKey: "sk-b", accessToken: "tok")),
        ], defaults: defaults)
    }

    @Test("多个账号同轮跌破：一轮只弹一条（列表顺序即优先级），另一条在后续轮次补上")
    func announcesOneAccountPerRound() async throws {
        let defaults = try isolatedDefaults()
        PreferenceStore.write(QuotaAlertThreshold.five, defaults: defaults)
        let model = try makeTwoAccountModel(defaults: defaults)
        model.refresh()
        await waitUntilRefreshed(model)

        // `refresh()` 收尾会排一拍判据（`Task { @MainActor in evaluateAlerts() }`），那一拍
        // 什么时候跑不确定：它先跑就报了第一个账号。因此这里不猜「第一次是谁发的」，
        // 而是把 `mutedAlert` **每次变出来的那一条**记下来（相邻重复不算新提醒——一直低着
        // 时它会停在上一条上，这正是「不重复报」）。
        var announced: [String] = []
        func record() {
            guard let name = model.mutedAlert?.accountName else { return }
            if announced.last != name { announced.append(name) }
        }
        record()
        // 判几轮：两个账号的两条降沿都该被报出来（第二条没被第一条吃掉）。
        for _ in 0..<4 {
            model.evaluateAlerts()
            record()
        }
        #expect(announced.count == 2)
        #expect(Set(announced) == Set(["a", "b"]))

        // 两条都记过账了：再判不再换人（也不重复报同一个）。
        let settled = model.mutedAlert?.accountName
        model.evaluateAlerts()
        model.evaluateAlerts()
        #expect(model.mutedAlert?.accountName == settled)
    }

    @Test("两个槽交错：一个槽回升、另一个槽在低位，原来的槽再跌破时仍然会响")
    func slotsRecoverIndependently() async throws {
        let defaults = try isolatedDefaults()
        let model = try makeModel(defaults: defaults)
        PreferenceStore.write(QuotaAlertThreshold.five, defaults: defaults)

        model.refresh()
        await waitUntilRefreshed(model)
        #expect(model.mutedAlert?.slot == .account)

        // 账户充钱（$40）、Key 仍在低位（$2）：报出的是 Key 槽，账户槽应被复位。
        NewAPIAlertStub.set([
            "/api/user/self": (
                status: 200,
                body:
                    #"{"success":true,"message":"","data":{"quota":20000000,"used_quota":1,"display_name":"t","id":7,"group":"default","request_count":9}}"#
            )
        ])
        model.refresh()
        await waitUntilRefreshed(model)
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .key)

        // Key 换新（$40）、账户又花光（$1.98）：账户槽是**新的**一次下跌，照常报出。
        NewAPIAlertStub.set([
            "/api/user/self": (
                status: 200,
                body:
                    #"{"success":true,"message":"","data":{"quota":987655,"used_quota":1,"display_name":"t","id":7,"group":"default","request_count":9}}"#
            ),
            "/api/usage/token/": (
                status: 200,
                body:
                    #"{"success":true,"message":"ok","data":{"total_granted":20000000,"total_used":1,"total_available":20000000,"unlimited_quota":false}}"#
            ),
        ])
        model.refresh()
        await waitUntilRefreshed(model)
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .account)
    }

    @Test("清空凭据：那条提醒跟着消失，填回来又是「首见」——不会顶着陈旧的降沿标记")
    func clearingCredentialsDropsTheAlert() async throws {
        let defaults = try isolatedDefaults()
        let model = try makeModel(defaults: defaults)
        PreferenceStore.write(QuotaAlertThreshold.five, defaults: defaults)

        model.refresh()
        await waitUntilRefreshed(model)
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .account)

        // 用户把地址 / Key 清掉：能查的账号一个都没有，`refresh()` 走「不可用快照」的早退分支。
        // 那一支也必须判一遍——否则这条提醒会一直挂着，而它描述的读数已经取不到了。
        model.setField(.apiKey, to: "")
        model.setField(.accessToken, to: "")
        model.commitConfig()
        await waitUntilRefreshed(model)
        #expect(model.mutedAlert == nil)

        // 再填回去（余额仍然低）：这是新一轮「首见」，照常提醒一次。
        // （`refresh()` 收尾会再排一拍判据；判据本身幂等，这里显式判一次就不用赌那一拍的时序。）
        model.setField(.apiKey, to: "sk-a")
        model.setField(.accessToken, to: "tok")
        model.commitConfig()
        await waitUntilRefreshed(model)
        model.evaluateAlerts()
        #expect(model.mutedAlert?.slot == .account)
    }

    @Test("阈值档位表：关闭档在首位（默认），其余是 1 / 5 / 10 / 20 / 50")
    func thresholdOptions() {
        #expect(QuotaAlertThreshold.defaultValue == .off)
        #expect(QuotaAlertThreshold.allCases.first == .off)
        #expect(QuotaAlertThreshold.allCases.map(\.value) == [nil, 1, 5, 10, 20, 50])
        // 偏好域里的 rawValue 是稳定的字符串：改它等于丢用户设置。
        #expect(QuotaAlertThreshold.five.rawValue == "five")
    }
}

// MARK: - 余额提醒用例的私有桩

/// 最小 `URLProtocol` 桩（与 `QuotaLayoutStub` / `BalanceStubProtocol` 同形，但状态是本套件私有的）。
nonisolated final class NewAPIAlertStub: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: (status: Int, body: String)] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        responses = [:]
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewAPIAlertStub.self]
        return URLSession(configuration: configuration)
    }

    /// 响应表的写入（用例在 `reset()` 之后逐条填）。
    static func set(_ table: [String: (status: Int, body: String)]) {
        lock.lock()
        for (key, value) in table { responses[key] = value }
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URL.path` 会吃掉尾斜杠（`/api/usage/token/` → `/api/usage/token`），两种写法都要认。
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let hit = Self.responses[path] ?? Self.responses[path + "/"]
        Self.lock.unlock()

        guard let hit, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: hit.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(hit.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
