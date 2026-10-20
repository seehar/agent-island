//
//  QuotaAlertPolicy.swift
//  AgentIsland
//
//  额度提醒的**判断规则**（纯函数 + 纯值）：哪些账号该提醒、提醒里写什么。
//
//  收口在这里的理由与 `QuotaReadingSelection` 相同：这条规则是「额度低于阈值就弹窗」的
//  全部语义（拿哪个槽、按什么判、什么情况闭嘴），要被用例逐条钉住——它一旦悄悄回归，
//  用户看到的是「余额见底了但刘海一声不吭」，而这在界面上没有任何症状。
//
//  四条口径（都是真机上会遇到的形态）：
//  * **只看「剩余」**（`available`），不看「已用」，且按**显示口径的数字**比阈值——阈值是
//    用户在额度页上看到的那个量（见 `QuotaAlertSelector`），两个槽各按自己实例的口径换算。
//  * **不限额度**（`unlimited_quota`）永不提醒。
//  * **阈值必须大于 0**：输入框不会给出负数，但偏好域里的值可能是手改的——0 意味着
//    「任何余额都算低」，那是「留空 = 关闭」的语义，不是提醒。
//  * **跌一次提醒一次**：已经低于阈值的账号在后续一轮里继续低着，不再重复提醒；回到阈值
//    之上后（充了钱 / 换了 Key）再跌破会重新提醒一次（见 `QuotaAlertTracker`）。
//

import Foundation

/// 一个账号该不该提醒、提醒里写什么。
///
/// 纯值类型（`Equatable` / `Sendable`）：视图模型把结果丢给刘海面与提示音，用例直接比对。
nonisolated struct QuotaAlert: Equatable, Sendable {
    /// 触发提醒的账号。
    let accountID: UUID
    /// 账号显示名（备注名 → 主机名 → 「账号 N」；调用方按 `newAPIAccountDisplayName` 算好）。
    let accountName: String
    /// 触发提醒的那个槽。
    let slot: QuotaAlertSlot
    /// 该槽当前的剩余额度（显示口径的数字，与额度页上印的是同一个量）。
    let available: Double
    /// 当前阈值（显示口径的数字）。
    let threshold: Double
}

/// 触发提醒的槽位。
///
/// 一个账号两个槽各要各的凭据（见 `NewAPISlot`），提醒因此要说清是**哪一个**见了底：
/// 只说「额度低」而账号有两个数（账户余额 / 密钥额度），用户不知道该去充哪儿。
nonisolated enum QuotaAlertSlot: Equatable, Sendable {
    /// 账户余额（`/api/user/self` 的 `quota`）。
    case account
    /// 当前 Key 的额度（`/api/usage/token/` 的 `total_available`）。
    case key
}

/// 「哪些账号该提醒」的判据。
nonisolated enum QuotaAlertPolicy {
    /// 阈值之上的槽**算不上低**。
    ///
    /// 两个槽都要看：账户余额低时用户可能要充值，密钥额度低时用户可能要换 Key——两者
    /// 都是「接着用下去会断」的情况。
    ///
    /// - Parameters:
    ///   - reading: 该账号这一轮的读数（两条读数要来自**同一次刷新**，两个槽的显示口径
    ///     因此是同一份实例设置）。
    ///   - threshold: 当前阈值（显示口径的数字）；`nil`（阈值留空）或非正数时一律不提醒。
    /// - Returns: 该提醒的那个槽；不提醒时为 nil。**账户槽优先**——它是页面上的主读数
    ///   （见 `QuotaReadingSelection.primarySlot`），且「充值」是比「换 Key」更常见的动作。
    static func breachedSlot(
        _ reading: NewAPIAccountReading, threshold: Double?
    ) -> QuotaAlertSlot? {
        guard let threshold, threshold > 0 else { return nil }
        let currency = reading.siteCurrency
        if isBelow(reading.account, currency: currency, threshold: threshold) { return .account }
        if isBelow(reading.key, currency: currency, threshold: threshold) { return .key }
        return nil
    }

    /// 某个槽的数值够不够低。
    ///
    /// `.value` 与「失败但留着旧值」都算：余额不会因为一次网络抖动自己涨回去，读数还挂着
    /// 上次的数值时就该照常判断；真正没有数值（未配置 / 缺凭据 / 还在拉）时不判。
    static func isBelow(
        _ reading: NewAPIBalanceReading, currency: NewAPICurrency, threshold: Double
    ) -> Bool {
        guard let value = reading.lastValue else { return false }
        if value.unlimited { return false }
        return NewAPIBalanceFormat.displayedValue(value.available, currency: currency)
            < threshold
    }
}

