//
//  StatsRangePicker.swift
//  AgentIsland
//
//  统计页的时间范围控件：页眉行里的披露控件 + 「重新统计」按钮 + 展开后的选择器
//  （预设芯片网格 + 自绘月历）。控件在设置页的页眉行里（与返回箭头、分组标题同一行），
//  展开块作为固定块插在分段条与滚动区之间——它挤占页内滚动视口，不参与面板高度。
//

import Combine
import SwiftUI

// MARK: - 页眉行里的控件

/// 范围控件：显示当前时间窗口，点一下展开 / 收起选择器。
///
/// 它取代了原来页面顶部那条 7 档分段控件：那条与设置面板的分组切换条上下相邻、形状
/// 又相同，会被读成「第二层导航」；并进页眉行后同一时刻只有一条控件行。
struct StatsRangeControl: View {
    @ObservedObject var viewModel: UsageStatsViewModel
    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale

    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(SettingsMotion.expand) {
                viewModel.toggleRangePicker()
            }
        } label: {
            HStack(spacing: UsageStatsMetrics.headerRangeGap) {
                Text(UsageStatsFormat.windowTitle(viewModel.window, locale: locale))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(UsageStatsMetrics.headerRangeMinimumScale)

                Image(systemName: viewModel.isRangePickerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(AppPalette.tertiaryText)
            }
            .padding(.horizontal, 6)
            .frame(
                width: UsageStatsMetrics.headerRangeWidth,
                height: UsageStatsMetrics.headerActionSize,
                alignment: .trailing
            )
            .background(
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .fill(isHovered || viewModel.isRangePickerExpanded ? AppPalette.rowHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(l10n.t("Date range")))
    }
}

/// 「重新统计」按钮：把各 Agent 的历史记录从头重读一遍并重放（增量扫描只读文件的
/// 尾巴，所以数字对不上时只有这条路能改）。索引进行中禁用；进度文案在页面脚注里，
/// 页眉这一格只放图标，不再占一行。
struct StatsRescanButton: View {
    @ObservedObject var viewModel: UsageStatsViewModel
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isHovered = false

    var body: some View {
        let isIndexing = viewModel.snapshot.isIndexing

        return Button {
            viewModel.rescan()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint(isIndexing: isIndexing))
                .frame(
                    width: UsageStatsMetrics.headerActionSize,
                    height: UsageStatsMetrics.headerActionSize
                )
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovered && !isIndexing ? AppPalette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .disabled(isIndexing)
        .onHover { isHovered = $0 }
        // 禁用时把原因写进提示：索引进行中再点也只会被同一次重建吞掉，
        // 而界面上的唯一信号是图标变淡（同面板其它禁用态都换成说明文案）。
        .help(
            isIndexing
                ? l10n.t("Indexing…")
                : l10n.t("Re-read every session record and recompute the statistics.")
        )
        .accessibilityLabel(Text(l10n.t("Rescan")))
    }

    /// 图标色：索引中（禁用）降到最弱一级，与设置面板的禁用态同口径。
    private func tint(isIndexing: Bool) -> Color {
        if isIndexing { return AppPalette.subtleText }
        return isHovered ? AppPalette.primaryText : AppPalette.secondaryText
    }
}

// MARK: - 选择器

/// 范围选择器：预设芯片网格（4 列两行，8 格 = 7 档 + 「自定义…」）+ 展开后的月历。
struct StatsRangePickerPanel: View {
    @ObservedObject var viewModel: UsageStatsViewModel
    @ObservedObject private var l10n = LocalizationManager.shared

    /// 当前悬停的芯片（按标题记，标题即唯一键）。
    @State private var hoveredChip: String?

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: UsageStatsMetrics.rangePickerGap) {
                chipGrid

                if viewModel.isCustomPicking {
                    Rectangle()
                        .fill(AppPalette.separator)
                        .frame(height: 1)

                    StatsCalendarView(viewModel: viewModel)
                }
            }
            .padding(.horizontal, NotchMenuMetrics.rowHorizontalPadding)
            .padding(.vertical, UsageStatsMetrics.rangePickerVerticalPadding)
        }
    }

    // MARK: - 预设芯片

    /// 芯片网格：预设档按 `StatsRange.chipOrder` 排，末尾补一格「自定义…」。
    private var chipGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: UsageStatsMetrics.rangeChipSpacing),
                count: UsageStatsMetrics.rangeChipColumns
            ),
            spacing: UsageStatsMetrics.rangeChipRowSpacing
        ) {
            ForEach(StatsRange.chipOrder) { range in
                chip(
                    title: UsageStatsFormat.presetTitle(range),
                    isSelected: viewModel.window == .preset(range)
                ) {
                    viewModel.select(range)
                }
            }

            chip(title: l10n.t("Custom…"), isSelected: viewModel.window.presetRange == nil) {
                viewModel.startCustomPicking()
            }
        }
    }

    /// 一格芯片：选中态用滑块底色、未选中用轨道底色（与设置面板的分段控件同口径）。
    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(SettingsMotion.expand) {
                action()
            }
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? AppPalette.primaryText : AppPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(UsageStatsMetrics.rangeChipMinimumScale)
                .frame(maxWidth: .infinity)
                .frame(height: UsageStatsMetrics.rangeChipHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isSelected ? AppPalette.segmentedThumb : AppPalette.segmentedTrack)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(hoveredChip == title ? AppPalette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .onHover { isHovering in
            if isHovering {
                hoveredChip = title
            } else if hoveredChip == title {
                hoveredChip = nil
            }
        }
        .accessibilityLabel(Text(title))
    }
}

