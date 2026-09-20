//
//  NotchGeometryTests.swift
//  AgentIslandTests
//
//  刘海与展开面板的命中判定决定「鼠标算不算在面板里」，算错会让面板无法展开或
//  无法收起。这里是纯几何，用固定的屏幕/刘海尺寸把边界钉死。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("刘海与面板几何")
struct NotchGeometryTests {
    /// 1920x1080 的主屏 + 200x32 的刘海。
    private var geometry: NotchGeometry {
        NotchGeometry(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowHeight: 40)
    }

    private var panelSize: CGSize { CGSize(width: 500, height: 648) }

    @Test("刘海矩形居中贴屏幕顶部")
    func notchRectIsCenteredAtTop() {
        let rect = geometry.notchScreenRect
        #expect(rect.midX == 960)
        #expect(rect.maxY == 1080)
        #expect(rect.width == 200)
        #expect(rect.height == 32)
        #expect(rect.minY == 1048)
    }

    @Test("面板矩形按 size 去掉外边距后居中贴顶")
    func openedRectShrinksAndTopAnchors() {
        let rect = geometry.openedScreenRect(for: panelSize)
        #expect(rect.width == 494)
        #expect(rect.height == 618)
        #expect(rect.midX == 960)
        #expect(rect.maxY == 1080)
        #expect(rect.minX == 713)
        #expect(rect.minY == 462)
    }

    @Test("负原点的屏幕（外接屏）仍然贴自己的顶边")
    func screenBelowPrimaryIsHandled() {
        let secondary = NotchGeometry(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            windowHeight: 40)
        #expect(secondary.notchScreenRect.maxY == 0)
        #expect(secondary.notchScreenRect.minY == -32)
        #expect(secondary.openedScreenRect(for: panelSize).maxY == 0)
    }

    @Test("刘海命中带 10/5 的容差，刚好差一点就不算")
    func notchHitTestTolerance() {
        #expect(geometry.isPointInNotch(CGPoint(x: 960, y: 1064)))
        #expect(geometry.isPointInNotch(CGPoint(x: 850.5, y: 1064)))
        #expect(!geometry.isPointInNotch(CGPoint(x: 849.5, y: 1064)))
        #expect(geometry.isPointInNotch(CGPoint(x: 960, y: 1084.5)))
        #expect(!geometry.isPointInNotch(CGPoint(x: 960, y: 1085.5)))
        #expect(!geometry.isPointInNotch(CGPoint(x: 960, y: 1042.5)))
    }

    @Test("面板命中在边界内外各差一点就翻转")
    func panelHitTestBoundaries() {
        #expect(geometry.isPointInOpenedPanel(CGPoint(x: 713.5, y: 463), size: panelSize))
        #expect(!geometry.isPointInOpenedPanel(CGPoint(x: 712.5, y: 463), size: panelSize))
        #expect(geometry.isPointInOpenedPanel(CGPoint(x: 960, y: 1079.5), size: panelSize))
        #expect(!geometry.isPointInOpenedPanel(CGPoint(x: 960, y: 1080.5), size: panelSize))
    }

    @Test("面板内与面板外互为补集，远离面板的点两者都为假")
    func panelInsideAndOutsideAreComplements() {
        let points = [
            CGPoint(x: 960, y: 700), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 0),
            CGPoint(x: 1207, y: 500), CGPoint(x: 713, y: 462),
        ]
        for point in points {
            let inside = geometry.isPointInOpenedPanel(point, size: panelSize)
            let outside = geometry.isPointOutsidePanel(point, size: panelSize)
            #expect(inside != outside, "面板命中与面板外判定必须互补")
        }
        #expect(!geometry.isPointInOpenedPanel(CGPoint(x: 100, y: 100), size: panelSize))
        #expect(!geometry.isPointInNotch(CGPoint(x: 100, y: 100)))
    }
}
