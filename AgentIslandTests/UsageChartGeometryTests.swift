//
//  UsageChartGeometryTests.swift
//  AgentIslandTests
//
//  曲线图的坐标换算与平滑插值：多路共用的单轴投影、悬停命中最近的桶、以及
//  「曲线过每个点且不过冲」这条形状不变量（平滑曲线的视觉诚实全靠它）。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("曲线图几何")
struct UsageChartGeometryTests {
  private let geometry = UsageChartGeometry(plotWidth: 400, plotHeight: 120)

  /// 三次贝塞尔在 `t` 处的取值：端点断言用它（只看控制点无法证明曲线真的过点）。
  private func evaluate(
    _ control1: CGPoint, _ control2: CGPoint, from start: CGPoint, to end: CGPoint, t: CGFloat
  ) -> CGPoint {
    let remaining = 1 - t
    let x =
      remaining * remaining * remaining * start.x
      + 3 * remaining * remaining * t * control1.x
      + 3 * remaining * t * t * control2.x
      + t * t * t * end.x
    let y =
      remaining * remaining * remaining * start.y
      + 3 * remaining * remaining * t * control1.y
      + 3 * remaining * t * t * control2.y
      + t * t * t * end.y
    return CGPoint(x: x, y: y)
  }

  @Test("x 均匀铺满绘图区：首尾贴边、中间等分、单桶落中线")
  func xSpansPlotWidth() {
    #expect(geometry.x(index: 0, count: 5) == 0)
    #expect(geometry.x(index: 4, count: 5) == 400)
    #expect(geometry.x(index: 2, count: 5) == 200)
    #expect(geometry.x(index: 0, count: 1) == 200)
    // 宽度尚未定下来（布局中）时不产生 NaN。
    #expect(UsageChartGeometry(plotWidth: 0, plotHeight: 120).x(index: 1, count: 3) == 0)
  }

  @Test("y：0 贴底、峰值贴顶，峰值非正时一律贴底")
  func yPutsZeroAtBottomAndPeakAtTop() {
    #expect(geometry.y(value: 0, peak: 100) == 120)
    #expect(geometry.y(value: 100, peak: 100) == 0)
    #expect(geometry.y(value: 50, peak: 100) == 60)
    #expect(geometry.y(value: 7, peak: 0) == 120)
    // 超出峰值的值被夹住（换窗口时数字先到、峰值后到的过渡帧）。
    #expect(geometry.y(value: 150, peak: 100) == 0)
  }

  @Test("悬停命中最接近的桶，超出两端时夹住")
  func nearestIndexClampsAtEdges() {
    #expect(geometry.nearestIndex(x: 0, count: 5) == 0)
    #expect(geometry.nearestIndex(x: -50, count: 5) == 0)
    #expect(geometry.nearestIndex(x: 999, count: 5) == 4)
    #expect(geometry.nearestIndex(x: 210, count: 5) == 2)
    #expect(geometry.nearestIndex(x: 100, count: 1) == 0)
  }

  @Test("非有限的悬停坐标不会 trap，按第一个桶处理")
  func nearestIndexHandlesNonFiniteInput() {
    // `Int(CGFloat.nan)` / `Int(CGFloat.infinity)` 在 Swift 里是运行时 trap（不是夹取）。
    #expect(geometry.nearestIndex(x: .nan, count: 5) == 0)
    #expect(geometry.nearestIndex(x: .infinity, count: 5) == 0)
    #expect(geometry.nearestIndex(x: -.infinity, count: 5) == 0)
  }

  @Test("投影：一列值变成绘图区内的点串")
  func pointsProjectValues() {
    let points = geometry.points(values: [0, 100], peak: 100)
    #expect(points.count == 2)
    #expect(points[0] == CGPoint(x: 0, y: 120))
    #expect(points[1] == CGPoint(x: 400, y: 0))
  }

