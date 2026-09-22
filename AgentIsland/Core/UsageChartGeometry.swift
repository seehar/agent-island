//
//  UsageChartGeometry.swift
//  AgentIsland
//
//  统计曲线图的坐标换算与插值：把「桶序号 × 值」投影进绘图区，并把折线变成不过冲的
//  平滑曲线。与视图无关（纯函数），因此曲线的形状与悬停命中都能逐点断言。
//

import CoreGraphics

/// 曲线图的坐标换算。
///
/// 绘图区是最小单位：左侧 y 轴刻度栏与下方横轴行都在它之外，调用方传进来的就是「图本身」
/// 的尺寸。五路序列共用一根 y 轴（按可见路的窗内峰值归一），换算因此只有这一份。
nonisolated struct UsageChartGeometry: Equatable {
    /// 绘图区宽度。
    var plotWidth: CGFloat
    /// 绘图区高度。
    var plotHeight: CGFloat

    /// 第 `index` 个桶的 x；只有一个桶时落在中线。
    func x(index: Int, count: Int) -> CGFloat {
        guard plotWidth > 0 else { return 0 }
        guard count > 1 else { return plotWidth / 2 }
        return plotWidth * CGFloat(index) / CGFloat(count - 1)
    }

    /// 值 `value` 在峰值 `peak` 下的 y：0 在底、`peak` 在顶；峰值非正时一律贴底。
    func y(value: Int, peak: Int) -> CGFloat {
        guard peak > 0 else { return plotHeight }
        let ratio = CGFloat(max(0, min(value, peak))) / CGFloat(peak)
        return plotHeight * (1 - ratio)
    }

    /// 离 `x` 最近的桶序号（超界夹到两端）。
    ///
    /// `x` 必须先是有限值：`Int(CGFloat.nan)` / `Int(CGFloat.infinity)` 在 Swift 里是
    /// 运行时 trap（不是夹取），而 hover 坐标由框架给出，不能假定它永远有限。
    func nearestIndex(x: CGFloat, count: Int) -> Int {
        guard x.isFinite else { return 0 }
        guard count > 1, plotWidth > 0 else { return 0 }
        let raw = Int((x / plotWidth * CGFloat(count - 1)).rounded())
        return min(max(raw, 0), count - 1)
    }

    /// 把一列值投影成绘图区内的点（x 均匀升序）。
    func points(values: [Int], peak: Int) -> [CGPoint] {
        values.enumerated().map { index, value in
            CGPoint(x: x(index: index, count: values.count), y: y(value: value, peak: peak))
        }
    }
}

/// 单调三次插值：曲线过每个点且不过冲——每一段的 y 都落在两端点的值域内，因此不会出现
/// 「底边附近抖出负值」或「峰值被顶得更高」这类视觉谎话。
///
/// 不过冲来自**切线的取法**：内部点的切线取两侧割线斜率的**调和平均**（两侧异号时取 0，
/// 即极值点处切线水平），端点取相邻割线斜率。调和平均 ≤ 2 × min(两侧斜率)，于是限制器要算
/// 的 α² + β² 恒不超过 4（等斜率时取到 2、斜率悬殊时趋近 4）、永远触发不了——教科书里那个 Fritsch–Carlson 限制器在这里
/// 是死代码：消融实测删掉它，`UsageChartGeometryTests.curveNeverOvershoots` 仍然全绿，
/// 因此不再保留。**改动切线取法时必须把那一段限制器补回来。**
nonisolated enum UsageChartCurve {
    /// 相邻两点之间的一对贝塞尔控制点；点数 < 2 时返回空数组。
    static func controlPoints(_ points: [CGPoint]) -> [(CGPoint, CGPoint)] {
        guard points.count >= 2 else { return [] }

        let count = points.count
        var spans = [CGFloat](repeating: 0, count: count - 1)
        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let span = points[index + 1].x - points[index].x
            spans[index] = span
            slopes[index] = span == 0 ? 0 : (points[index + 1].y - points[index].y) / span
        }

        // 切线：两端取相邻斜率；内部符号相反处取 0（该点是极值），否则取两个斜率的调和平均。
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            let previous = slopes[index - 1]
            let next = slopes[index]
            tangents[index] = previous * next <= 0 ? 0 : 2 / (1 / previous + 1 / next)
        }

        return (0..<(count - 1)).map { index in
            let span = spans[index]
            let control1 = CGPoint(
                x: points[index].x + span / 3,
                y: points[index].y + tangents[index] * span / 3)
            let control2 = CGPoint(
                x: points[index + 1].x - span / 3,
                y: points[index + 1].y - tangents[index + 1] * span / 3)
            return (control1, control2)
        }
    }
}
