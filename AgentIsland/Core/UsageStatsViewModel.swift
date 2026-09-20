//
//  UsageStatsViewModel.swift
//  AgentIsland
//
//  统计页的状态：当前时间窗口 + 该窗口的快照。视图只读这里，不自己算口径
//  （总量、命中率、排序都由 `UsageStatsSnapshot` 给出）。
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
    /// 当前展示的时间窗口。
    @Published var range: StatsRange = .today
    /// 当前窗口的快照；没有数据时就是 `.empty`。
    @Published var snapshot: UsageStatsSnapshot = .empty

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

    /// 切换时间窗口并重取快照。
    func select(_ range: StatsRange) {
        self.range = range
        reload()
    }

    // MARK: - 取快照

    private func reload() {
        requestSequence += 1
        let sequence = requestSequence
        let requested = range

        Task {
            let fresh = await indexer.snapshot(for: requested)
            // 过期返回（期间换了窗口，或已有更新的请求在飞）直接丢弃。
            guard sequence == requestSequence, requested == range else { return }
            snapshot = fresh
        }
    }
}
