//
//  UsageStats.swift
//  AgentIsland
//
//  用量统计的值类型：时间窗口、口径与快照形状。口径与各 Agent 记录里的原始
//  字段保持一致，避免同一份数据在不同页面出现两个数：
//    · 总 token = 输入 + 输出 + 缓存读 + 缓存写（omp/pi 的 `totalTokens`
//      就是这四项之和，见 Services/Session/PiTranscriptSchema.swift 的 usage 解析）；
//    · 缓存命中率 = 缓存读 / (输入 + 缓存读 + 缓存写)，即「缓存读取占全部提示词
//      token 的比例」——各家 usage 里 `input` 都不含命中缓存的部分，因此分母要
//      把缓存读/写加回去；
//    · 会话数 = 窗口内有记录的会话去重计数，**不含子代理会话**（子代理的 token
//      仍然计入用量）。
//

import Foundation

/// 统计的时间窗口。七档分两组：
///   · **滚动窗口**（近一天 / 近一周 / 近一月）以「现在」为终点，按整桶往回数，
///     所以桶数与起点都固定（24 / 7 / 30）；
///   · **日历窗口**（今天 / 本周 / 本月）从本地自然日的边界起算，桶数随当前时刻
///     在窗口中的位置变化；末尾是「全部」（不限起点，柱图按 `trendDayLimit` 截断）。
nonisolated enum StatsRange: String, CaseIterable, Identifiable, Sendable {
  /// 最近 24 小时（含当前小时，按整点对齐）。
  case lastDay
  /// 最近 7 天（含今天）。
  case lastWeek
  /// 最近 30 天（含今天）。
  case lastMonth
  /// 今天（本地时区自然日）。
  case today
  /// 本周（起点跟随系统「周起始日」设置）。
  case week
  /// 本月（当月 1 日 00:00 起）。
  case month
  /// 全部历史。
  case all

  var id: String { rawValue }

  /// 范围芯片的显示顺序：今天 / 近 24 小时 / 本周 / 近 7 天 / 本月 / 近 30 天 / 全部
  /// （日历窗口在前、滚动窗口紧随；末尾由视图补一格「自定义…」）。
  /// 视图与布局测试都读这里，排序因此只有一份。
  static let chipOrder: [StatsRange] = [.today, .lastDay, .week, .lastWeek, .month, .lastMonth, .all]

  /// 趋势粒度：一天以内的窗口按小时，其余按天。
  var trendGranularity: TrendGranularity {
    switch self {
    case .lastDay, .today:
      return .hour
    case .lastWeek, .lastMonth, .week, .month, .all:
      return .day
    }
  }

  /// 窗口起点；`nil` 表示不限起点（仅「全部」）。
  ///
  /// 「近 X」的起点落在整桶上（小时窗口对齐到整点、天窗口对齐到零点），因此首桶
  /// 总是完整的——对齐到当前分钟会让柱图多出一根只有半截数据的柱子。
  func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
    switch self {
    case .all:
      return nil
    case .lastDay:
      // 24 个整点桶：首桶是 23 小时前的那一小时。
      return calendar.date(byAdding: .hour, value: -23, to: Self.hourStart(now, calendar: calendar))
    case .lastWeek:
      // 7 个自然日（含今天）：首日是 6 天前。
      return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
    case .lastMonth:
      // 30 个自然日（含今天）：首日是 29 天前。
      return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
    case .today:
      return calendar.startOfDay(for: now)
    case .week:
      return calendar.dateInterval(of: .weekOfYear, for: now)?.start
    case .month:
      return calendar.dateInterval(of: .month, for: now)?.start
    }
  }

  /// 趋势的桶计划（粒度 + 首尾桶）。视图的柱子数就是计划里的桶数。
  ///
  /// 首尾桶都落在粒度边界上；「全部」只回溯 `trendDayLimit` 天（几百根柱子看不出
  /// 形状，更早的数据仍计入总量与各 Agent 拆分，只是不进柱图）。
  func trendPlan(now: Date = Date(), calendar: Calendar = .current) -> TrendPlan {
    let day = calendar.startOfDay(for: now)

    let first: Date
    let last: Date
    switch self {
    case .lastDay:
      // 到当前小时为止的 24 个小时桶：右端跟着时钟走。
      let hour = Self.hourStart(now, calendar: calendar)
      first = calendar.date(byAdding: .hour, value: -23, to: hour) ?? hour
      last = hour
    case .today:
      // 画满一整天（未来的钟点留空柱）：柱子数与横轴两端不随时钟漂移。
      first = day
      last = UsageStatsCalendar.lastHourStart(ofDayStartingAt: day, calendar: calendar)
    case .lastWeek:
      first = calendar.date(byAdding: .day, value: -6, to: day) ?? day
      last = day
    case .lastMonth:
      first = calendar.date(byAdding: .day, value: -29, to: day) ?? day
      last = day
    case .week, .month:
      let windowStart = start(now: now, calendar: calendar) ?? day
      first = calendar.startOfDay(for: windowStart)
      last = day
    case .all:
      first = calendar.date(byAdding: .day, value: -(Self.trendDayLimit - 1), to: day) ?? day
      last = day
    }
    return TrendPlan(granularity: trendGranularity, firstBucket: first, lastBucket: last)
  }

  /// 日粒度柱图最多回溯的天数（含今天）。再往前的数据只有总量与拆分看得到。
  static let trendDayLimit = 60

  /// 当前小时桶的起点。
  private static func hourStart(_ now: Date, calendar: Calendar) -> Date {
    calendar.dateInterval(of: .hour, for: now)?.start ?? now
  }
}

