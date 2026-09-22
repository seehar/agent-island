//
//  UsageStatsFormatTests.swift
//  AgentIslandTests
//
//  统计页的展示格式化：窗口标题（预设档 / 自选范围）、横轴刻度、悬停桶标签、月历的
//  月名与周名。日期一律按界面语言格式化，因此这些用例都显式传 locale，
//  不读运行机器的系统 locale。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("统计页的展示格式化")
struct UsageStatsFormatTests {
  private let english = Locale(identifier: "en_US")
  private let chinese = Locale(identifier: "zh-Hans")

  private func calendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar().date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
  }

  @Test("七个预设档各给自己的文案（不是同一个键的残留）")
  func presetTitlesCoverEveryRange() {
    // 键即英语源文案；两种语言的取值都在这里，缺一个都会被抓出来。
    let keys = ["Last 24h", "Last 7d", "Last 30d", "Today", "This Week", "This Month", "All"]
    let chineseTitles = ["近一天", "近一周", "近一月", "今天", "本周", "本月", "全部"]

    #expect(keys.count == StatsRange.allCases.count)
    for (index, range) in StatsRange.allCases.enumerated() {
      let title = UsageStatsFormat.presetTitle(range)
      #expect(
        title == keys[index] || title == chineseTitles[index],
        "\(range.rawValue) 的标题解析成了 \(title)")
    }
  }

  @Test("自选范围的读数按界面语言：英语给「月份 + 日」，中文给「几月几日」")
  func customRangeDiffersByLanguage() {
    let from = day(2026, 9, 1)
    let to = day(2026, 9, 20)

    let englishTitle = UsageStatsFormat.customRange(from: from, to: to, locale: english)
    let chineseTitle = UsageStatsFormat.customRange(from: from, to: to, locale: chinese)

    #expect(englishTitle == "Sep 1 – Sep 20")
    #expect(chineseTitle.contains("月"))
    #expect(chineseTitle.contains("20"))
    #expect(englishTitle.contains("–") && chineseTitle.contains("–"))
  }

  @Test("跨年的自选范围两端都带年份（否则看不出跨了年）")
  func customRangeCarriesYearsWhenCrossingNewYear() {
    let title = UsageStatsFormat.customRange(
      from: day(2025, 12, 28), to: day(2026, 1, 3), locale: english)
    #expect(title.contains("2025"))
    #expect(title.contains("2026"))
  }

  @Test("窗口标题：预设给档名，自选给范围读数")
  func windowTitleFollowsWindowKind() {
    for range in StatsRange.allCases {
      #expect(
        UsageStatsFormat.windowTitle(.preset(range), locale: english)
          == UsageStatsFormat.presetTitle(range))
    }

    let custom = StatsWindow.custom(from: day(2026, 9, 1), to: day(2026, 9, 20))
    #expect(
      UsageStatsFormat.windowTitle(custom, locale: english)
        == UsageStatsFormat.customRange(from: day(2026, 9, 1), to: day(2026, 9, 20), locale: english))
  }

  @Test("横轴刻度与桶标签：小时粒度给钟点，日粒度只有日期")
  func axisAndBucketLabelsFollowGranularity() {
    // 钟点的断言用 24 小时制的区域：en_US 会给出「2:00 PM」，那与 14 点对不上。
    let twentyFourHour = Locale(identifier: "en_GB")
    let afternoon = calendar().date(byAdding: .hour, value: 14, to: day(2026, 9, 20)) ?? Date()

    let hourAxis = UsageStatsFormat.axisLabel(afternoon, granularity: .hour, locale: twentyFourHour)
    #expect(hourAxis == "14:00")
    #expect(UsageStatsFormat.axisLabel(day(2026, 9, 20), granularity: .day, locale: english) == "Sep 20")

    // 桶标签：小时粒度要带上日期（跨天的窗口里只给「14:00」分不清是哪天）。
    let hourBucket = UsageStatsFormat.bucketLabel(
      afternoon, granularity: .hour, locale: twentyFourHour)
    #expect(hourBucket.contains("14:00"))
    #expect(hourBucket.contains("Sep"))
    #expect(hourBucket.contains("20"))
    #expect(UsageStatsFormat.bucketLabel(day(2026, 9, 20), granularity: .day, locale: english) == "Sep 20")
  }

  @Test("月历月名：英语「September 2026」、中文「2026年9月」")
  func monthTitleFollowsLanguage() {
    let title = day(2026, 9, 20)
    #expect(UsageStatsFormat.monthTitle(title, locale: english) == "September 2026")

    let chineseTitle = UsageStatsFormat.monthTitle(title, locale: chinese)
    #expect(chineseTitle.contains("2026"))
    #expect(chineseTitle.contains("9"))
    #expect(chineseTitle.contains("月"))
  }

  @Test("周标题跟着周起始日轮转，语言取界面语言")
  func weekdaySymbolsFollowFirstWeekday() {
    let mondayFirst = UsageStatsFormat.weekdaySymbols(
      locale: english, calendar: calendar(firstWeekday: 2))
    #expect(mondayFirst.count == 7)
    #expect(mondayFirst.first == "Mon")

    let sundayFirst = UsageStatsFormat.weekdaySymbols(
      locale: english, calendar: calendar(firstWeekday: 1))
    #expect(sundayFirst.first == "Sun")

    // 中文的短名（周一…）：第一格必须是「一」，不能落到「日」。
    let chineseMondayFirst = UsageStatsFormat.weekdaySymbols(
      locale: chinese, calendar: calendar(firstWeekday: 2))
    #expect(chineseMondayFirst.count == 7)
    #expect(chineseMondayFirst.first?.contains("一") == true)
    #expect(chineseMondayFirst != mondayFirst)
  }

  @Test("月历格子的日号只给数字（不带「日」这类后缀）")
  func dayNumberIsNumeric() {
    #expect(UsageStatsFormat.dayNumber(day(2026, 9, 1), locale: english) == "1")
    #expect(UsageStatsFormat.dayNumber(day(2026, 9, 20), locale: chinese) == "20")
  }
}
