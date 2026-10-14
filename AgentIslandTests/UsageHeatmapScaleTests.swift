//
//  UsageHeatmapScaleTests.swift
//  AgentIslandTests
//
//  热力图的分档：阈值只由非零日决定、边界取「等于阈值算低一档」、样本太少时不把
//  唯一的高产日画成最浅。这些判据直接决定用户看到的深浅，因此逐点钉住。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("热力图分档")
struct UsageHeatmapScaleTests {
  @Test("阈值取非零日的 50 / 75 / 90 分位（最近秩法，不插值）")
  func thresholdsUseQuantilesOfNonzeroDays() {
    // 1…10 十个非零日：⌊9×0.5⌋=4 → 5；⌊9×0.75⌋=6 → 7；⌊9×0.9⌋=8 → 9。
    let totals = Array(1...10)
    #expect(UsageHeatmapScale.thresholds(of: totals) == [5, 7, 9])

    // 零值不参与分位：混进 20 个 0 之后阈值不变（0 档是「没有用量」，不是最小用量）。
    #expect(UsageHeatmapScale.thresholds(of: totals + Array(repeating: 0, count: 20)) == [5, 7, 9])

    // 乱序输入先排序再取分位。
    #expect(UsageHeatmapScale.thresholds(of: totals.shuffled()) == [5, 7, 9])
  }

  @Test("档位：等于阈值算低一档，超过才算高一档；0 恒为 0 档")
  func levelStepsAtThresholds() {
    let thresholds = [5, 7, 9]

    #expect(UsageHeatmapScale.level(total: 0, thresholds: thresholds) == 0)
    for total in 1...5 {
      #expect(UsageHeatmapScale.level(total: total, thresholds: thresholds) == 1)
    }
    #expect(UsageHeatmapScale.level(total: 6, thresholds: thresholds) == 2)
    #expect(UsageHeatmapScale.level(total: 7, thresholds: thresholds) == 2)
    #expect(UsageHeatmapScale.level(total: 8, thresholds: thresholds) == 3)
    #expect(UsageHeatmapScale.level(total: 9, thresholds: thresholds) == 3)
    #expect(UsageHeatmapScale.level(total: 10, thresholds: thresholds) == 4)
    // 峰值再大也不越档：色阶只有 5 格。
    #expect(
      UsageHeatmapScale.level(total: 9_999_999_999, thresholds: thresholds)
        == UsageHeatmapScale.levelCount)
  }

  @Test("样本太少（非零日少于档位数）时不把唯一的高产日画成最浅")
  func sparseSamplesFallBackToDeepestLevel() {
    // 只有一两天有量：分位没有意义 ⇒ 阈值取 0，任何有量的日子都是最深一档。
    for sample in [[], [42], [1, 999], [7, 7, 7]] {
      let thresholds = UsageHeatmapScale.thresholds(of: sample)
      #expect(thresholds == [0, 0, 0], "样本 \(sample)")
      for total in sample {
        #expect(
          UsageHeatmapScale.level(total: total, thresholds: thresholds)
            == UsageHeatmapScale.levelCount)
      }
      #expect(UsageHeatmapScale.level(total: 0, thresholds: thresholds) == 0)
    }
    // 够 4 个非零日就回到分位口径（不再是「全深」）。
    let thresholds = UsageHeatmapScale.thresholds(of: [1, 2, 3, 100])
    #expect(thresholds != [0, 0, 0])
    #expect(UsageHeatmapScale.level(total: 1, thresholds: thresholds) == 1)
  }

  @Test("档位随总量单调不减")
  func levelIsMonotonic() {
    let thresholds = UsageHeatmapScale.thresholds(of: Array(1...40))
    var previous = 0
    for total in 0...60 {
      let level = UsageHeatmapScale.level(total: total, thresholds: thresholds)
      #expect(level >= previous, "total = \(total)")
      #expect(level >= 0 && level <= UsageHeatmapScale.levelCount)
      previous = level
    }
  }
}
