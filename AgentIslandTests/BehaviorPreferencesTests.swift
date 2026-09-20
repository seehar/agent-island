//
//  BehaviorPreferencesTests.swift
//  AgentIslandTests
//
//  行为偏好（枚举档位）的用例：档位要落盘、坏值要回退默认档、每个档位的数值映射得与
//  文案说的是同一件事（延时、窗口、比例、间隔），以及「已结束的会话」的移除判据。
//  另有一条结构性判据：行为页的单个选择器不超过 4 档——再多就会顶到窗口留出的
//  可用高度（见 NotchMenuMetrics.maxPanelHeight 的注释）。
//  全部在独立偏好域里跑，不碰用户真实偏好。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@MainActor
@Suite("行为偏好")
struct BehaviorPreferencesTests {
    /// 每个用例一个独立偏好域。
    private func makeDefaults() throws -> UserDefaults {
        let name = "agent-island-behavior-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    // MARK: - 读写

    /// 逐档位类型跑一遍：默认值 → 换成非默认档 → 重建后仍是它 → 坏值回退默认档。
    private func roundTrip<P: PreferenceOption>(_ type: P.Type) throws {
        let defaults = try makeDefaults()
        #expect(PreferenceStore.read(type, defaults: defaults) == P.defaultValue)

        let other = try #require(P.allCases.first { $0 != P.defaultValue })
        PreferenceStore.write(other, defaults: defaults)
        #expect(PreferenceStore.read(type, defaults: defaults) == other)

        defaults.set("no-such-option", forKey: P.preferenceKey)
        #expect(PreferenceStore.read(type, defaults: defaults) == P.defaultValue)
    }

    @Test("每个档位类型都能落盘，坏值回退默认档")
    func everyPreferenceRoundTrips() throws {
        try roundTrip(HoverExpand.self)
        try roundTrip(CompletionBadge.self)
        try roundTrip(PanelSize.self)
        try roundTrip(IdleNotchVisibility.self)
        try roundTrip(SessionRetention.self)
        try roundTrip(SessionRowDensity.self)
        try roundTrip(RefreshCadence.self)
        try roundTrip(NotificationScope.self)
        try roundTrip(SessionRowClickAction.self)
    }

    @Test("选择器：选择后落盘，展开高度按档位数算")
    func selectorPersistsAndReportsHeight() throws {
        let defaults = try makeDefaults()
        let selector = EnumPreference<PanelSize>(defaults: defaults)
        #expect(selector.option == .standard)
        #expect(selector.expandedPickerHeight == 0)

        selector.select(.wide)

        #expect(EnumPreference<PanelSize>(defaults: defaults).option == .wide)
        selector.isPickerExpanded = true
        #expect(
            selector.expandedPickerHeight
                == NotchMenuMetrics.pickerOptionsHeight(visibleOptions: PanelSize.allCases.count))
    }

    @Test("行为页的每个选择器都不超过 4 档（面板高度的硬约束）")
    func pickerOptionCountsStayWithinPanelBudget() {
        let counts = [
            HoverExpand.allCases.count,
            CompletionBadge.allCases.count,
            PanelSize.allCases.count,
            IdleNotchVisibility.allCases.count,
            SessionRetention.allCases.count,
            SessionRowDensity.allCases.count,
            RefreshCadence.allCases.count,
            NotificationScope.allCases.count,
            SessionRowClickAction.allCases.count,
        ]
        #expect(counts.allSatisfy { $0 <= 4 })
    }

    // MARK: - 档位语义

    @Test("悬停展开：档位给出延时，关闭档不自动展开")
    func hoverExpandDelays() {
        #expect(HoverExpand.off.delay == nil)

        let delays = [HoverExpand.fast, .standard, .slow].compactMap(\.delay)
        #expect(delays.count == 3)
        #expect(delays == delays.sorted())
        #expect(delays.allSatisfy { $0 > 0 })
    }

    @Test("完成提示：窗口递增，「一直显示」档没有窗口")
    func completionBadgeWindows() {
        #expect(CompletionBadge.persistent.window == nil)

        let windows = [CompletionBadge.short, .standard, .long].compactMap(\.window)
        #expect(windows.count == 3)
        #expect(windows == windows.sorted())
    }

    @Test("面板尺寸：基准档是 1，紧凑更小、宽档更大")
    func panelSizeScales() {
        #expect(PanelSize.standard.scale == 1)
        #expect(PanelSize.compact.scale < 1)
        #expect(PanelSize.wide.scale > 1)
    }

    @Test("空闲可见性：只有「一直显示」档不隐藏，保留档的延时长于立即档")
    func idleVisibilityHiding() {
        #expect(!IdleNotchVisibility.always.hidesWhenIdle)
        #expect(IdleNotchVisibility.whenActive.hidesWhenIdle)
        #expect(IdleNotchVisibility.linger.hidesWhenIdle)
        #expect(
            IdleNotchVisibility.linger.lingerWindow
                > IdleNotchVisibility.whenActive.lingerWindow)
    }

    @Test("刷新频率：状态复核随档位变慢，目录扫描不比它更快")
    func refreshCadences() {
        #expect(RefreshCadence.fast.statusSeconds < RefreshCadence.standard.statusSeconds)
        #expect(RefreshCadence.standard.statusSeconds < RefreshCadence.relaxed.statusSeconds)
        #expect(RefreshCadence.standard.discoverySeconds >= RefreshCadence.standard.statusSeconds)
    }

    @Test("已结束会话：立即档等于结束就移除，其余档按窗口保留")
    func endedSessionRetention() {
        let now = Date()
        let endedAMinuteAgo = now.addingTimeInterval(-60)

        #expect(
            SessionStore.shouldDropEndedSession(
                phase: .ended, lastActivity: endedAMinuteAgo, retention: .immediate, now: now))
        #expect(
            !SessionStore.shouldDropEndedSession(
                phase: .ended, lastActivity: endedAMinuteAgo, retention: .tenMinutes, now: now))
        #expect(
            SessionStore.shouldDropEndedSession(
                phase: .ended, lastActivity: now.addingTimeInterval(-700),
                retention: .tenMinutes, now: now))
        // 非结束态不归这条判据管
        #expect(
            !SessionStore.shouldDropEndedSession(
                phase: .idle, lastActivity: endedAMinuteAgo, retention: .immediate, now: now))
    }

    @Test("列表密度：紧凑档不画活动行与用量，详细档多一行工作目录")
    func rowDensityFlags() {
        #expect(!SessionRowDensity.compact.showsActivityLine)
        #expect(!SessionRowDensity.compact.showsTokenUsage)
        #expect(!SessionRowDensity.compact.showsWorkingDirectory)

        #expect(SessionRowDensity.standard.showsActivityLine)
        #expect(SessionRowDensity.standard.showsTokenUsage)
        #expect(!SessionRowDensity.standard.showsWorkingDirectory)

        #expect(SessionRowDensity.detailed.showsWorkingDirectory)
    }

    @Test("提示音范围：只有含审批的档位覆盖审批请求")
    func notificationScopeCoversApprovals() {
        #expect(!NotificationScope.readyOnly.coversApprovals)
        #expect(NotificationScope.readyAndApprovals.coversApprovals)
    }

    @Test("单击动作默认不做事（保持双击进聊天）")
    func clickActionDefaultsToNone() {
        #expect(SessionRowClickAction.defaultValue == .none)
    }
}
