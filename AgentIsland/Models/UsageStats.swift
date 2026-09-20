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

/// 统计的时间窗口。
nonisolated enum StatsRange: String, CaseIterable, Identifiable, Sendable {
  /// 今天（本地时区自然日）。
  case today
  /// 本周（起点跟随系统「周起始日」设置）。
  case week
  /// 本月（当月 1 日 00:00 起）。
  case month
  /// 全部历史。
  case all

  var id: String { rawValue }

  /// 趋势粒度：当天按小时，其余按天。
  var trendGranularity: TrendGranularity {
    self == .today ? .hour : .day
  }

  /// 窗口起点；`nil` 表示不限起点（仅「全部」）。
  func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
    switch self {
    case .all:
      return nil
    case .today:
      return calendar.startOfDay(for: now)
    case .week:
      return calendar.dateInterval(of: .weekOfYear, for: now)?.start
    case .month:
      return calendar.dateInterval(of: .month, for: now)?.start
    }
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

/// 趋势图上的一个柱子（一个时间桶）。
nonisolated struct TrendPoint: Identifiable, Equatable, Sendable {
  /// 桶起点（本地时区）。
  let start: Date
  /// 桶内的总 token。
  let total: Int
  /// 桶内的工具调用次数。
  let calls: Int

  var id: Double { start.timeIntervalSince1970 }
}

/// 一次查询的完整结果，视图只消费这个值。
nonisolated struct UsageStatsSnapshot: Equatable, Sendable {
  var range: StatsRange = .today
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

  /// 把小时键还原成桶起点。
  static func date(fromHourKey hourKey: String, calendar: Calendar = .current) -> Date? {
    formatter(for: calendar).date(from: hourKey)
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
