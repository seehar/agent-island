//
//  UsageStatsCalendar.swift
//  AgentIsland
//
//  统计页的日期算术：自然日跨度、范围归一、月历格子与月份步进。全部是纯函数
//  （日历由调用方传入），视图与视图模型共用同一份实现——范围天数决定趋势粒度、
//  月历格子决定点击落到哪一天，两处不能各写一套日期算术。
//

import Foundation

/// 统计页的日期算术。
nonisolated enum UsageStatsCalendar {
    /// 月历固定显示的行数：六行（42 格）足够放下任意月份。
    static let rowCount = 6

    /// 两个自然日之间含首尾的天数（顺序颠倒时按交换后算）。
    static func dayCount(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let range = normalized(from, to)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: range.from),
            to: calendar.startOfDay(for: range.to)
        ).day ?? 0
        return days + 1
    }

    /// 归一到「早 – 晚」：用户可能先点晚的那天、再点早的那天。
    static func normalized(_ a: Date, _ b: Date) -> (from: Date, to: Date) {
        a <= b ? (a, b) : (b, a)
    }

    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 某个自然日的**最后一个小时桶**的起点。
    ///
    /// 不能写成「零点 + 23 小时」：夏令时跳变那天当地是 23 或 25 小时，加 23 小时会落在
    /// 21/22 点，末小时（如 `T23`）的数据就画不出来（America/Havana 2026-11-01 实测）。
    static func lastHourStart(ofDayStartingAt day: Date, calendar: Calendar = .current) -> Date {
        let end =
            calendar.dateInterval(of: .day, for: day)?.end ?? day.addingTimeInterval(24 * 3600)
        let justBeforeEnd = end.addingTimeInterval(-1)
        return calendar.dateInterval(of: .hour, for: justBeforeEnd)?.start ?? justBeforeEnd
    }

    /// 该日所在月的 1 日零点。
    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    /// 月份步进；天数越界时夹到目标月的最后一天（1 月 31 日 +1 月 → 2 月 28/29 日）。
    /// 先把日期移到当月 1 日再加月份：直接给 1 月 31 日加一个月会溢出到 3 月。
    static func addMonths(_ delta: Int, to date: Date, calendar: Calendar = .current) -> Date {
        let monthStart = startOfMonth(date, calendar: calendar)
        guard
            let shifted = calendar.date(byAdding: .month, value: delta, to: monthStart)
        else { return monthStart }

        let targetStart = startOfMonth(shifted, calendar: calendar)
        let wantedDay = calendar.component(.day, from: date)
        let daysInTarget = calendar.range(of: .day, in: .month, for: targetStart)?.count ?? 1
        let day = min(wantedDay, daysInTarget)
        return calendar.date(byAdding: .day, value: day - 1, to: targetStart) ?? targetStart
    }

    /// 月历的一页：7 列 × 6 行（42 格），只含当月日期，前导空格补 `nil`；
    /// 首列固定是 `calendar.firstWeekday` 对应的星期（某月只需 5 行时尾部自然为 `nil`）。
    static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date?] {
        let monthStart = startOfMonth(date, calendar: calendar)
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        // 1 日是星期几（1 = 周日），与周起始日一起算出需要几个前导空格。
        let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<daysInMonth {
            cells.append(calendar.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart)
        }

        let total = 7 * rowCount
        while cells.count < total { cells.append(nil) }
        return Array(cells.prefix(total))
    }
}
