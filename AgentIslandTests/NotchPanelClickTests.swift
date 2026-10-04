//
//  NotchPanelClickTests.swift
//  AgentIslandTests
//
//  面板点击归属：展开时**面板内部**的点击全部归 SwiftUI（头部条带里的按钮优先），
//  鼠标监听只处理「点面板外面 → 收起」。这里钉住那次修复——判定带曾经是**关闭态胶囊**
//  矩形，用户把胶囊调宽后头部按钮落进带里（300pt 时带右边缘 1110，统计按钮命中区
//  [1089, 1111]），点击被抢走：灵动岛收起而不是切页。
//
//  同一条不变量在本文件里换几个角度看：**画出来的那一块 == 点击归属的判据**。
//  另外两套用例：全屏空间守卫（面板不该盖在全屏应用上、也不该收它的点击）与面板状态接续
//  （屏幕参数变化重建窗口时状态不丢）。
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("面板点击归属")
struct NotchPanelClickTests {
    /// 报障时的配置：胶囊宽度改成自定义 300pt（此时判定带 [810, 1110] 盖住头部按钮）。
    @MainActor
    private func makeModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 300, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowHeight: 750,
            hasPhysicalNotch: false
        )
    }

    @Test("展开时点面板内部不收起——包括关闭态胶囊盖住的那条带子")
    @MainActor
    func clickInsidePanelKeepsPanelOpen() {
        let model = makeModel()
        model.notchOpen(reason: .click)
        #expect(model.status == .opened)

        // 带子中心：关闭态胶囊的位置，展开后是面板的头部条带。
        model.handleMouseDown(at: CGPoint(x: 960, y: 1064))
        #expect(model.status == .opened)

        // 头部按钮的位置（统计按钮命中区）：修复前这里会被判定带抢走并收起面板。
        model.handleMouseDown(at: CGPoint(x: 1100, y: 1064))
        #expect(model.status == .opened)

        // 面板内的其它位置（内容区）同样不收起。
        model.handleMouseDown(at: CGPoint(x: 960, y: 950))
        #expect(model.status == .opened)
    }

    @Test("展开时点面板外面收起并回到会话列表")
    @MainActor
    func clickOutsidePanelCollapses() {
        let model = makeModel()
        model.notchOpen(reason: .click)
        model.contentType = .menu

        model.handleMouseDown(at: CGPoint(x: 100, y: 100))
        #expect(model.status == .closed)
        #expect(model.contentType == .instances)
    }

    @Test("底部那条 30pt 属于卡片：点它既不再收起、也不再被判「卡外」转投出去")
    @MainActor
    func bottomBandBelongsToTheCard() {
        let model = makeModel()
        model.notchOpen(reason: .click)
        // 判据曾经把卡片底部 30pt 判在「卡外」（行为判据按 height − 30 算）：点一下既收起
        // 面板，又把点击转投给下层应用。
        let rect = model.geometry.openedScreenRect(for: model.openedSize)
        let point = CGPoint(x: rect.midX, y: rect.minY + 10)

        #expect(model.isScreenPointInPanel(point), "卡片底部属于卡片，不能被判成卡外转投")
        model.handleMouseDown(at: point)
        #expect(model.status == .opened)
    }

    @Test("右键与左键同一条路：卡片外的右键也要收起面板")
    func rightClickSharesTheSamePath() {
        // 事件监听只掩码左键时，右键在卡片外的点击既不被窗口收下（判据放行给下层应用）、
        // 也不会被鼠标监听收掉，面板会停在「看着还在、点不动、点击还穿过去」的幽灵态。
        // 掩码是私有的（单测里造不出事件循环），因此这里钉住这条接线本身。
        #expect(EventMonitors.mouseDownMask.contains(.leftMouseDown))
        #expect(EventMonitors.mouseDownMask.contains(.rightMouseDown))
    }

    @Test("头部条带手势：展开且非聊天面才收起")
    func headerTapRule() {
        // 收起：列表面与设置面（含统计分组）。
        #expect(
            NotchViewModel.collapsesOnHeaderTap(status: .opened, contentType: .instances))
        #expect(NotchViewModel.collapsesOnHeaderTap(status: .opened, contentType: .menu))

        // 不收起：收起状态下没有条带可点；聊天面是粘性的（读到一半不该被误关）。
        #expect(
            NotchViewModel.collapsesOnHeaderTap(status: .closed, contentType: .instances) == false)
        let session = SessionState(agent: .ohMyPi, sessionId: "s1", cwd: "/tmp")
        #expect(
            NotchViewModel.collapsesOnHeaderTap(status: .opened, contentType: .chat(session))
                == false)
    }

    @Test("头部条带手势在聊天面不收起，在设置面收起")
    @MainActor
    func headerTapRespectsChatFace() {
        let model = makeModel()
        model.notchOpen(reason: .click)

        // 设置面：收起。
        model.contentType = .menu
        model.collapseFromHeaderTap()
        #expect(model.status == .closed)

        // 聊天面：不收起。
        model.notchOpen(reason: .click)
        model.contentType = .chat(SessionState(agent: .claudeCode, sessionId: "s2", cwd: "/tmp"))
        model.collapseFromHeaderTap()
        #expect(model.status == .opened)
    }

    @Test("关闭态：悬停与点击的判据就是画出来的胶囊（耳朵与计数徽标都在里面）")
    @MainActor
    func closedCapsuleOwnsHoverAndClick() {
        let model = makeModel()
        #expect(model.status == .closed)

        let capsule = NotchClosedMetrics.capsuleSize(
            notchSize: model.deviceNotchRect.size,
            earWidth: NotchClosedMetrics.earWidth(
                for: NotchClosedMetrics.label(
                    activeSessions: 3, subagents: 0, totalSessions: 9),
                minimum: NotchClosedMetrics.minimumEarWidth(
                    notchHeight: model.deviceNotchRect.height)),
            showsEars: true)
        model.updateClosedCapsuleSize(capsule)
        let rect = model.geometry.closedCapsuleScreenRect(for: capsule)

        // 胶囊两端的耳朵都在判据里（旧判据是「物理刘海外扩 10/5」，比画出来的窄一头）。
        #expect(model.isPointInClosedCapsule(CGPoint(x: rect.minX + 20, y: rect.midY)))
        #expect(model.isPointInClosedCapsule(CGPoint(x: rect.maxX - 20, y: rect.midY)))
        #expect(!model.isPointInClosedCapsule(CGPoint(x: rect.maxX + 1, y: rect.midY)))

        // 点胶囊展开（悬停展开的判据与它同源：`handleMouseMove` 走同一个 `isPointInClosedCapsule`）。
        model.handleMouseDown(at: CGPoint(x: rect.maxX - 20, y: rect.midY))
        #expect(model.status == .opened)
    }

    @Test("画出来的卡片 == 判据用的矩形：内边距的溢出被裁到声明尺寸")
    @MainActor
    func paintedCardMatchesTheJudgedRectangle() {
        for size in [
            CGSize(width: 480, height: 320),
            CGSize(width: 480, height: 631),
            CGSize(width: 552, height: 667),
            CGSize(width: 286, height: 32),
        ] {
            // 内容故意比卡片宽 30pt（生产里那两层内边距就是把子树撑成这样的）：卡片必须把
            // 它裁在声明尺寸里——背景画到声明之外正是「看得见、点上去没反应」的来源。
            let painted = paintedCardBox(size: size, contentOverflow: 30)
            #expect(painted.box.width > 0, "没量到卡片墨迹：离屏渲染可能失效了")
            // 判据是**位置感知**的：声明矩形之外的墨迹必须一个像素都没有——那正是
            // 「看得见、点上去没反应」的来源。不拿「包围盒宽度差」判越界：一侧外溢会被
            // 另一侧的内缩抵消，而材质在形状左右两端本来就各留 1pt 近白（见下一条）。
            // 消融实测（把 `clipShape` 去掉）：越界墨迹 1920…160080 像素，这条立刻红。
            #expect(
                painted.outsideInk == 0,
                "声明矩形之外还有 \(painted.outsideInk) 个墨迹像素（声明 \(size)）：卡片外的墨迹就是「看得见、点上去没反应」")
            // 也不许明显缩水，否则量到的包围盒就不是这张卡片了。宽度下界的 −2 是**实测**的：
            // 卡片底换成系统材质后（`NotchPanelSurface`），材质在形状左右两端各留 1pt 近白
            // （边缘高光），包围盒因此比声明窄 2pt，与渲染 scale 无关（1× 与 2× 都是 2px；
            // 黑底时代是 0）。高度不受影响。
            #expect(
                painted.box.width >= size.width - 2,
                "画出来的宽度 \(painted.box.width) 比声明的 \(size.width) 窄太多")
            #expect(
                abs(painted.box.height - size.height) <= 1,
                "画出来的高度 \(painted.box.height) ≠ 声明高度 \(size.height)")
            // 判据用的矩形与它同尺寸在 `NotchGeometryTests` 里钉住（两者都取自
            // `NotchGeometry` 的卡片矩形，因此「画出来的 == 判据」由这两条传递成立）。
        }
    }

    /// 离屏渲染一张卡片（白底），返回卡片墨迹的包围盒（pt）与**声明矩形之外**的墨迹像素数。
    ///
    /// 覆盖 `NotchCard` 的**唯一**职责：把画出来的那一块定死成声明尺寸（背景在固定 frame
    /// 之内、溢出交给 `clipShape`）。
    ///
    /// 越界判据按**布局真值**算声明矩形（水平居中 + 顶距 `contentOverflow + 20`），与墨迹的
    /// 包围盒无关——用包围盒宽度差判越界会被「一侧外溢、另一侧内缩」互相抵消。
    /// `renderer.scale = 1`，因此画布像素与 pt 是 1:1。
    @MainActor
    private func paintedCardBox(
        size: CGSize, contentOverflow: CGFloat
    ) -> (box: CGRect, outsideInk: Int) {
        let canvas = CGSize(
            width: size.width + 2 * contentOverflow + 40,
            height: size.height + 2 * contentOverflow + 40)
        let view = ZStack(alignment: .top) {
            Color.white
            NotchCard(
                size: size,
                shape: NotchShape(
                    topCornerRadius: AppRadius.panelClosedTop,
                    bottomCornerRadius: AppRadius.panelClosedBottom)
            ) {
                Color.red.frame(width: size.width + 2 * contentOverflow, height: size.height)
            }
            .padding(.top, contentOverflow + 20)
        }
        .frame(width: canvas.width, height: canvas.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return (.zero, -1) }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (.zero, -1) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 声明矩形（布局真值）：`ZStack(alignment: .top)` 把卡片水平居中、顶距是那层 padding。
        let declared = CGRect(
            x: (canvas.width - size.width) / 2,
            y: contentOverflow + 20,
            width: size.width,
            height: size.height)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var outsideInk = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard !(pixels[offset] > 240 && pixels[offset + 1] > 240 && pixels[offset + 2] > 240)
                else { continue }
                if !declared.contains(CGPoint(x: x, y: y)) { outsideInk += 1 }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (.zero, outsideInk) }
        return (
            CGRect(
                x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1),
                height: CGFloat(maxY - minY + 1)),
            outsideInk)
    }
}