// MARK: - 统计窗口

/// 统计的时间窗口：预设档，或用户自选的起止自然日。
///
/// 自定义窗口的 `from`/`to` 都是本地自然日（`startOfDay`），**含首尾整天**；查询右端
/// 按「次日零点」半开（`hour_key < 次日零点的小时键`），与预设档「只卡左端」等价——
/// 预设档的右端是「现在」，未来的桶本来就没有数据。
nonisolated enum StatsWindow: Equatable, Sendable {
  /// 预设档（近一天 / 近一周 / 近一月 / 今天 / 本周 / 本月 / 全部）。
  case preset(StatsRange)
  /// 用户自选的起止自然日（`from <= to`，由 `UsageStatsCalendar.normalized` 归一）。
  case custom(from: Date, to: Date)

  /// 进曲线图的天粒度桶上限：最多画到「末桶那天往前 366 天」。
  ///
  /// 与 `.all` 的 `trendDayLimit` 同一个语义：更早的数据仍计入总量与各 Agent 拆分，
  /// 只是不进曲线（几百个点挤在 400pt 宽里读不出形状）。
  static let customTrendDayLimit = 366

  /// 预设档对应的枚举值；自选范围给 `nil`。
  var presetRange: StatsRange? {
    if case .preset(let range) = self { return range }
    return nil
  }

  /// 趋势粒度：预设档看自家定义；自选范围按跨度——不超过 2 个自然日按小时，
  /// 否则按天（跨 3 天以上按小时会画出几十上百个桶）。
  func granularity(calendar: Calendar = .current) -> TrendGranularity {
    switch self {
    case .preset(let range):
      return range.trendGranularity
    case .custom(let from, let to):
      return UsageStatsCalendar.dayCount(from: from, to: to, calendar: calendar) <= 2 ? .hour : .day
    }
  }

  /// 窗口的查询边界（本地时区）：`start` 含、`end` 不含；`nil` 表示该侧不限。
  func bounds(now: Date = Date(), calendar: Calendar = .current) -> (start: Date?, end: Date?) {
    switch self {
    case .preset(let range):
      return (range.start(now: now, calendar: calendar), nil)
    case .custom(let from, let to):
      let start = UsageStatsCalendar.startOfDay(from, calendar: calendar)
      let end = calendar.date(
        byAdding: .day, value: 1, to: UsageStatsCalendar.startOfDay(to, calendar: calendar))
      return (start, end)
    }
  }

  /// 边界的小时键（`usage_bucket.hour_key` 的形状）：可直接做 SQL 字符串比较。
  func keyBounds(now: Date = Date(), calendar: Calendar = .current) -> (
    start: String?, end: String?
  ) {
    let bounds = bounds(now: now, calendar: calendar)
    return (
      bounds.start.map { UsageStatsKey.hour(for: $0, calendar: calendar) },
      bounds.end.map { UsageStatsKey.hour(for: $0, calendar: calendar) }
    )
  }

  /// 趋势桶计划：粒度 + 首尾桶（都落在粒度边界上）。
  func trendPlan(now: Date = Date(), calendar: Calendar = .current) -> TrendPlan {
    switch self {
    case .preset(let range):
      return range.trendPlan(now: now, calendar: calendar)
    case .custom(let from, let to):
      let start = UsageStatsCalendar.startOfDay(from, calendar: calendar)
      let end = UsageStatsCalendar.startOfDay(to, calendar: calendar)
      switch granularity(calendar: calendar) {
      case .hour:
        // 范围是按天选的，因此小时粒度要覆盖**整个末日**（含当地最后那一个小时）。
        let last = UsageStatsCalendar.lastHourStart(ofDayStartingAt: end, calendar: calendar)
        return TrendPlan(granularity: .hour, firstBucket: start, lastBucket: last)
      case .day:
        // 首桶给自选的起点，超上限由 `bucketLimit` 从末桶往回截——末桶永远是自选的末日。
        return TrendPlan(
          granularity: .day, firstBucket: start, lastBucket: end,
          bucketLimit: Self.customTrendDayLimit)
      }
    }
  }
}