  @Test("平滑曲线的控制点真按切线算：等间距线性数据的控制点落在直线上")
  func curveControlPointsFollowTangents() {
    // 三次贝塞尔在 t=0 / t=1 处恒等于端点（对**任意**控制点都成立），所以端点等式钉不住
    // 实现。等间距的线性数据才是判别式：切线 == 割线斜率，控制点必然落在那一小段直线上。
    let line = [CGPoint(x: 0, y: 100), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]
    let controls = UsageChartCurve.controlPoints(line)
    #expect(controls.count == line.count - 1)

    for (index, control) in controls.enumerated() {
      let start = line[index]
      let end = line[index + 1]
      let span = end.x - start.x
      let slope = (end.y - start.y) / span
      #expect(abs(control.0.y - (start.y + slope * span / 3)) < 0.001)
      #expect(abs(control.1.y - (end.y - slope * span / 3)) < 0.001)
      #expect(abs(control.0.x - (start.x + span / 3)) < 0.001)
      #expect(abs(control.1.x - (end.x - span / 3)) < 0.001)
    }

    // 控制点必须落在相邻两点的值域内（单调三次插值的构造性质，不是恒真式）。
    let shapes: [[CGPoint]] = [
      [CGPoint(x: 0, y: 120), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 120)],
      [
        CGPoint(x: 0, y: 100), CGPoint(x: 8, y: 100), CGPoint(x: 16, y: 0),
        CGPoint(x: 120, y: 0), CGPoint(x: 128, y: 100),
      ],
    ]
    for points in shapes {
      for (index, control) in UsageChartCurve.controlPoints(points).enumerated() {
        let low = min(points[index].y, points[index + 1].y)
        let high = max(points[index].y, points[index + 1].y)
        #expect(control.0.y >= low - 0.001 && control.0.y <= high + 0.001)
        #expect(control.1.y >= low - 0.001 && control.1.y <= high + 0.001)
      }
    }
  }

  @Test("平滑曲线不过冲：每一段的 y 都落在两端点的值域内")
  func curveNeverOvershoots() {
    // 单峰、单谷、陡升陡降各来一组。不过冲来自切线取的是**调和平均**（见
    // `UsageChartCurve` 的说明）：把切线换成平均斜率或三点差分，这组数据就会过冲——
    // 下面的疏密不均那两例就是为这种退化准备的反例。
    let shapes: [[CGPoint]] = [
      [CGPoint(x: 0, y: 120), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 120)],
      [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 120), CGPoint(x: 200, y: 0)],
      [
        CGPoint(x: 0, y: 120), CGPoint(x: 50, y: 118), CGPoint(x: 100, y: 2),
        CGPoint(x: 150, y: 0), CGPoint(x: 200, y: 90),
      ],
      [CGPoint(x: 0, y: 30), CGPoint(x: 200, y: 30)],
      // 疏密不均的 x：窄段里的大落差最容易把切线推过头。
      [
        CGPoint(x: 0, y: 100), CGPoint(x: 8, y: 100), CGPoint(x: 16, y: 0),
        CGPoint(x: 120, y: 0), CGPoint(x: 128, y: 100), CGPoint(x: 200, y: 100),
      ],
      [
        CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 120), CGPoint(x: 180, y: 120),
        CGPoint(x: 200, y: 0),
      ],
    ]

    for points in shapes {
      for (index, control) in UsageChartCurve.controlPoints(points).enumerated() {
        let start = points[index]
        let end = points[index + 1]
        let low = min(start.y, end.y)
        let high = max(start.y, end.y)
        for step in 0...20 {
          let t = CGFloat(step) / 20
          let value = evaluate(control.0, control.1, from: start, to: end, t: t).y
          #expect(
            value >= low - 0.001 && value <= high + 0.001,
            "第 \(index) 段 t=\(t) 的 y=\(value) 越过了 [\(low), \(high)]")
        }
      }
    }
  }

  @Test("平坦数据退化成直线，点数不足时不产生控制点")
  func curveHandlesFlatAndShortInput() {
    let flat = [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 50)]
    for (index, control) in UsageChartCurve.controlPoints(flat).enumerated() {
      let start = flat[index]
      let end = flat[index + 1]
      #expect(control.0.y == start.y)
      #expect(control.1.y == end.y)
      #expect(control.0.x > start.x && control.0.x < end.x)
      #expect(control.1.x > start.x && control.1.x < end.x)
    }

    #expect(UsageChartCurve.controlPoints([]).isEmpty)
    #expect(UsageChartCurve.controlPoints([CGPoint(x: 0, y: 10)]).isEmpty)
  }
}
