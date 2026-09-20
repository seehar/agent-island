//
//  UsageStatsTests.swift
//  AgentIslandTests
//
//  用量统计的口径与时间窗口：总量是否含缓存、缓存命中率的分母、本地时区的小时/
//  天分桶，以及「本周」是否跟随系统周起始日。这些数字一旦漂移，页面上会出现
//  两个互相矛盾的用量，所以逐项钉死。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("用量统计口径")
struct UsageStatsTests {
  /// 固定时区的日历：断言不随运行机器的时区与周起始日变化。
  private func calendar(timeZone: String = "Asia/Shanghai", firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  @Test("总 token 含缓存读写")
  func totalIncludesCacheTokens() {
    var totals = UsageTotals()
    totals.input = 100
    totals.output = 20
    totals.cacheRead = 300
    totals.cacheWrite = 40

    #expect(totals.total == 460)
  }

  @Test("缓存命中率 = 缓存读 / (输入 + 缓存读 + 缓存写)")
  func cacheHitRateUsesPromptTokens() {
    var totals = UsageTotals()
    totals.input = 100
    totals.cacheRead = 300
    totals.cacheWrite = 100

    // 300 / (100 + 300 + 100) = 0.6
    #expect(abs((totals.cacheHitRate ?? 0) - 0.6) < 1e-9)
  }

  @Test("没有任何提示词 token 时命中率无意义")
  func cacheHitRateNilWithoutPromptTokens() {
    var totals = UsageTotals()
    totals.output = 42

    #expect(totals.cacheHitRate == nil)
    #expect(totals.isEmpty == false)  // 有输出就不是空态
  }

  @Test("汇总相加")
  func totalsAddUp() {
    var left = UsageTotals()
    left.input = 1
    left.sessions = 1
    var right = UsageTotals()
    right.cacheWrite = 2
    right.calls = 3

    let sum = left + right
    #expect(sum.input == 1)
    #expect(sum.cacheWrite == 2)
    #expect(sum.sessions == 1)
    #expect(sum.calls == 3)
  }

  @Test("中文界面按「万 / 亿」，其余语言按 K / M")
  func tokenShortFormatFollowsLanguage() {
    let zh = Locale(identifier: "zh-Hans")
    let en = Locale(identifier: "en-US")

    // 中文：不足一万给原数，一万以上「万」，一亿以上「亿」。
    #expect(UsageTokenFormat.short(9_999, languageCode: "zh", locale: zh) == "9,999")
    #expect(UsageTokenFormat.short(12_488, languageCode: "zh", locale: zh) == "1.2万")
    #expect(UsageTokenFormat.short(4_800_000, languageCode: "zh", locale: zh) == "480万")
    #expect(UsageTokenFormat.short(100_000_000, languageCode: "zh", locale: zh) == "1亿")
    #expect(UsageTokenFormat.short(3_239_364_009, languageCode: "zh", locale: zh) == "32.4亿")
    #expect(UsageTokenFormat.short(69_538_549_758, languageCode: "zh", locale: zh) == "695.4亿")

    // 其它语言沿用公制词头。
    #expect(UsageTokenFormat.short(12_488, languageCode: "en", locale: en) == "12.5K")
    #expect(UsageTokenFormat.short(4_800_000, languageCode: "en", locale: en) == "4.8M")
    #expect(UsageTokenFormat.short(999, languageCode: "en", locale: en) == "999")
  }

  @Test("小时键按本地时区切分")
  func hourKeyUsesLocalTimeZone() {
    let shanghai = calendar()
    // 2026-01-01 00:30 +08:00
    let newYear = Date(timeIntervalSince1970: 1_767_198_600)
    #expect(UsageStatsKey.hour(for: newYear, calendar: shanghai) == "2026-01-01T00")

    // 同一个瞬间在 UTC 下属于前一天：分桶必须跟着时区走。
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    #expect(UsageStatsKey.hour(for: newYear, calendar: utc) == "2025-12-31T16")
    #expect(UsageStatsKey.day(of: UsageStatsKey.hour(for: newYear, calendar: utc)) == "2025-12-31")
  }

  @Test("小时键可以还原成桶起点")
  func hourKeyRoundTrip() {
    let shanghai = calendar()
    let date = Date(timeIntervalSince1970: 1_767_198_600)
    let key = UsageStatsKey.hour(for: date, calendar: shanghai)
    let restored = UsageStatsKey.date(fromHourKey: key, calendar: shanghai)

    #expect(restored == Date(timeIntervalSince1970: 1_767_196_800))  // 当地 00:00
  }

  @Test("今天从当地零点开始")
  func todayStartsAtLocalMidnight() {
    let shanghai = calendar()
    let now = Date(timeIntervalSince1970: 1_767_198_600)  // 2026-01-01 00:30 +08:00
    let start = StatsRange.today.start(now: now, calendar: shanghai)

    #expect(start == Date(timeIntervalSince1970: 1_767_196_800))
  }

  @Test("本周起点落在系统设置的周起始日、且在 7 天窗口内")
  func weekStartFollowsFirstWeekday() {
    let now = Date(timeIntervalSince1970: 1_767_585_600)  // 2026-01-05 12:00 +08:00

    for firstWeekday in [1, 2, 7] {
      let calendar = calendar(firstWeekday: firstWeekday)
      guard let start = StatsRange.week.start(now: now, calendar: calendar) else {
        Issue.record("本周起点缺失")
        continue
      }
      #expect(calendar.component(.weekday, from: start) == firstWeekday)
      #expect(start <= now)
      #expect(now.timeIntervalSince(start) < 7 * 24 * 3600)
      #expect(calendar.component(.hour, from: start) == 0)
      #expect(calendar.component(.minute, from: start) == 0)
    }
  }

  @Test("本月从当月 1 日零点开始")
  func monthStartsOnFirstDay() {
    let shanghai = calendar()
    let now = Date(timeIntervalSince1970: 1_767_585_600)  // 2026-01-05 12:00 +08:00
    guard let start = StatsRange.month.start(now: now, calendar: shanghai) else {
      Issue.record("本月起点缺失")
      return
    }

    #expect(shanghai.component(.day, from: start) == 1)
    #expect(shanghai.component(.hour, from: start) == 0)
    #expect(shanghai.component(.month, from: start) == shanghai.component(.month, from: now))
  }

  @Test("只有「全部」没有起点")
  func allRangeHasNoStart() {
    #expect(StatsRange.all.start() == nil)
    #expect(StatsRange.today.trendGranularity == .hour)
    #expect(StatsRange.week.trendGranularity == .day)
    #expect(StatsRange.all.trendGranularity == .day)
  }
}
