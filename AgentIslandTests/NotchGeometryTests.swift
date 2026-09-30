//
//  NotchGeometryTests.swift
//  AgentIslandTests
//
//  刘海与面板的命中判定决定「鼠标算不算在面板里」，算错会让面板无法展开或无法收起。
//  这里是纯几何与卡片形状，用固定的屏幕/刘海尺寸把边界钉死。
//
//  一条不变量贯穿全套：**画出来的那一块 == 命中判据 == 行为判据**。三处曾经各算一套
//  （画的是 `notchSize`，宿主视图命中是 `size.width + 52`，行为判据是 `size.width - 6` /
//  `size.height - 30`），于是卡片边上有一条「看得见、点上去没反应」的带子，底部 30pt 还会
//  既收起面板、又把点击转投给下层应用。
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("刘海与面板几何")
struct NotchGeometryTests {
    /// 1920x1080 的主屏 + 200x32 的刘海。
    private var geometry: NotchGeometry {
        NotchGeometry(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowHeight: 750)
    }

    /// 各档面板尺寸：会话列表（480×320）、设置页（480×631）、紧凑档（422×269）、宽档（552×667）。
    private var panelSizes: [CGSize] {
        [
            CGSize(width: 480, height: 320),
            CGSize(width: 480, height: 631),
            CGSize(width: 422, height: 269),
            CGSize(width: 552, height: 667),
        ]
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

    @Test("展开态卡片矩形不缩不推：声明多大就是多大，居中贴顶")
    func openedCardRectIsExactlyTheDeclaredSize() {
        // 曾经左右各减 3pt、下方减 30pt（"tuned to match visual output"）——那正是
        // 「底部 30pt 既收起面板又把点击转投出去」的来源。
        for size in panelSizes {
            let rect = geometry.openedScreenRect(for: size)
            #expect(rect.size == size)
            #expect(rect.midX == 960)
            #expect(rect.maxY == 1080)
            #expect(rect.minY == 1080 - size.height)
        }
    }

    @Test("同一张卡片在窗口坐标里的矩形与屏幕坐标一致（命中 == 行为判据）")
    func windowRectMatchesScreenRect() {
        // 窗口与屏幕左缘/顶边对齐（`NotchWindowController` 的 windowFrame）：换算只是
        // 「横坐标减窗口原点、纵坐标从窗口底边改成从顶边量」。
        for size in panelSizes {
            let screen = geometry.openedScreenRect(for: size)
            let window = geometry.openedWindowRect(for: size)
            #expect(window.size == screen.size)
            #expect(window.midX == geometry.screenRect.width / 2)
            #expect(window.maxY == geometry.windowHeight)
            #expect(
                window.minX == screen.minX - geometry.screenRect.minX,
                "窗口系横坐标必须与屏幕系只差一个窗口原点")
        }
    }

    @Test("关闭态胶囊矩形同样是一套：屏幕系与窗口系同值，且贴顶居中")
    func closedCapsuleRectIsOneRectangle() {
        let capsule = NotchClosedMetrics.capsuleSize(
            notchSize: geometry.deviceNotchRect.size,
            earWidth: NotchClosedMetrics.minimumEarWidth(notchHeight: 32),
            showsEars: true)
        let screen = geometry.closedCapsuleScreenRect(for: capsule)
        let window = geometry.closedCapsuleWindowRect(for: capsule)

        #expect(screen.size == capsule)
        #expect(screen.midX == 960)
        #expect(screen.maxY == 1080)
        #expect(window.midX == geometry.screenRect.width / 2)
        #expect(window.maxY == geometry.windowHeight)
    }

