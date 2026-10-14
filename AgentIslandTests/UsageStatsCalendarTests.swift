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
    #expect(
      UsageStatsCalendar.dayCount(from: day(2026, 9, 1), to: day(2026, 9, 1), calendar: calendar)
        == 1)
    #expect(
      UsageStatsCalendar.dayCount(from: day(2026, 9, 1), to: day(2026, 9, 30), calendar: calendar)
        == 30)
    #expect(
      UsageStatsCalendar.dayCount(from: day(2026, 9, 30), to: day(2026, 9, 1), calendar: calendar)
        == 30)
    #expect(
      UsageStatsCalendar.dayCount(from: day(2025, 12, 31), to: day(2026, 1, 1), calendar: calendar)
        == 2)
    // 跨月且跨夏令时无关的月份：3 月 31 天。
    #expect(
      UsageStatsCalendar.dayCount(from: day(2026, 3, 1), to: day(2026, 3, 31), calendar: calendar)
        == 31)
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
    #expect(
      UsageStatsCalendar.addMonths(1, to: day(2026, 1, 31), calendar: calendar) == day(2026, 2, 28))
    #expect(
      UsageStatsCalendar.addMonths(1, to: day(2024, 1, 31), calendar: calendar) == day(2024, 2, 29))
    #expect(
      UsageStatsCalendar.addMonths(-1, to: day(2026, 3, 31), calendar: calendar) == day(2026, 2, 28)
    )
    #expect(
      UsageStatsCalendar.addMonths(1, to: day(2026, 9, 15), calendar: calendar) == day(2026, 10, 15)
    )
    // 跨年：12 月 +1 月 → 次年 1 月。
    #expect(
      UsageStatsCalendar.addMonths(1, to: day(2026, 12, 15), calendar: calendar) == day(2027, 1, 15)
    )
  }

  @Test("月的第一天与起点：startOfMonth 落在 1 日零点")
  func startOfMonthLandsOnFirstDay() {
    let calendar = calendar()
    #expect(
      UsageStatsCalendar.startOfMonth(day(2026, 9, 20), calendar: calendar) == day(2026, 9, 1))
    #expect(UsageStatsCalendar.startOfDay(day(2026, 9, 20), calendar: calendar) == day(2026, 9, 20))
  }

  @Test("热力图：53 列 × 7 行、行序按周起始日、末列是包含今天的那一周")
  func heatmapWeeksAlignToFirstWeekday() {
    // 2026-09-20 是周日：周一起算的日历里，它落在那一周的最后一行；周日起算时是第一行。
    let now =
      calendar().date(
        from: DateComponents(year: 2026, month: 9, day: 20, hour: 15, minute: 30)) ?? Date()

    for firstWeekday in 1...7 {
      let calendar = calendar(firstWeekday: firstWeekday)
      let weeks = UsageStatsCalendar.heatmapWeeks(containing: now, calendar: calendar)
      let today = calendar.startOfDay(for: now)

      #expect(weeks.count == UsageStatsCalendar.heatmapWeekCount)
      #expect(weeks.count == 53)
      #expect(weeks.allSatisfy { $0.count == UsageStatsCalendar.daysPerWeek })
      let lastColumn = weeks.count - 1

      // 「今天」那一格的行号 = 从周起始日数到今天的天数。
      let row = (calendar.component(.weekday, from: today) - firstWeekday + 7) % 7
      #expect(weeks[lastColumn][row] == today, "firstWeekday = \(firstWeekday)")

      // 每一列的第一天是它自己的那一周，且都是本地零点。
      for column in weeks {
        #expect(column[0] == UsageStatsCalendar.startOfWeek(column[0], calendar: calendar))
        #expect(column.allSatisfy { calendar.startOfDay(for: $0) == $0 })
        // 列里最后一行与第一行同属一周（行序按周起始日对齐的直接结果）。
        #expect(UsageStatsCalendar.startOfWeek(column[6], calendar: calendar) == column[0])
      }

      // 逐格相邻：同一列相邻两行差一天（夏令时那天当地没有 00:00，比较前先归一到当天零点）。
      for index in 1..<weeks[0].count {
        let next =
          calendar.date(byAdding: .day, value: 1, to: weeks[0][index - 1]).map(calendar.startOfDay)
        #expect(next == weeks[0][index])
      }
      // 第 0 列第 0 格 == 查询起点（最早那一周的第一天）。
      #expect(weeks[0][0] == UsageStatsCalendar.heatmapStart(containing: now, calendar: calendar))
      // 末列的第 0 行就是「今天所在周的起点」。
      #expect(weeks[lastColumn][0] == UsageStatsCalendar.startOfWeek(now, calendar: calendar))
      // 网格覆盖 53 周整：首尾两格相差 370 天（含首尾 = 371 天）。
      #expect(
        UsageStatsCalendar.dayCount(
          from: weeks[0][0], to: weeks[lastColumn][6], calendar: calendar)
          == UsageStatsCalendar.daysPerWeek * UsageStatsCalendar.heatmapWeekCount)
    }
  }

  @Test("热力图月份标签：每个新月一列、末尾不足三列的不给（标签比一列宽）")
  func heatmapMonthLabelsMarkMonthStarts() {
    let calendar = calendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14)) ?? Date()
    let weeks = UsageStatsCalendar.heatmapWeeks(containing: now, calendar: calendar)
    let starts = UsageStatsCalendar.heatmapMonthStarts(weeks: weeks, calendar: calendar)

    // 一年 12 个月：至少 11 个标签（首列那个月可能只有几天），且列号严格递增。
    #expect(starts.count >= 11 && starts.count <= 13, "标签数 \(starts.count)")
    #expect(starts.map(\.column) == starts.map(\.column).sorted())
    #expect(Set(starts.map(\.column)).count == starts.count)
    // 每个标签都落在「前一列与这一列的首日不同月」的位置上。
    for start in starts {
      let column = start.column
      #expect(column >= 0 && column < weeks.count)
      #expect(weeks[column].first == start.date)
      if column > 0, let previous = weeks[column - 1].first, let first = weeks[column].first {
        #expect(
          calendar.component(.month, from: previous) != calendar.component(.month, from: first))
      }
      // 相邻标签至少隔 4 列（一个月最短 28 天 = 4 周），否则会在行里叠字。
      #expect(weeks.count - column >= 3, "末尾标签太贴右缘")
    }
    // 首列一定有标签（网格从哪一周起都要能读出「从哪个月开始」）。
    #expect(starts.first?.column == 0)
  }

  @Test("热力图跨夏令时也逐格对齐（按天推，不是按 24 小时推）")
  func heatmapGridSurvivesDaylightSavingTransition() {
    // America/Havana 2026-11-01 结束夏令时：那一天当地有 25 小时，用「+24h」逐格推会
    // 在跳变处错开一小时，格子就不再是本地零点（月历的 `lastHourStart` 有同类注释）。
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Havana") ?? .gmt
    calendar.firstWeekday = 1

    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)) ?? Date()
    let weeks = UsageStatsCalendar.heatmapWeeks(containing: now, calendar: calendar)
    let flat = weeks.flatMap { $0 }

    #expect(flat.allSatisfy { calendar.startOfDay(for: $0) == $0 })
    for index in 1..<flat.count {
      // 夏令时开始那天当地没有 00:00（时钟 23:59 → 01:00）：先「加一天」再归一到当天零点，
      // 与 `heatmapWeeks` 的口径一致。
      let next =
        calendar.date(byAdding: .day, value: 1, to: flat[index - 1]).map(calendar.startOfDay)
      #expect(next == flat[index])
    }
    #expect(
      UsageStatsCalendar.dayCount(from: flat[0], to: flat[flat.count - 1], calendar: calendar)
        == UsageStatsCalendar.daysPerWeek * UsageStatsCalendar.heatmapWeekCount)
  }
}