/// 曲线图上的一路序列（可切换显示的维度）。
nonisolated enum StatsSeries: String, CaseIterable, Identifiable, Sendable {
  /// 总 token（输入 + 输出 + 缓存读 + 缓存写）。
  case total
  case input
  case output
  case cacheRead
  case cacheWrite

  var id: String { rawValue }

  /// 默认显示的三路：总量、输入、输出——缓存读/写通常比前三者小一个量级，
  /// 默认画上去会把曲线压到贴近底边，因此留在图例里等用户点开。
  static let defaultVisible: Set<StatsSeries> = [.total, .input, .output]

  /// 图例的档位数：布局预算与测试同源（见 `UsageStatsLayoutTests`）。
  static let visibleOptions = allCases.count
}

/// 趋势桶的计划：粒度（小时 / 天）+ 首尾桶（都落在粒度边界上）+ 可选的桶数上限。
nonisolated struct TrendPlan: Equatable, Sendable {
  var granularity: TrendGranularity
  var firstBucket: Date
  var lastBucket: Date
  /// 桶数上限（`nil` = 不限）。超长的自选范围只画最近的这些桶，更早的数据仍计入总量。
  var bucketLimit: Int? = nil

  /// 桶起点序列（升序、含空桶）——数据层据此补空桶，视图直接画。
  ///
  /// 从末桶**往回**走，而不是从首桶按「+24 小时 / +1 小时」正推：日粒度下正推过午夜发生
  /// 夏令时跳变的那天之后，每个落点都晚一小时，走到末桶之前就退出——曲线丢掉窗口最后
  /// 一天，而总量把它算进去了（America/Santiago 实测：总量 200，曲线只有 19 个桶）。
  /// 往回走时每一步用「前一秒所在的桶起点」，跳变日与不存在的当地时刻都不会踩空。
  ///
  /// 桶按**键**去重：秋令时回拨的那一小时会出现两个同分钟的桶（如 `T00` 两次），而 SQL
  /// 也是按键分组的，它们本来就是同一个桶。
  func bucketStarts(calendar: Calendar = .current) -> [Date] {
    let unit: Calendar.Component = granularity == .hour ? .hour : .day
    let lastStart = bucketStart(containing: lastBucket, unit: unit, calendar: calendar)
    let firstStart = bucketStart(containing: firstBucket, unit: unit, calendar: calendar)

    var starts: [Date] = []
    var seen = Set<String>()
    var cursor = lastStart
    while cursor >= firstStart {
      let key = UsageStatsKey.bucket(for: cursor, granularity: granularity, calendar: calendar)
      if seen.insert(key).inserted { starts.append(cursor) }
      if let bucketLimit, starts.count >= bucketLimit { break }
      guard let previous = previousBucketStart(before: cursor, unit: unit, calendar: calendar)
      else { break }
      cursor = previous
    }
    return starts.reversed()
  }

  /// 某个时刻所在桶的起点。
  private func bucketStart(containing date: Date, unit: Calendar.Component, calendar: Calendar)
    -> Date
  {
    calendar.dateInterval(of: unit, for: date)?.start ?? date
  }

  /// 上一个桶的起点：从「前一秒」所在的桶取（不用 `date(byAdding:)` 直接减去一整天——
  /// 夏令时跳变日的当地零点可能不存在，加减一天的行为不保证落在相邻的那一天）。
  private func previousBucketStart(
    before date: Date, unit: Calendar.Component, calendar: Calendar
  ) -> Date? {
    let start = bucketStart(
      containing: date.addingTimeInterval(-1), unit: unit, calendar: calendar)
    return start < date ? start : nil
  }
}