/// 「这一轮该不该响」的状态机（每个账号 × 每个槽一份），保证**每个账号每跌一次只提醒一次**。
///
/// 不进偏好域：它是运行时状态，重启后重新判断一次是期望行为（重启时余额如果仍然低着，
/// 用户看到的提醒是有信息量的，而不是噪声）。判定完全由纯函数 `shouldAlert` 做，便于用例钉住。
@MainActor
final class QuotaAlertTracker {
    /// 每个账号 × 每个槽上一轮的冷暖：`true` = 上一轮在阈值之下。
    private var armed: [String: Bool] = [:]

    /// 这个槽该不该响。
    ///
    /// 规则：
    ///  * 上一轮就在阈值之下（`true`）：不再提醒——提醒是「跌到低位」这一次事件，不是
    ///    「每一轮都念一遍」（轮询每两分钟一轮，常念就成噪声了）；
    ///  * 上一轮**在阈值之上**（`false`，由 `noteRecovered` 记下）或**还没有记录**
    ///    （应用刚起来 / 刚加的账号）：提醒一次，并把标记置为「已在低位」。
    ///
    /// 「没有记录」也提醒：这是有意的选择——读数是**逐账号**判的，一个账号在读数回来的
    /// 那一刻被观察到跌在阈值之下，用户需要知道。代价是「每次启动 / 每次设上阈值」时，
    /// 已经在低位的账号会各响一次（信息量足够，且之后一直低着就不再响），换掉的是
    /// 「打开了开关却什么都没发生」这种最坏的形态。
    func shouldAlert(_ breach: QuotaAlert) -> Bool {
        let key = "\(breach.accountID.uuidString):\(breach.slot.id)"
        // 一直低着（这一轮和上一轮同样低）：不再提醒；一旦回到阈值之上（`noteRecovered`）
        // 就重新武装，之后再跌破会再响一次。
        guard !(armed[key] ?? false) else { return false }
        armed[key] = true
        return true
    }

    /// 记录「这个槽这一轮在阈值之上」。不提醒，只把标记复位，让它下次跌破时再响一次。
    ///
    /// 复位写成 `false`（「上一轮在阈值之上」）：本规则下它与「没有记录」等价（两者都会在
    /// 跌破时提醒），保留键只是为了让状态表读起来是一张「每个槽上一轮的冷暖」，而不是一张
    /// 「最近谁在低位」的稀疏表——排查时 `armed` 一眼能看出这个槽判过没有。
    func noteRecovered(accountID: UUID, slot: QuotaAlertSlot) {
        armed["\(accountID.uuidString):\(slot.id)"] = false
    }

    /// 账号被删 / 读数清空时忘掉它的状态。
    func forget(accountID: UUID) {
        let prefix = accountID.uuidString + ":"
        armed = armed.filter { !$0.key.hasPrefix(prefix) }
    }

    /// 只给用例用：重置全部状态。
    func reset() {
        armed.removeAll()
    }
}

extension QuotaAlertSlot {
    /// 状态表里的键后缀（与 `QuotaAlertSlot` 的 case 一一对应）。
    var id: String {
        switch self {
        case .account: return "account"
        case .key: return "key"
        }
    }
}
