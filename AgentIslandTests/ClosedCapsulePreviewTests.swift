//
//  ClosedCapsulePreviewTests.swift
//  AgentIslandTests
//
//  关闭态胶囊预览的比例：预览盒代表整个可调区间，因此任何合法取值都装得下，
//  而且两个方向都随入参单调增长（不能在某一端饱和——那正是「等比例缩放」方案的毛病）。
//

import CoreGraphics
import Testing

@testable import AgentIsland

@MainActor
@Suite("关闭态胶囊预览")
struct ClosedCapsulePreviewTests {
    /// 与真实预览盒同形：一行选项高（32）减去上下边距后是 20，宽度取标准档的一项内容宽。
    private let box = CGSize(width: 300, height: 20)

    @Test("整个可调区间都装得下：任何合法取值都不越出预览盒")
    func everyLegalValueFitsTheBox() {
        for width in stride(
            from: NotchWidthSelector.minimumWidth, through: NotchWidthSelector.maximumWidth, by: 8)
        {
            for height in stride(
                from: NotchHeightSelector.minimumHeight,
                through: NotchHeightSelector.maximumHeight, by: 2)
            {
                let size = ClosedCapsulePreview.fittedSize(
                    width: width, height: height, in: box)
                #expect(size.width <= box.width + 0.0001, "宽度 \(width) 越出预览盒")
                #expect(size.height <= box.height + 0.0001, "高度 \(height) 越出预览盒")
                #expect(size.width > 0 && size.height > 0, "\(width)×\(height) 画没了")
            }
        }
    }

    @Test("上限那一档：受约束的方向正好占满预览盒")
    func maxValuesFillTheConstrainedAxis() {
        let size = ClosedCapsulePreview.fittedSize(
            width: NotchWidthSelector.maximumWidth,
            height: NotchHeightSelector.maximumHeight,
            in: box)
        // 预览盒是扁的（300×20），限制轴是高度
        #expect(abs(size.height - box.height) < 0.0001)
        #expect(size.width < box.width)
    }

    @Test("剪影的圆角跟着身子同一个比例缩：预览盒减半，圆角也减半")
    func cornerRadiiScaleWithTheSilhouette() {
        let full = ClosedCapsulePreview.shape(in: box)
        let half = ClosedCapsulePreview.shape(
            in: CGSize(width: box.width / 2, height: box.height / 2))

        #expect(abs(half.topCornerRadius - full.topCornerRadius / 2) < 0.0001)
        #expect(abs(half.bottomCornerRadius - full.bottomCornerRadius / 2) < 0.0001)
        // 圆角必须真的缩了：不缩的话 6/14pt 的角配一块 62×10 的身子会画成一只「托盘」。
        #expect(full.topCornerRadius < AppRadius.panelClosedTop)
        #expect(half.bottomCornerRadius < full.bottomCornerRadius)
    }

    @Test("两个方向都单调：最宽的几档看上去必须不一样宽")
    func bothDimensionsGrowMonotonically() {
        let wide = ClosedCapsulePreview.fittedSize(width: 520, height: 32, in: box)
        let wider = ClosedCapsulePreview.fittedSize(width: 480, height: 32, in: box)
        #expect(wider.width < wide.width, "上限附近饱和了：480 与 520 画出来一样宽")

        let tall = ClosedCapsulePreview.fittedSize(width: 224, height: 64, in: box)
        let taller = ClosedCapsulePreview.fittedSize(width: 224, height: 60, in: box)
        #expect(taller.height < tall.height, "上限附近饱和了：60 与 64 画出来一样高")
    }
}