/// 自绘月历：月头（◀ 月名 ▶）+ 周标题 + 6 × 7 日期格 + 读数行。
///
/// 点第一下落起点、点第二下落终点（顺序颠倒也能容纳，见 `UsageStatsViewModel.pick`）。
/// 自绘而不是用 `DatePicker`：控件的观感与设置面板同源，且日期算术是纯函数、可单测。
struct StatsCalendarView: View {
    @ObservedObject var viewModel: UsageStatsViewModel
    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.locale) private var locale

    /// 当前悬停的日期（只影响底色）。
    @State private var hoveredDay: Date?

    var body: some View {
        VStack(spacing: 0) {
            monthHeader
            weekdayHeader
            // 行距只加在日期行之间（`UsageStatsMetrics.rangePickerHeight` 算的正是这 5 个间距）：
            // 月头、周标题与读数行与日期区之间不留缝。
            dayGrid
            readout
        }
        .frame(width: UsageStatsMetrics.calendarWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 6 × 7 的日期格：行距与列距同值，格子的横竖间隔看起来一致。
    private var dayGrid: some View {
        VStack(spacing: UsageStatsMetrics.calendarCellSpacing) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: UsageStatsMetrics.calendarCellSpacing) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
                .frame(height: UsageStatsMetrics.calendarCellHeight)
            }
        }
    }

    // MARK: - 月头与周标题

    private var monthHeader: some View {
        HStack(spacing: 0) {
            monthStepButton(symbol: "chevron.left", delta: -1, label: l10n.t("Previous month"))
            Spacer(minLength: 4)
            Text(UsageStatsFormat.monthTitle(viewModel.calendarMonth, locale: locale))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppPalette.primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            monthStepButton(symbol: "chevron.right", delta: 1, label: l10n.t("Next month"))
        }
        .frame(height: UsageStatsMetrics.calendarMonthHeaderHeight)
    }

    /// 翻月按钮：与设置面板的返回箭头同一档的图标按钮。
    private func monthStepButton(symbol: String, delta: Int, label: String) -> some View {
        Button {
            withAnimation(SettingsMotion.segment) {
                viewModel.stepMonth(delta)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(AppPalette.secondaryText)
                .frame(width: UsageStatsMetrics.headerActionSize, height: UsageStatsMetrics.headerActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCompactButtonStyle())
        .accessibilityLabel(Text(label))
    }

    /// 周标题：按系统「周起始日」顺序的 7 个短名（语言取界面语言）。
    private var weekdayHeader: some View {
        HStack(spacing: UsageStatsMetrics.calendarCellSpacing) {
            ForEach(
                Array(UsageStatsFormat.weekdaySymbols(locale: locale, calendar: .current).enumerated()),
                id: \.offset
            ) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9))
                    .foregroundColor(AppPalette.tertiaryText)
                    .lineLimit(1)
                    .frame(width: UsageStatsMetrics.calendarCellWidth)
            }
        }
        .frame(height: UsageStatsMetrics.calendarWeekdayHeight)
    }

    // MARK: - 日期格

    /// 月历格子按周切分（7 个一行）。
    private var weeks: [[Date?]] {
        let cells = UsageStatsCalendar.monthGrid(
            containing: viewModel.calendarMonth, calendar: .current)
        return stride(from: 0, to: cells.count, by: 7).map { start in
            Array(cells[start..<min(start + 7, cells.count)])
        }
    }

    /// 一格日期：`nil` 是前导 / 尾部空位（只占位，不可点）。
    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let state = cellState(for: day)

            Button {
                guard state.isSelectable else { return }
                withAnimation(SettingsMotion.expand) {
                    viewModel.pick(day: day)
                }
            } label: {
                Text(UsageStatsFormat.dayNumber(day, locale: locale))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(state.textColor)
                    .frame(
                        width: UsageStatsMetrics.calendarCellWidth,
                        height: UsageStatsMetrics.calendarCellHeight
                    )
                    .background(
                        RoundedRectangle(
                            cornerRadius: UsageStatsMetrics.calendarCellRadius, style: .continuous
                        )
                        .fill(state.fill)
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: UsageStatsMetrics.calendarCellRadius, style: .continuous
                        )
                        .fill(state.isSelectable && hoveredDay == day ? AppPalette.rowHover : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsCompactButtonStyle())
            .disabled(!state.isSelectable)
            .onHover { isHovering in
                if isHovering {
                    hoveredDay = day
                } else if hoveredDay == day {
                    hoveredDay = nil
                }
            }
            .accessibilityLabel(
                Text(
                    UsageStatsFormat.bucketLabel(day, granularity: .day, locale: locale))
            )
        } else {
            Color.clear
                .frame(
                    width: UsageStatsMetrics.calendarCellWidth,
                    height: UsageStatsMetrics.calendarCellHeight
                )
        }
    }

    /// 一格日期的状态：底色、文字色与可点性。
    private struct DayCellState {
        var fill: Color
        var textColor: Color
        var isSelectable: Bool
    }

    private func cellState(for day: Date) -> DayCellState {
        let today = UsageStatsCalendar.startOfDay(Date())
        // 未来日永远不会有数据，选中它只会得到一片空桶。
        guard day <= today else {
            return DayCellState(fill: .clear, textColor: AppPalette.subtleText, isSelectable: false)
        }

        let from = viewModel.customFrom
        let to = viewModel.customTo
        if day == from || day == to {
            return DayCellState(
                fill: AppPalette.segmentedThumb, textColor: AppPalette.primaryText, isSelectable: true)
        }
        if let from, day >= from, day <= (to ?? from) {
            return DayCellState(
                fill: AppPalette.segmentedTrack, textColor: AppPalette.primaryText, isSelectable: true)
        }
        if day == today {
            return DayCellState(fill: .clear, textColor: AppPalette.accent, isSelectable: true)
        }
        return DayCellState(
            fill: .clear, textColor: AppPalette.secondaryText, isSelectable: true)
    }

    // MARK: - 读数行

    /// 读数行：范围落定后给出读数，只落了起点时给出下一步提示。
    private var readout: some View {
        HStack(spacing: 0) {
            if let from = viewModel.customFrom, let to = viewModel.customTo {
                Text(UsageStatsFormat.customRange(from: from, to: to, locale: locale))
                    .font(.system(size: 10))
                    .foregroundColor(AppPalette.secondaryText)
            } else {
                Text(l10n.t("Pick a start day, then an end day."))
                    .font(.system(size: 10))
                    .foregroundColor(AppPalette.subtleText)
            }

            Spacer(minLength: 0)
        }
        .frame(height: UsageStatsMetrics.calendarReadoutHeight)
    }
}
