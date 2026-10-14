//
//  UsageHeatmapScale.swift
//  AgentIsland
//
//  热力图的强度分档：把「某一格的总量」映射成 0…4 五档。与视图无关（纯函数），
//  因此档位切法与边界都能逐点断言。
//
//  阈值取**非零日**的 50 / 75 / 90 分位，不是按峰值等分的线性档：用量按天分布极不
//  均匀（本机实测：忙日以十亿计、闲日以百万计，相差三个量级），线性档会把绝大多数
//  日子挤进最低档。分位档的语义是「相对你自己的节奏」——最深的那一档 = 你的高产日。
//

import Foundation

/// 热力图的强度分档。
nonisolated enum UsageHeatmapScale {
    /// 档位数（不含「没有用量」的 0 档）。
    static let levelCount = 4

    /// 三个分位点：中位 / 上四分位 / 九成位。
    private static let quantiles: [Double] = [0.5, 0.75, 0.9]

    /// 三个阈值（升序）。样本是**窗口内所有自然日的总量**（含 0 的那些天；0 档不参与分位）。
    ///
    /// 非零日少于 `levelCount` 天时（刚装上、刚清过库）分位没有统计意义：阈值一律取 0，
    /// 于是任何有量的日子都落到最深一档——「唯一的那个大日子显示成最浅」比它更糟。
    static func thresholds(of totals: [Int]) -> [Int] {
        let nonzero = totals.filter { $0 > 0 }.sorted()
        guard nonzero.count >= levelCount else {
            return Array(repeating: 0, count: quantiles.count)
        }
        return quantiles.map { quantile(of: nonzero, at: $0) }
    }

    /// 某一格落在哪一档：0 = 没有用量，1…`levelCount` 由阈值切开（超过第 i 个阈值就多一档）。
    static func level(total: Int, thresholds: [Int]) -> Int {
        guard total > 0 else { return 0 }
        return thresholds.filter { total > $0 }.count + 1
    }

    /// 最近秩法分位（`sorted` 升序、非空，`p ∈ [0, 1]`）：取 `⌊(n−1)p⌋` 号元素。
    /// 确定性的整数下标、不插值——阈值是给分档用的，插出来的小数没有意义（分档只看大小关系）。
    private static func quantile(of sorted: [Int], at p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded(.down))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
