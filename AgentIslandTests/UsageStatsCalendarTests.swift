//
//  UsageStatsCalendarTests.swift
//  AgentIslandTests
//
//  统计页的日期算术：含首尾的天数、范围归一、月历格子（前导空格由周起始日推出）、
//  月份步进遇到月末的处理。月历的每一格都来自这里，因此这些边界直接决定用户点到
//  哪一天、窗口覆盖哪些天。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("统计页的日期算术")
struct UsageStatsCalendarTests {
  private func calendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar().date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
  }

  @Test("天数含首尾；顺序颠倒按交换后算；跨年也对")
  func dayCountIncludesBothEnds() {
    let calendar = calendar()
    #expect(UsageStatsCalendar.dayCount(from: day(2026, 9, 1), to: day(2026, 9, 1), calendar: calendar) == 1)
    #expect(UsageStatsCalendar.dayCount(from: day(2026, 9, 1), to: day(2026, 9, 30), calendar: calendar) == 30)
    #expect(UsageStatsCalendar.dayCount(from: day(2026, 9, 30), to: day(2026, 9, 1), calendar: calendar) == 30)
    #expect(UsageStatsCalendar.dayCount(from: day(2025, 12, 31), to: day(2026, 1, 1), calendar: calendar) == 2)
    // 跨月且跨夏令时无关的月份：3 月 31 天。
    #expect(UsageStatsCalendar.dayCount(from: day(2026, 3, 1), to: day(2026, 3, 31), calendar: calendar) == 31)
  }

  @Test("范围归一：先点晚的那天、再点早的那天也能得到「早 – 晚」")
  func normalizationSwapsReversedDays() {
    let range = UsageStatsCalendar.normalized(day(2026, 9, 20), day(2026, 9, 3))
    #expect(range.from == day(2026, 9, 3))
    #expect(range.to == day(2026, 9, 20))

    let same = UsageStatsCalendar.normalized(day(2026, 9, 3), day(2026, 9, 3))
    #expect(same.from == day(2026, 9, 3))
    #expect(same.to == day(2026, 9, 3))
  }

  @Test("月历固定 42 格、前导空格由周起始日推出、每格只含当月日期")
  func monthGridStartsOnFirstWeekday() {
    // 2026-09-01 是周二：周日开头的日历要空 2 格（周日、周一），周一开始空 1 格。
    let expectedLeading = [2, 1, 0, 6, 5, 4, 3]

    for firstWeekday in 1...7 {
      let calendar = calendar(firstWeekday: firstWeekday)
      let grid = UsageStatsCalendar.monthGrid(containing: day(2026, 9, 1), calendar: calendar)
      let leading = grid.prefix { $0 == nil }.count

      #expect(grid.count == 7 * UsageStatsCalendar.rowCount)
      #expect(grid.count == 42)
      #expect(leading == expectedLeading[firstWeekday - 1], "firstWeekday = \(firstWeekday)")
      #expect(grid[leading] == calendar.startOfDay(for: day(2026, 9, 1)))
      // 9 月 30 天：当月日期恰好 30 个，其余是空位。
      #expect(grid.compactMap { $0 }.count == 30)
      #expect(grid[leading + 29] == calendar.startOfDay(for: day(2026, 9, 30)))
    }
  }

  @Test("月历跨月与闰年：二月按真实天数")
  func monthGridHandlesLeapAndShortMonths() {
    let calendar = calendar()

    let leap = UsageStatsCalendar.monthGrid(containing: day(2024, 2, 10), calendar: calendar)
    #expect(leap.compactMap { $0 }.count == 29)

    let short = UsageStatsCalendar.monthGrid(containing: day(2026, 2, 10), calendar: calendar)
    #expect(short.compactMap { $0 }.count == 28)

    // 31 天的月份不越界到 8 月 1 日。
    let long = UsageStatsCalendar.monthGrid(containing: day(2026, 7, 15), calendar: calendar)
    let days = long.compactMap { $0 }
    #expect(days.count == 31)
    #expect(calendar.component(.month, from: days.last ?? Date()) == 7)
    #expect(calendar.component(.day, from: days.last ?? Date()) == 31)
  }

  @Test("月份步进遇到月末夹到目标月最后一天")
  func addMonthsClampsInvalidDays() {
    let calendar = calendar()
    #expect(UsageStatsCalendar.addMonths(1, to: day(2026, 1, 31), calendar: calendar) == day(2026, 2, 28))
    #expect(UsageStatsCalendar.addMonths(1, to: day(2024, 1, 31), calendar: calendar) == day(2024, 2, 29))
    #expect(UsageStatsCalendar.addMonths(-1, to: day(2026, 3, 31), calendar: calendar) == day(2026, 2, 28))
    #expect(UsageStatsCalendar.addMonths(1, to: day(2026, 9, 15), calendar: calendar) == day(2026, 10, 15))
    // 跨年：12 月 +1 月 → 次年 1 月。
    #expect(UsageStatsCalendar.addMonths(1, to: day(2026, 12, 15), calendar: calendar) == day(2027, 1, 15))
  }

  @Test("月的第一天与起点：startOfMonth 落在 1 日零点")
  func startOfMonthLandsOnFirstDay() {
    let calendar = calendar()
    #expect(UsageStatsCalendar.startOfMonth(day(2026, 9, 20), calendar: calendar) == day(2026, 9, 1))
    #expect(UsageStatsCalendar.startOfDay(day(2026, 9, 20), calendar: calendar) == day(2026, 9, 20))
  }
}