@Suite("全屏空间守卫")
struct FullScreenGuardTests {
    /// 选中屏在 Quartz 坐标里的矩形（1920×1080 的主屏）。
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let ownPID: pid_t = 999

    private func window(
        _ frame: CGRect, layer: Int = 0, pid: pid_t = 4242, alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowLayer as String: layer,
            kCGWindowOwnerPID as String: Int(pid),
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: [
                "X": frame.minX, "Y": frame.minY, "Width": frame.width, "Height": frame.height,
            ],
        ]
    }

    @Test("屏幕矩形换算到 Quartz 坐标（原点 = 主屏左上、y 向下）")
    func quartzConversion() {
        #expect(
            NotchWindowController.quartzRect(
                for: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080)
                == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // 内置屏在主屏**上方**（NSScreen 的 y 为正）→ Quartz 的 y 为负。
        #expect(
            NotchWindowController.quartzRect(
                for: CGRect(x: 0, y: 1080, width: 1512, height: 982), primaryHeight: 1080)
                == CGRect(x: 0, y: -982, width: 1512, height: 982))
    }

    @Test("整块盖住屏幕的窗口才算全屏：最大化窗口（只到 visibleFrame）不算")
    func fullScreenWindowCoversTheWholeScreen() {
        let maximized = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        #expect(
            !NotchWindowController.isScreenCovered(
                by: [window(maximized)], screenQuartzRect: screen, ownPID: ownPID),
            "最大化窗口不吃菜单栏那条，不算全屏空间")
        let fullScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(
            NotchWindowController.isScreenCovered(
                by: [window(fullScreen)], screenQuartzRect: screen, ownPID: ownPID))
    }

    @Test("面板自己、高 layer 与透明窗口都不算全屏")
    func ownWindowAndHighLayersAreIgnored() {
        let fullScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(
            !NotchWindowController.isScreenCovered(
                by: [window(fullScreen, pid: ownPID)], screenQuartzRect: screen, ownPID: ownPID),
            "本进程的窗口（面板）不能把自己判成全屏")
        #expect(
            !NotchWindowController.isScreenCovered(
                by: [window(fullScreen, layer: 25)], screenQuartzRect: screen, ownPID: ownPID),
            "菜单栏 / Dock 这类高 layer 的窗口不算全屏")
        #expect(
            !NotchWindowController.isScreenCovered(
                by: [window(fullScreen, alpha: 0)], screenQuartzRect: screen, ownPID: ownPID),
            "透明窗口不算全屏")
        #expect(
            !NotchWindowController.isScreenCovered(
                by: [], screenQuartzRect: screen, ownPID: ownPID),
            "没有窗口就没有全屏空间")
    }

    @Test("只看选中屏：隔壁屏的全屏窗口不影响本屏")
    func otherScreenFullScreenIsIgnored() {
        let other = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        #expect(
            !NotchWindowController.isScreenCovered(
                by: [window(other)], screenQuartzRect: screen, ownPID: ownPID))
    }
}

