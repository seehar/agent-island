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

  @Test("自选范围过长时只截首桶：末桶固定是自选的末日")
  func customTrendPlanCapsLongRanges() {
    let calendar = calendar()
    let to = day(2026, 9, 20)
    guard let from = calendar.date(byAdding: .day, value: -399, to: to) else {
      Issue.record("构造起点失败")
      return
    }

    let plan = StatsWindow.custom(from: from, to: to).trendPlan(now: to, calendar: calendar)
    let starts = plan.bucketStarts(calendar: calendar)
    #expect(plan.granularity == .day)
    #expect(starts.count == StatsWindow.customTrendDayLimit)
    #expect(plan.lastBucket == to)
    #expect(
      starts.first
        == calendar.date(byAdding: .day, value: -(StatsWindow.customTrendDayLimit - 1), to: to))
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