    @Test("关闭态胶囊盖住角色（左耳）与计数徽标（右耳）——旧判据把耳朵切在外面")
    func closedCapsuleCoversBothEars() {
        let notch = geometry.deviceNotchRect.size
        let label = NotchClosedMetrics.label(activeSessions: 11, subagents: 11, totalSessions: 22)
        let ear = NotchClosedMetrics.earWidth(
            for: label, minimum: NotchClosedMetrics.minimumEarWidth(notchHeight: notch.height))
        let capsule = NotchClosedMetrics.capsuleSize(
            notchSize: notch, earWidth: ear, showsEars: true)
        let rect = geometry.closedCapsuleScreenRect(for: capsule)

        // 左耳的几何中心（角色就画在这个耳位里）：胶囊左缘 + 两侧内边距 + 半个耳宽。
        let leftEarCentre = CGPoint(
            x: rect.minX + NotchClosedMetrics.Capsule.sidePadding + ear / 2,
            y: rect.midY)
        // 右耳同理（计数徽标的槽位）。
        let rightEarCentre = CGPoint(
            x: rect.maxX - NotchClosedMetrics.Capsule.sidePadding
                - NotchClosedMetrics.Capsule.badgeTrailing - ear / 2,
            y: rect.midY)
        #expect(geometry.isPointInClosedCapsule(leftEarCentre, size: capsule))
        #expect(geometry.isPointInClosedCapsule(rightEarCentre, size: capsule))

        // 判别力：旧的判据是「物理刘海外扩 10/5」（宽 220），左耳中心正好落在它外面
        // ——「角色外半截悬停没反应、点击穿到菜单栏」就是这么来的。
        let oldBand = geometry.notchScreenRect.insetBy(dx: -10, dy: -5)
        #expect(!oldBand.contains(leftEarCentre))
        #expect(!oldBand.contains(rightEarCentre))
        // 胶囊至少要盖住物理挖孔（否则计数会落在挖孔边上）。
        #expect(rect.minX <= geometry.notchScreenRect.minX)
        #expect(rect.maxX >= geometry.notchScreenRect.maxX)
    }

    @Test("负原点的屏幕（外接屏）仍然贴自己的顶边")
    func screenBelowPrimaryIsHandled() {
        let secondary = NotchGeometry(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            windowHeight: 750)
        #expect(secondary.notchScreenRect.maxY == 0)
        #expect(secondary.notchScreenRect.minY == -32)
        #expect(secondary.openedScreenRect(for: panelSize).maxY == 0)
    }

    @Test("胶囊命中在边界内外各差一点就翻转（判据就是画出来的那一块，不外扩）")
    func capsuleHitTestBoundaries() {
        let capsule = NotchClosedMetrics.capsuleSize(
            notchSize: geometry.deviceNotchRect.size,
            earWidth: 30,
            showsEars: false)
        let rect = geometry.closedCapsuleScreenRect(for: capsule)

        #expect(
            geometry.isPointInClosedCapsule(
                CGPoint(x: rect.minX + 0.5, y: rect.midY), size: capsule))
        #expect(
            !geometry.isPointInClosedCapsule(
                CGPoint(x: rect.minX - 0.5, y: rect.midY), size: capsule))
        #expect(
            geometry.isPointInClosedCapsule(
                CGPoint(x: rect.midX, y: rect.maxY - 0.5), size: capsule))
        #expect(
            !geometry.isPointInClosedCapsule(
                CGPoint(x: rect.midX, y: rect.maxY + 0.5), size: capsule))
        #expect(!geometry.isPointInClosedCapsule(CGPoint(x: 100, y: 100), size: capsule))
    }

    @Test("面板命中在边界内外各差一点就翻转")
    func panelHitTestBoundaries() {
        for size in panelSizes {
            let rect = geometry.openedScreenRect(for: size)
            #expect(
                geometry.isPointInOpenedPanel(
                    CGPoint(x: rect.minX + 0.5, y: rect.midY), size: size))
            #expect(
                !geometry.isPointInOpenedPanel(
                    CGPoint(x: rect.minX - 0.5, y: rect.midY), size: size))
            #expect(
                geometry.isPointInOpenedPanel(
                    CGPoint(x: rect.midX, y: rect.maxY - 0.5), size: size))
            #expect(
                !geometry.isPointInOpenedPanel(
                    CGPoint(x: rect.midX, y: rect.maxY + 0.5), size: size))
            // 底部那条 30pt 曾经被判在面板外（点一下既收起、又把点击转投出去）。
            #expect(
                geometry.isPointInOpenedPanel(
                    CGPoint(x: rect.midX, y: rect.minY + 15), size: size))
            #expect(
                !geometry.isPointOutsidePanel(
                    CGPoint(x: rect.midX, y: rect.minY + 15), size: size))
        }
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
        #expect(!geometry.isPointInClosedCapsule(CGPoint(x: 100, y: 100), size: panelSize))
    }
}