/// 趋势图的粒度。
nonisolated enum TrendGranularity: Sendable {
  case hour
  case day
}

/// 一个窗口内的汇总用量。
nonisolated struct UsageTotals: Equatable, Sendable {
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0
  /// 窗口内的会话数（去重，不含子代理会话）。
  var sessions = 0
  /// 窗口内的工具调用次数。
  var calls = 0

  /// 总 token = 输入 + 输出 + 缓存读 + 缓存写。
  var total: Int { input + output + cacheRead + cacheWrite }

  /// 缓存命中率 = 缓存读 / (输入 + 缓存读 + 缓存写)；分母为 0 时无意义。
  var cacheHitRate: Double? {
    let promptTokens = input + cacheRead + cacheWrite
    guard promptTokens > 0 else { return nil }
    return Double(cacheRead) / Double(promptTokens)
  }

  /// 是否一条记录都没有（用于空态判断）。
  var isEmpty: Bool { total == 0 && calls == 0 && sessions == 0 }

  static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
    var sum = lhs
    sum.input += rhs.input
    sum.output += rhs.output
    sum.cacheRead += rhs.cacheRead
    sum.cacheWrite += rhs.cacheWrite
    sum.calls += rhs.calls
    sum.sessions += rhs.sessions
    return sum
  }
}

/// 单个 Agent 在窗口内的用量。
nonisolated struct AgentUsage: Identifiable, Equatable, Sendable {
  let agent: AgentKind
  var totals: UsageTotals

  var id: String { agent.rawValue }
}

/// 单个工具在窗口内的调用次数。
nonisolated struct ToolUsage: Identifiable, Equatable, Sendable {
  /// 归一化后的工具名（入库前已去大小写与 `mcp__` 前缀）。
  let name: String
  let calls: Int

  var id: String { name }
}

/// 趋势图上的一个点（一个时间桶）。四路 token 各自成列，曲线按需选路画。
nonisolated struct TrendPoint: Identifiable, Equatable, Sendable {
  /// 桶起点（本地时区）。
  let start: Date
  let input: Int
  let output: Int
  let cacheRead: Int
  let cacheWrite: Int
  /// 桶内的工具调用次数。
  let calls: Int

  var id: Double { start.timeIntervalSince1970 }

  /// 桶内的总 token（与 `UsageTotals.total` 同口径：四路之和）。
  var total: Int { input + output + cacheRead + cacheWrite }

  /// 某一路序列在这个桶里的值。
  func value(for series: StatsSeries) -> Int {
    switch series {
    case .total: return total
    case .input: return input
    case .output: return output
    case .cacheRead: return cacheRead
    case .cacheWrite: return cacheWrite
    }
  }
}

/// 一次查询的完整结果，视图只消费这个值。
nonisolated struct UsageStatsSnapshot: Equatable, Sendable {
  /// 这次查询的窗口（视图据它取粒度与横轴刻度）。
  var window: StatsWindow = .preset(.today)
  var totals = UsageTotals()
  /// 各 Agent 的用量，按总 token 降序。
  var agents: [AgentUsage] = []
  /// 工具榜，按调用次数降序（视图自行截断）。
  var tools: [ToolUsage] = []
  /// 趋势，按时间升序且**含空桶**（视图可直接画）。
  var trend: [TrendPoint] = []
  /// 最近一次索引完成时间。
  var indexedAt: Date?
  /// 是否正在做首次回填 / 增量扫描。
  var isIndexing = false

  static let empty = UsageStatsSnapshot()
}

// MARK: - 数值短格式

