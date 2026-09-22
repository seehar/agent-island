//
//  UsageStatsWindowTests.swift
//  AgentIslandTests
//
//  统计窗口（预设档 / 自选起止）的边界与粒度：右端半开的小时键、跨度决定粒度、
//  长自选范围的桶上限，以及趋势点按序列取值的映射。页面的总量与曲线都由这些数字
//  推出来，因此逐项钉死（时区与周起始日固定，不随运行机器变化）。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("统计窗口")
struct UsageStatsWindowTests {
  /// 固定时区与周起始日的日历。
  private func calendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  /// 上海时区的某个自然日零点。
  private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar().date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
  }

  @Test("预设档委托给 StatsRange：粒度与起点都一致")
  func presetDelegatesToRange() {
    let calendar = calendar()
    let now = day(2026, 9, 20)

    for range in StatsRange.allCases {
      let window = StatsWindow.preset(range)
      #expect(window.granularity(calendar: calendar) == range.trendGranularity)
      #expect(window.bounds(now: now, calendar: calendar).start == range.start(now: now, calendar: calendar))
      // 预设档只卡左端：右端是「现在」，未来的桶本来就没有数据。
      #expect(window.bounds(now: now, calendar: calendar).end == nil)
      #expect(window.keyBounds(now: now, calendar: calendar).end == nil)
      #expect(window.presetRange == range)
    }
  }

  @Test("自选范围的右端是半开的：含终点整天，上界取终点次日零点")
  func customWindowIsHalfOpenOnTheRight() {
    let window = StatsWindow.custom(from: day(2026, 9, 1), to: day(2026, 9, 20))
    let keys = window.keyBounds(now: day(2026, 9, 20), calendar: calendar())

    #expect(keys.start == "2026-09-01T00")
    #expect(keys.end == "2026-09-21T00")
    #expect(window.presetRange == nil)
  }

  @Test("自选范围的粒度按跨度：不超过 2 个自然日按小时，否则按天")
  func customGranularityFollowsSpan() {
    let calendar = calendar()

    #expect(
      StatsWindow.custom(from: day(2026, 9, 1), to: day(2026, 9, 1))
        .granularity(calendar: calendar) == .hour)
    #expect(
      StatsWindow.custom(from: day(2026, 9, 1), to: day(2026, 9, 2))
        .granularity(calendar: calendar) == .hour)
    #expect(
      StatsWindow.custom(from: day(2026, 9, 1), to: day(2026, 9, 3))
        .granularity(calendar: calendar) == .day)
  }

  @Test("自选范围的小时粒度画满首尾两天（48 个桶）")
  func customHourPlanCoversBothDays() {
    let calendar = calendar()
    let plan = StatsWindow.custom(from: day(2026, 9, 1), to: day(2026, 9, 2))
      .trendPlan(now: day(2026, 9, 2), calendar: calendar)

    #expect(plan.granularity == .hour)
    #expect(plan.firstBucket == day(2026, 9, 1))
    #expect(plan.lastBucket == calendar.date(byAdding: .hour, value: 23, to: day(2026, 9, 2)))
    #expect(plan.bucketStarts(calendar: calendar).count == 48)
  }

  @Test("自选范围过长时只截首桶：末桶固定是自选的末日（夏令时时区也一样）")
  func customTrendPlanCapsLongRanges() {
    for zone in ["Asia/Shanghai", "America/Santiago"] {
      let calendar = calendar(zone: zone)
      guard
        let to = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20)),
        let from = calendar.date(byAdding: .day, value: -399, to: to)
      else {
        Issue.record("构造起点失败")
        return
      }

      let plan = StatsWindow.custom(from: from, to: to).trendPlan(now: to, calendar: calendar)
      let starts = plan.bucketStarts(calendar: calendar)
      let keys = starts.map {
        UsageStatsKey.bucket(for: $0, granularity: .day, calendar: calendar)
      }

      #expect(plan.granularity == .day)
      #expect(starts.count == StatsWindow.customTrendDayLimit, "\(zone) 的桶数应为 366，实际 \(starts.count)")
      #expect(Set(keys).count == keys.count, "\(zone) 的桶键不该重复")
      #expect(
        plan.lastBucket == calendar.startOfDay(for: to),
        "\(zone) 的末桶应为末日的 startOfDay")
      #expect(keys.last == "2026-09-20", "\(zone) 的末桶键应为末日")
    }
  }

  /// 固定时区（含**真会做夏令时**的时区）的日历：桶计划必须在这些时区里也成立。
  private func calendar(zone: String, firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  @Test("日粒度桶一个不少：夏令时跳变那天也不会把末日挤掉")
  func dayBucketsKeepTheLastDayInDaylightSavingZones() {
    // America/Santiago 2026-09-06 与 America/Havana 2026-03-01 的当地午夜发生过跳变
    // （那天的 startOfDay 不是 00:00）。旧实现按「+24 小时」递推，过跳变点后每个桶都晚
    // 一小时，走到末桶前就退出——曲线丢掉窗口最后一天，而总量把它算进去了。
    let cases: [(zone: String, from: (Int, Int, Int), to: (Int, Int, Int), days: Int)] = [
      ("America/Santiago", (2026, 9, 1), (2026, 9, 20), 20),
      ("America/Havana", (2026, 3, 1), (2026, 3, 15), 15),
      ("Asia/Shanghai", (2026, 9, 1), (2026, 9, 20), 20),
    ]

    for item in cases {
      let calendar = calendar(zone: item.zone)
      let from = calendar.date(
        from: DateComponents(year: item.from.0, month: item.from.1, day: item.from.2)) ?? Date()
      let to = calendar.date(
        from: DateComponents(year: item.to.0, month: item.to.1, day: item.to.2)) ?? Date()

      let plan = StatsWindow.custom(from: from, to: to).trendPlan(now: to, calendar: calendar)
      let starts = plan.bucketStarts(calendar: calendar)
      let keys = starts.map {
        UsageStatsKey.bucket(for: $0, granularity: .day, calendar: calendar)
      }

      #expect(starts.count == item.days, "\(item.zone) 的日粒度桶数应为 \(item.days)，实际 \(starts.count)")
      #expect(Set(keys).count == keys.count, "\(item.zone) 的桶键不该重复")
      #expect(keys.last == UsageStatsKey.day(of: UsageStatsKey.hour(for: to, calendar: calendar)),
              "\(item.zone) 的末桶必须是窗口末日（末桶 \(keys.last ?? "nil")）")
      #expect(keys.first == UsageStatsKey.day(of: UsageStatsKey.hour(for: from, calendar: calendar)))
    }
  }

  @Test("小时粒度桶覆盖窗口内每个整点键：秋令时回拨那天不重复、也不漏 23 点")
  func hourBucketsCoverEveryHourKey() {
    // America/Havana 2026-11-01 当地有 25 小时（00:00 回拨重复一次）：按小时键分组时
    // 两个 00:00 是同一个桶，因此正确的计划是 24 个键、且 23 点那个键必须在。
    let calendar = calendar(zone: "America/Havana")
    let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)) ?? Date()

    let plan = StatsWindow.custom(from: day, to: day).trendPlan(now: day, calendar: calendar)
    let keys = plan.bucketStarts(calendar: calendar).map {
      UsageStatsKey.bucket(for: $0, granularity: .hour, calendar: calendar)
    }

    #expect(Set(keys).count == keys.count, "桶键不该重复：\(keys)")
    #expect(keys.count == 24, "25 小时的一天按小时键只有 24 个桶，实际 \(keys.count)")
    #expect(keys.contains("2026-11-01T23"), "23 点那个桶必须在（否则它的数据画不出来）")
    #expect(keys.first == "2026-11-01T00")
    #expect(keys.last == "2026-11-01T23")
  }

  @Test("趋势点按序列取值：四路各有来源，总量是四路之和")
  func trendPointMapsSeriesValues() {
    let point = TrendPoint(
      start: day(2026, 9, 1), input: 10, output: 4, cacheRead: 300, cacheWrite: 40, calls: 7)

    #expect(point.value(for: .input) == 10)
    #expect(point.value(for: .output) == 4)
    #expect(point.value(for: .cacheRead) == 300)
    #expect(point.value(for: .cacheWrite) == 40)
    #expect(point.value(for: .total) == 354)
    #expect(point.calls == 7)
  }

  @Test("默认显示三路（总量 / 输入 / 输出），缓存两路留给图例")
  func defaultVisibleSeries() {
    #expect(StatsSeries.defaultVisible == [.total, .input, .output])
    #expect(StatsSeries.visibleOptions == StatsSeries.allCases.count)
  }

  @Test("范围芯片的顺序覆盖全部预设档，一格都不少、也不重复")
  func chipOrderCoversEveryPreset() {
    #expect(StatsRange.chipOrder.count == StatsRange.allCases.count)
    #expect(Set(StatsRange.chipOrder) == Set(StatsRange.allCases))
  }
}
