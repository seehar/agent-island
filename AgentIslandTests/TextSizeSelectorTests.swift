//
//  TextSizeSelectorTests.swift
//  AgentIslandTests
//
//  内容字号档位的用例：档位要落盘（否则重启就回到默认）、偏好里的坏值要回退到基准档、
//  展开高度要按选项数算进面板（面板高度是常量解析式推出来的，漏算这一项会把展开的
//  选项裁掉）。全部在独立偏好域里跑，不碰用户的真实偏好。
//

import Foundation
import Testing

@testable import AgentIsland

@MainActor
@Suite("内容字号档位")
struct TextSizeSelectorTests {
    /// 每个用例一个独立偏好域。
    private func makeDefaults() throws -> UserDefaults {
        let name = "agent-island-text-size-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("默认基准档；选择后落盘，重建后仍是所选档位")
    func selectionPersists() throws {
        let defaults = try makeDefaults()
        let selector = TextSizeSelector(defaults: defaults)
        #expect(selector.option == .standard)
        #expect(selector.scale == 1)

        selector.select(.extraLarge)

        #expect(TextSizeSelector(defaults: defaults).option == .extraLarge)
        #expect(TextSizeSelector(defaults: defaults).scale == TextSizeOption.extraLarge.scale)
    }

    @Test("偏好里是未知档位时回退到基准档")
    func unknownStoredValueFallsBack() throws {
        let defaults = try makeDefaults()
        defaults.set("gigantic", forKey: "textSizeOption")

        #expect(TextSizeSelector(defaults: defaults).option == .standard)
    }

    @Test("档位比例随档位递增，且基准档正好是 1")
    func scalesIncreaseWithOption() {
        let scales = TextSizeOption.allCases.map(\.scale)

        #expect(scales == scales.sorted())
        #expect(Set(scales).count == scales.count)
        #expect(TextSizeOption.standard.scale == 1)
    }

    @Test("展开高度按选项数计入面板，收起时为 0")
    func expandedHeightTracksPickerState() throws {
        let selector = TextSizeSelector(defaults: try makeDefaults())
        #expect(selector.expandedPickerHeight == 0)

        selector.isPickerExpanded = true
        #expect(
            selector.expandedPickerHeight
                == NotchMenuMetrics.pickerOptionsHeight(
                    visibleOptions: TextSizeOption.allCases.count))
    }
}
