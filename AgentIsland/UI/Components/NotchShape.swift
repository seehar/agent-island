//
//  NotchShape.swift
//  AgentIsland
//
//  Accurate notch shape using quadratic curves
//
//  形状有两套角，别混：
//   · **顶角是反向弧**（向卡片里侧弧进去）：卡片贴着屏幕顶边，只有反向弧才融得进刘海或
//     菜单栏上沿——这是这个形状存在的理由，不能换成普通圆角。
//   · **底角是普通圆角**，且取**连续曲率**（`RoundedRectangle(style: .continuous)`）：
//     面板内部的卡片、分组容器都是连续曲率，底角用正圆弧会和它们对不上。
//

import SwiftUI

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(
        topCornerRadius: CGFloat = AppRadius.panelClosedTop,
        bottomCornerRadius: CGFloat = AppRadius.panelClosedBottom
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(topCornerRadius, bottomCornerRadius)
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // 连续曲率只有整套圆角矩形、没有「只要底角」的 API，因此分两条子路径拼：
        //   ① 内缩后的矩形交给 `RoundedRectangle(style: .continuous)`——它的左右边界与底边
        //      都和本形状落在同一处，底角因此与面板内部的卡片同曲率；
        //   ② 顶部那条带（左右各一条反向弧 + 直边）单独闭合，高度取「反向弧 + 底角半径」：
        //      只有盖到内缩矩形顶角的切点，并集才不会被内缩矩形自己的上圆角咬出一个腰。
        // 两条子路径旋向一致、只在边界上相接，非零环绕填充出来的正是并集。
        var path = Path()

        // 底角半径按矩形的高/宽夹紧（`RoundedRectangle` 自己也是这么做的）：关闭态胶囊只有
        // 32pt 高、名义底角半径 14，实际用得上的是 13。这里把夹紧后的值算出来，
        // 顶部条带的高度才能与它严丝合缝地接上。
        let innerWidth = max(0, rect.width - 2 * topCornerRadius)
        let innerHeight = max(0, rect.height - topCornerRadius)
        let corner = min(bottomCornerRadius, min(innerWidth, innerHeight) / 2)

        // ① 下半段：连续曲率的圆角矩形（上边界落在反向弧的切点高度上）。
        let inner = CGRect(
            x: rect.minX + topCornerRadius,
            y: rect.minY + topCornerRadius,
            width: innerWidth,
            height: innerHeight)
        path.addPath(RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: inner))

        // ② 顶部条带：从右上角起顺时针走一圈（与 `Path(CGRect)` 同旋向）。
        let bandBottom = rect.minY + topCornerRadius + corner
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // 右上反向弧：从卡片右缘的顶边弯到内缩后的右边界。
        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY + topCornerRadius
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY
            )
        )
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: bandBottom))
        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: bandBottom))
        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius))
        // 左上反向弧：弯回卡片左缘的顶边。
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY
            )
        )
        path.closeSubpath()

        return path
    }
}

#Preview {
    VStack(spacing: 20) {
        // Closed state
        NotchShape(
            topCornerRadius: AppRadius.panelClosedTop,
            bottomCornerRadius: AppRadius.panelClosedBottom
        )
        .fill(.black)
        .frame(width: 200, height: 32)

        // Open state
        NotchShape(
            topCornerRadius: AppRadius.panelOpenedTop,
            bottomCornerRadius: AppRadius.panelOpenedBottom
        )
        .fill(.black)
        .frame(width: 600, height: 200)
    }
    .padding(20)
    .background(Color.gray.opacity(0.3))
}