@Suite("卡片形状")
struct NotchShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test("底角是连续曲率：底角方格内的命中与连续圆角矩形逐点一致")
    func bottomCornersFollowContinuousRoundedRect() {
        let top: CGFloat = 6
        let bottom: CGFloat = 14
        let path = NotchShape(topCornerRadius: top, bottomCornerRadius: bottom).path(in: rect)

        // 与 `NotchCard` 内部同源的连续圆角矩形（左右边界与底边都与本形状落在一起）。
        // 这个矩形够高，底角半径没有被夹紧，因此两边用的是同一个半径值。
        let inner = CGRect(
            x: rect.minX + top, y: rect.minY + top,
            width: rect.width - 2 * top, height: rect.height - top)
        let continuous = RoundedRectangle(cornerRadius: bottom, style: .continuous)
            .path(in: inner)

        // 底角方格：`y ≥ maxY − bottom`。这一段只有「下半段」那条子路径覆盖，因此命中必须
        // 逐点与连续圆角矩形相同——旧的二次曲线底角在这里会大面积不一致（连续曲率在 45°
        // 对角上更满）。
        var checked = 0
        for x in stride(from: rect.minX + top + 0.5, to: rect.minX + top + bottom, by: 2) {
            for y in stride(from: rect.maxY - bottom + 0.5, to: rect.maxY, by: 2) {
                let point = CGPoint(x: x, y: y)
                #expect(
                    path.contains(point) == continuous.contains(point),
                    "底角方格里的 \(point) 必须与连续曲率圆角矩形一致")
                checked += 1
            }
        }
        #expect(checked >= 40, "采样点太少，这条断言没有判别力")

        // 两条子路径（顶部条带 + 连续圆角矩形）的并集不能因为旋向相反被抵消：取几个
        // 「同时在两条子路径里」或紧邻接缝的点——winding 非零才不会挖出一个洞。
        #expect(
            path.contains(CGPoint(x: rect.midX, y: rect.minY + top + bottom / 2)), "重叠区不能被填充规则挖空")
        #expect(path.contains(CGPoint(x: rect.minX + top + 1, y: rect.minY + top + 1)))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.minY + 1)))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)))
    }

    @Test("底角半径按矩形高度夹紧：关闭态胶囊（32pt 高）不会把角画到卡片外面")
    func bottomCornersClampToTheCardHeight() {
        // 关闭态胶囊：286×32，顶角 6、名义底角 14 → 实际半径被夹到 13。
        let capsuleRect = CGRect(x: 0, y: 0, width: 286, height: 32)
        let path = NotchShape(topCornerRadius: 6, bottomCornerRadius: 14).path(in: capsuleRect)

        // 路径必须落在矩形里（夹紧之前，14 的底角在 32 高的卡片上会互相咬掉）。
        for x in stride(from: capsuleRect.minX, through: capsuleRect.maxX, by: 7) {
            #expect(
                !path.contains(CGPoint(x: x, y: capsuleRect.minY - 1)),
                "形状不能越出卡片的顶边")
            #expect(
                !path.contains(CGPoint(x: x, y: capsuleRect.maxY + 1)),
                "形状不能越出卡片的底边")
        }
        // 下缘中段仍然填满（底边是直的）。
        #expect(path.contains(CGPoint(x: capsuleRect.midX, y: capsuleRect.maxY - 0.5)))
        // 左下角已被圆掉：贴着左缘、离底边 1pt 的点在形状外。
        #expect(!path.contains(CGPoint(x: capsuleRect.minX + 6 + 1, y: capsuleRect.maxY - 1)))
    }

    @Test("顶角是反向弧：贴顶边那一带的左右两角要被弧进去")
    func topCornersAreConcave() {
        let topRadius: CGFloat = 19
        let shape = NotchShape(topCornerRadius: topRadius, bottomCornerRadius: 24)
        let path = shape.path(in: rect)

        // 顶边中段（弧够不到的地方）在形状里。
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.minY + 1)))
        // 左上角里侧一点：反向弧把这一小块切在形状**外**（这就是「融进刘海/菜单栏上沿」的
        // 反向弧；普通圆角会把它算在形状里）。
        #expect(!path.contains(CGPoint(x: rect.minX + 5, y: rect.minY + 1)))
        // 过了反向弧之后，卡片正文是**内缩一个顶角半径**的竖直边——不是贴着 rect.minX 的。
        // 这一点对旧实现同样成立（离屏逐行量过：旧/新在每一行的左右端点一致），所以断言
        // 钉的是形状本身的性质，不是某一版实现的写法。
        let belowArc = rect.minY + topRadius + 1
        #expect(!path.contains(CGPoint(x: rect.minX + topRadius - 1, y: belowArc)))
        #expect(path.contains(CGPoint(x: rect.minX + topRadius + 5, y: belowArc)))
        #expect(path.contains(CGPoint(x: rect.maxX - topRadius - 5, y: belowArc)))
        #expect(!path.contains(CGPoint(x: rect.maxX - topRadius + 1, y: belowArc)))
    }
}
