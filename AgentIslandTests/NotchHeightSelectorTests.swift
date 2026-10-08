//
//  NotchHeightSelectorTests.swift
//  AgentIslandTests
//
//  胶囊高度设置的用例：键入的**绝对值**要夹进微调范围（16…64）、来源要切成「自定义」并
//  落盘、值没变时不重复发几何通知、偏好里的坏值要夹回区间。
//  全部在独立偏好域里跑，不碰用户的真实偏好。
//

import Combine
import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@MainActor
@Suite("胶囊高度设置")
struct NotchHeightSelectorTests {
    /// 每个用例一个独立偏好域。
    private func makeDefaults() throws -> UserDefaults {
        let name = "agent-island-notch-height-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("默认自动；键入后落盘，重建后仍是自定义高度")
    func typedHeightPersists() throws {
        let defaults = try makeDefaults()
        let selector = NotchHeightSelector(defaults: defaults)
        #expect(selector.mode == .automatic)

        selector.setHeight(44)

        #expect(selector.mode == .custom)
        #expect(selector.customHeight == 44)
        // 「自定义」是按屏幕解析的绝对值：换了屏幕也不跟着变
        #expect(selector.resolvedHeight(for: nil) == 44)

        let reloaded = NotchHeightSelector(defaults: defaults)
        #expect(reloaded.mode == .custom)
        #expect(reloaded.customHeight == 44)
    }

    @Test("键入越界一律夹进微调范围")
    func typingClampsToRange() throws {
        let selector = NotchHeightSelector(defaults: try makeDefaults())

        selector.setHeight(0)
        #expect(selector.customHeight == NotchHeightSelector.minimumHeight)

        selector.setHeight(9999)
        #expect(selector.customHeight == NotchHeightSelector.maximumHeight)
    }

    @Test("同一个（夹紧后的）值不重复通知窗口")
    func unchangedValueDoesNotNotify() throws {
        let selector = NotchHeightSelector(defaults: try makeDefaults())

        // 通知就是「立刻换关闭态矩形 / 面板固定开销」那条路径：按发布者过滤，
        // 别的用例、别的选择器发出的通知不算。
        var notified = 0
        let token = NotificationCenter.default.publisher(
            for: .notchGeometryPreferenceChanged, object: selector
        ).sink { _ in notified += 1 }
        defer { token.cancel() }

        // 键入逐字符生效：越界值夹紧后停在同一个数上，不该再通知一遍
        selector.setHeight(0)
        selector.setHeight(5)
        #expect(notified == 1)

        selector.setHeight(30)
        #expect(notified == 2)
    }

    @Test("偏好里的未知模式回退自动，超范围的高度被夹回区间")
    func storedGarbageIsClamped() throws {
        let defaults = try makeDefaults()
        defaults.set("gigantic", forKey: "notchHeightMode")
        defaults.set(5000.0, forKey: "notchHeightCustom")
        #expect(NotchHeightSelector(defaults: defaults).mode == .automatic)

        defaults.set(NotchHeightMode.custom.rawValue, forKey: "notchHeightMode")
        #expect(
            NotchHeightSelector(defaults: defaults).customHeight
                == NotchHeightSelector.maximumHeight)

        defaults.set(1.0, forKey: "notchHeightCustom")
        #expect(
            NotchHeightSelector(defaults: defaults).customHeight
                == NotchHeightSelector.minimumHeight)
    }
}
