//
//  UsageStatsViewModel.swift
//  AgentIsland
//
//  统计页的状态：当前时间窗口 + 该窗口的快照 + 范围选择器（预设芯片与自选月历）的状态。
//  视图只读这里，不自己算口径（总量、命中率、排序都由 `UsageStatsSnapshot` 给出）。
//

import Combine
import Foundation

/// 统计页的视图模型。
///
/// 快照来自 `UsageStatsIndexer`。索引期间用户可能连点几次范围，而每次查询都是异步的
/// （「全部」比「今天」慢得多），因此每次请求带一个自增序号，回来时只有序号与当前窗口
/// 都还对得上才写入——否则先发出的慢请求会覆盖掉后选中的窗口。
@MainActor
final class UsageStatsViewModel: ObservableObject {
    /// 当前展示的时间窗口（预设档或自选起止）。
    @Published private(set) var window: StatsWindow = .preset(.today)
    /// 当前窗口的快照；没有数据时就是 `.empty`。
    @Published var snapshot: UsageStatsSnapshot = .empty
    /// 页眉控件上的范围选择器是否展开。展开时设置页在分段条与滚动区之间插入选择块，
    /// 滚动视口因此收缩（它不参与面板高度，见 `NotchMenuView`）。
    @Published private(set) var isRangePickerExpanded = false
    /// 月历是否展开：点「自定义…」后为真；选中预设档或落定范围后为假。
    @Published private(set) var isCustomPicking = false
    /// 自选范围的起点（第一下点击）；终点落定前只有它被高亮。
    @Published private(set) var customFrom: Date?
    /// 自选范围的终点；落定后窗口即切到 `.custom`。
    @Published private(set) var customTo: Date?
    /// 月历当前展示的月份（可自由翻月，与已选范围无关）。
    @Published private(set) var calendarMonth: Date = Date()
    /// 曲线图显示哪几路（默认总量 / 输入 / 输出）。
    @Published var visibleSeries: Set<StatsSeries> = StatsSeries.defaultVisible

    private let indexer = UsageStatsIndexer.shared
    private var cancellables = Set<AnyCancellable>()
    /// 已发出的快照请求序号，用于丢弃过期返回。
    private var requestSequence = 0
    /// 是否正显示在面板上（决定要不要跟着索引通知自动重取）。
    private var isActive = false

    init() {
        // 索引器每完成一批扫描都会发一次更新，收到就重取当前窗口的快照。
        indexer.updatesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                // 页面不在前台时不查库：索引器每完成一批都会发通知，长时间挂在别的
                // 内容面上时没必要反复做聚合查询。
                guard let self, self.isActive else { return }
                self.reload()
            }
            .store(in: &cancellables)
    }

    /// 进入统计页时调一次：让索引器立刻做一次增量扫描（内部有节流），
    /// 新数据到达后上面的订阅会重取快照。首轮回填在后台进行，
    /// 因此这里可能先拿到 `isIndexing` 为真的快照。
    func onAppear() {
        isActive = true
        Task {
            await indexer.refreshNow()
            reload()
        }
    }

    /// 离开统计页：停掉随索引通知的自动重取（下次进来会重新取一次）。
    func onDisappear() {
        isActive = false
    }

    /// 手动触发一次「重新统计」：让索引器把每个 Agent 的历史记录从头重读一遍并
    /// 重放（绕过索引器的节流）。这也是唯一能改掉已经统计过的数字的路径——增量
    /// 扫描只读文件的尾巴。进度与结果都由上面的订阅推回来，这里只发请求。
    func rescan() {
        Task {
            await indexer.rebuildNow()
            reload()
        }
    }

    /// 选预设档：切窗口并收起选择器（含月历）。
    func select(_ preset: StatsRange) {
        isCustomPicking = false
        isRangePickerExpanded = false
        apply(.preset(preset))
    }

    /// 展开 / 收起范围选择器。
    ///
    /// 展开时把月历对齐到已选范围：当前是自选范围就回填两个端点、翻到终点所在月；
    /// 否则清空端点、回到当前月——「接着改上一次的选择」比「每次都从头点」顺手。
    func toggleRangePicker() {
        isRangePickerExpanded.toggle()
        guard isRangePickerExpanded else {
            isCustomPicking = false
            return
        }

        if case .custom(let from, let to) = window {
            customFrom = from
            customTo = to
            calendarMonth = to
            isCustomPicking = true
        } else {
            customFrom = nil
            customTo = nil
            calendarMonth = Date()
            isCustomPicking = false
        }
    }

    /// 展开月历（点「自定义…」芯片）。
    func startCustomPicking() {
        isCustomPicking = true
    }

    /// 点月历里的一天。
    ///
    /// 还没有落定的起点（或上一次已经落定）⇒ 这一下是新的起点，只高亮、不查库；
    /// 已经有起点 ⇒ 这一下是终点，与起点归一成「早 – 晚」（用户可能先点晚的那天），
    /// 切窗口并收起选择器——范围已经选完，再占着滚动视口没有意义。
    func pick(day: Date, calendar: Calendar = .current) {
        let day = UsageStatsCalendar.startOfDay(day, calendar: calendar)
        guard let from = customFrom, customTo == nil else {
            customFrom = day
            customTo = nil
            calendarMonth = day
            return
        }

        let range = UsageStatsCalendar.normalized(from, day)
        customFrom = range.from
        customTo = range.to
        isCustomPicking = false
        isRangePickerExpanded = false
        apply(.custom(from: range.from, to: range.to))
    }

    /// 月历翻月（◀ ▶）。
    func stepMonth(_ delta: Int, calendar: Calendar = .current) {
        calendarMonth = UsageStatsCalendar.addMonths(delta, to: calendarMonth, calendar: calendar)
    }

    /// 切换曲线图上某一路的显示。最后一路不允许关掉——关掉就只剩空网格。
    func toggleSeries(_ series: StatsSeries) {
        if visibleSeries.contains(series) {
            guard visibleSeries.count > 1 else { return }
            visibleSeries.remove(series)
        } else {
            visibleSeries.insert(series)
        }
    }

    // MARK: - 取快照

    /// 切窗口并重取快照。
    private func apply(_ new: StatsWindow) {
        window = new
        reload()
    }

    private func reload() {
        requestSequence += 1
        let sequence = requestSequence
        let requested = window

        Task {
            let fresh = await indexer.snapshot(for: requested)
            // 过期返回（期间换了窗口，或已有更新的请求在飞）直接丢弃。
            guard sequence == requestSequence, requested == window else { return }
            snapshot = fresh
        }
    }
}
