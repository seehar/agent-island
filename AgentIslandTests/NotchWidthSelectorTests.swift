//
//  NotchWidthSelectorTests.swift
//  AgentIslandTests
//
//  胶囊宽度的用例：档位要落盘（否则重启就回到自动）、偏好里的坏值要夹回范围、
//  夹紧必须把物理刘海宽度当下限（有刘海的屏幕上把胶囊调得比挖孔还窄会露出挖孔）、
//  展开高度要按选项数算进面板。全部在独立偏好域里跑，不碰用户的真实偏好。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@MainActor
@Suite("胶囊宽度设置")
struct NotchWidthSelectorTests {
    /// 每个用例一个独立偏好域。
    private func makeDefaults() throws -> UserDefaults {
        let name = "agent-island-notch-width-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("默认自动；微调后落盘，重建后仍是自定义宽度")
    func customWidthPersists() throws {
        let defaults = try makeDefaults()
        let selector = NotchWidthSelector(defaults: defaults)
        #expect(selector.mode == .automatic)
        // 拿不到屏幕时自动模式退回典型刘海宽度
        #expect(selector.resolvedWidth(for: nil) == NotchWidthSelector.fallbackNotchWidth)

        selector.stepWidth(by: 20, on: nil)

        let reloaded = NotchWidthSelector(defaults: defaults)
        #expect(reloaded.mode == .custom)
        #expect(reloaded.customWidth == NotchWidthSelector.fallbackNotchWidth + 20)
    }

    @Test("回到自动后不再跟随自定义值")
    func selectingAutomaticDropsCustom() throws {
        let selector = NotchWidthSelector(defaults: try makeDefaults())
        selector.stepWidth(by: 40, on: nil)
        #expect(selector.resolvedWidth(for: nil) != NotchWidthSelector.fallbackNotchWidth)

        selector.selectAutomatic()

        #expect(selector.mode == .automatic)
        #expect(selector.resolvedWidth(for: nil) == NotchWidthSelector.fallbackNotchWidth)
    }

    @Test("偏好里的未知模式回退自动，超范围的宽度被夹回区间")
    func storedGarbageIsClamped() throws {
        let defaults = try makeDefaults()
        defaults.set("gigantic", forKey: "notchWidthMode")
        defaults.set(5000.0, forKey: "notchWidthCustom")
        #expect(NotchWidthSelector(defaults: defaults).mode == .automatic)

        defaults.set(NotchWidthMode.custom.rawValue, forKey: "notchWidthMode")
        #expect(
            NotchWidthSelector(defaults: defaults).customWidth == NotchWidthSelector.maximumWidth)

        defaults.set(10.0, forKey: "notchWidthCustom")
        #expect(
            NotchWidthSelector(defaults: defaults).customWidth == NotchWidthSelector.minimumWidth)
    }

    @Test("有物理刘海时下限抬到挖孔宽度，没有刘海时就是微调范围下限")
    func lowerBoundFollowsNotch() {
        #expect(NotchWidthSelector.lowerBound(notchHeight: 0, notchWidth: 224)
            == NotchWidthSelector.minimumWidth)
        #expect(NotchWidthSelector.lowerBound(notchHeight: 38, notchWidth: 200) == 200)
        // 挖孔比微调范围下限还窄时仍取下限，避免出现比范围更小的值
        #expect(NotchWidthSelector.lowerBound(notchHeight: 38, notchWidth: 100)
            == NotchWidthSelector.minimumWidth)
    }

    @Test("夹紧：落进微调范围，且不窄于刘海宽度")
    func clampRespectsRangeAndNotchFloor() {
        // 无刘海（下限 = 微调范围下限）：两侧都夹
        #expect(
            NotchWidthSelector.clamped(10, lowerBound: NotchWidthSelector.minimumWidth)
                == NotchWidthSelector.minimumWidth)
        #expect(
            NotchWidthSelector.clamped(9999, lowerBound: NotchWidthSelector.minimumWidth)
                == NotchWidthSelector.maximumWidth)
        // 有刘海（下限 = 刘海宽度）：比挖孔窄的一律抬到挖孔宽度
        #expect(NotchWidthSelector.clamped(150, lowerBound: 200) == 200)
        #expect(NotchWidthSelector.clamped(260, lowerBound: 200) == 260)
        #expect(NotchWidthSelector.clamped(200, lowerBound: 200) == 200)
    }

    @Test("微调到上限就不再增加")
    func steppingStopsAtMaximum() throws {
        let selector = NotchWidthSelector(defaults: try makeDefaults())

        for _ in 0..<400 { selector.stepWidth(by: NotchWidthSelector.step, on: nil) }

        #expect(selector.mode == .custom)
        #expect(selector.customWidth == NotchWidthSelector.maximumWidth)
    }

    @Test("展开高度按选项数计入面板，收起时为 0")
    func expandedHeightTracksPickerState() throws {
        let selector = NotchWidthSelector(defaults: try makeDefaults())
        #expect(selector.expandedPickerHeight == 0)

        selector.isPickerExpanded = true
        // 「自动」一个选项 + 一行微调
        #expect(
            selector.expandedPickerHeight == NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 2)
        )
    }

    @Test("标称宽度只加长胶囊中间那段：胶囊宽度随它 1:1 增长，两侧耳位完全不参与")
    func nominalWidthOnlyLengthensTheMiddleSection() {
        // 「计数避开相机挖孔」只由耳宽决定（推导见 `NotchClosedMetrics` 文件头）：把胶囊调宽
        // 不该把计数推进挖孔里，也不该让计数换档；边界各向外长一半。
        let ear: CGFloat = 30
        let narrow = NotchClosedMetrics.capsuleSize(
            notchSize: CGSize(width: 200, height: 32), earWidth: ear, showsEars: true)
        let wide = NotchClosedMetrics.capsuleSize(
            notchSize: CGSize(width: 300, height: 32), earWidth: ear, showsEars: true)

        #expect(wide.width - narrow.width == 100, "标称宽 +100 → 画出来的胶囊宽 +100")
        #expect(wide.width / 2 - narrow.width / 2 == 50, "多出来的宽度两侧平分，耳位不动")
        #expect(wide.height == narrow.height)
        // 胶囊始终盖住物理挖孔（两种标称宽下都成立）。
        #expect(narrow.width > 200)
        #expect(wide.width > 300)
    }
}