@Suite("面板状态接续")
struct NotchPanelStateTests {
    @MainActor
    private func makeModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 300, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowHeight: 750,
            hasPhysicalNotch: false
        )
    }

    @Test("接得上「收起后回到哪条对话」：屏幕参数变化不会把读过的对话弄丢")
    @MainActor
    func chatSessionSurvivesRebuild() {
        let model = makeModel()
        let session = SessionState(agent: .claudeCode, sessionId: "s1", cwd: "/tmp")
        model.notchOpen(reason: .click)
        model.contentType = .chat(session)
        model.notchClose()  // 收起：面回到会话列表，但「上次那条对话」在这里是私有状态

        let restored = makeModel()
        restored.restorePanelState(model.panelState)

        #expect(restored.status == .closed)
        #expect(restored.contentType == .instances)
        // 再点开（click 会让视图模型恢复上次的对话面）——粘性必须活下来。
        restored.notchOpen(reason: .click)
        #expect(restored.contentType == .chat(session))
    }

    @Test("展开中的面与设置分组也接得上（面板不会因为改显示参数就关掉）")
    @MainActor
    func openFaceAndSectionSurviveRebuild() {
        let model = makeModel()
        model.notchOpen(reason: .click)
        model.toggleStatistics()  // .menu + .statistics

        let restored = makeModel()
        restored.restorePanelState(model.panelState)

        #expect(restored.status == .opened)
        #expect(restored.isShowingStatistics)
        #expect(restored.openReason == model.openReason)
    }
}