/// 用量数字的短格式。
///
/// 规则有两条，都是为了「位数一致且放得下」：
///   · **不足一个量级的原数按整数显示**，不给整数补 `.00`（token 数本身是整数）；
///   · **缩写值的小数位随量级收缩**：整数部分不超过两位时保留 2 位（12,488 → 1.25万，
///     截断误差在 0.5% 以内），超过两位就不再带小数（12,345,678 → 1235万）。
///     后一条是必须的：一律 2 位小数会把大数写成 `1234.57万`（8 个字符），总览卡的大
///     数字与曲线图的 y 轴刻度都放不下（实测：y 轴刻度栏只有 30 多 pt）。
///
/// 中文界面按「万 / 亿」（12,488 → 1.25万；69,538,549,758 → 695亿），其余语言沿用
/// K / M / B 公制词头（词头各语言通用；B 那一档不能省——只到 M 的话 32 亿 token 会写成
/// `3239M`，比中文的 `32.39亿` 还长）。小数点符号与千分位跟随界面语言。
nonisolated enum UsageTokenFormat {
    /// 短格式的 token 数量。
    static func short(_ value: Int, languageCode: String, locale: Locale) -> String {
        if languageCode.hasPrefix("zh") {
            return chineseShort(value, locale: locale)
        }
        if value >= 1_000_000_000 {
            return scaled(Double(value) / 1_000_000_000, suffix: "B")
        }
        if value >= 1_000_000 {
            return scaled(Double(value) / 1_000_000, suffix: "M")
        }
        if value >= 1_000 {
            return scaled(Double(value) / 1_000, suffix: "K")
        }
        return value.formatted(.number.locale(locale))
    }

    /// 中文的量级词：不足一万给原数，一万以上用「万」，一亿以上用「亿」。
    private static func chineseShort(_ value: Int, locale: Locale) -> String {
        if value >= 100_000_000 {
            return scaled(Double(value) / 100_000_000, suffix: "亿")
        }
        if value >= 10_000 {
            return scaled(Double(value) / 10_000, suffix: "万")
        }
        return value.formatted(.number.locale(locale))
    }

    /// 缩写值的写法：整数部分不超过两位时 2 位小数，否则不带小数（见上面的规则说明）。
    ///
    /// 两条实现细节都是为了「位数可控」（最坏 6 个字符，见 `tokenShortFormatStaysShort`）：
    ///   · **先按 2 位小数算出最终数字再选格式**——按原始值判断会让 999,999 写成
    ///     `100.00万`（进位后 7 个字符）；
    ///   · **不带千分位**：`1235万` 而不是 `1,235万`（缩写值本身是近似值，位数越短越好；
    ///     原数那一档 `9,999` 仍然按语言加千分位）。
    private static func scaled(_ value: Double, suffix: String) -> String {
        let rounded = (value * 100).rounded() / 100
        let format = rounded >= 100 ? "%.0f" : "%.2f"
        // 不传 locale：C 的 `%f` 不加千分位（传 locale 会带上语言的分组分隔符）。
        return String(format: format, value) + suffix
    }
}

// MARK: - 时间桶键

/// 聚合键的构造与解析。全部按**本地时区**分桶，键形如 `2026-09-20T14`。
nonisolated enum UsageStatsKey {
  /// 本地时区的「小时」键。
  static func hour(for date: Date, calendar: Calendar = .current) -> String {
    formatter(for: calendar).string(from: date)
  }

  /// 从小时键取出「天」部分（`2026-09-20T14` → `2026-09-20`）。
  static func day(of hourKey: String) -> String {
    String(hourKey.prefix(10))
  }

  /// 趋势用的桶键：小时粒度给 `2026-09-20T14`，天粒度给 `2026-09-20`。
  /// 统计库的分组表达式（`hour_key` / `substr(hour_key, 1, 10)`）与此一一对应。
  static func bucket(
    for date: Date, granularity: TrendGranularity, calendar: Calendar = .current
  ) -> String {
    let hourKey = hour(for: date, calendar: calendar)
    switch granularity {
    case .hour:
      return hourKey
    case .day:
      return day(of: hourKey)
    }
  }

  private static var cachedFormatter: DateFormatter?
  private static var cachedTimeZoneIdentifier: String?

  /// 按日历时区取格式化器；时区变了就重建（用户切换时区后键要跟着走）。
  private static func formatter(for calendar: Calendar) -> DateFormatter {
    let identifier = calendar.timeZone.identifier
    if let cachedFormatter, cachedTimeZoneIdentifier == identifier {
      return cachedFormatter
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd'T'HH"
    cachedFormatter = formatter
    cachedTimeZoneIdentifier = identifier
    return formatter
  }
}
