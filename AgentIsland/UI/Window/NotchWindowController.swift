//
//  NotchWindowController.swift
//  AgentIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    /// 会话监视器：由窗口层独占持有并向下传——快捷键控制器在 AppKit 层，
    /// 放在 SwiftUI 视图里就拿不到它。
    let sessionMonitor = ClaudeSessionMonitor()
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()

    /// 接续状态那一跳是否要跳过「抢键盘焦点」。一次性：状态订阅消费掉就失效。
    private var suppressFocusForRestoredOpen = false

    /// 全屏守卫当前是否把面板藏起来了（见 `refreshFullScreenGuard`）。
    private var isHiddenForFullScreen = false

    /// 当前面板状态（`WindowManager` 在销毁本控制器**之前**取走，装到重建出来的窗口上）。
    var capturedPanelState: NotchPanelState { viewModel.panelState }

    /// - Parameter restoring: 屏幕参数变化重建窗口时要接续的面板状态（见 `NotchPanelState`）。
    ///   接续不算「用户打开了面板」，因此不抢键盘焦点——用户此刻多半正在系统设置里改显示参数。
    init(screen: NSScreen, animateOnLaunch: Bool = true, restoring: NotchPanelState? = nil) {
        self.screen = screen

        let screenFrame = screen.frame

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: Self.closedNotchRect(for: screen),
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.physicalNotchHeight > 0
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // 接续一份面板状态（屏幕参数变化重建窗口）：必须在状态订阅**之前**装好，订阅时看到的
        // 就是接续后的状态；`suppressFocusForRestoredOpen` 让这一跳不抢键盘焦点。
        if let restoring {
            suppressFocusForRestoredOpen = restoring.status == .opened
            viewModel.restorePanelState(restoring)
        }

        // 点击转投（见 `ClickForwarding`）：只有卡片之外的点击才交给下层应用，判据与
        // 收起都取视图模型那套几何/状态——与「点面板外收起」同源，且收起由转投这条路径
        // 自己保证：`sendEvent` 是同步的、就在这一次点击里，不依赖「鼠标监听还能收到下一
        // 个事件」（监听是全局+本地两条，模态或事件重定向时都可能漏）。
        notchWindow.forwarding = .live(
            isPointOnPanel: { [weak self] screenPoint in
                // 同上：`isScreenPointInPanel` 自己已合取开合状态。
                guard let self else { return true }
                return self.viewModel.isScreenPointInPanel(screenPoint)
            },
            collapse: { [weak self] in self?.viewModel.collapseForForwardedClick() })

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(
            viewModel: viewModel, sessionMonitor: sessionMonitor)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // 快捷键控制器挂接这个窗口（弱引用：窗口随屏幕变化重建时会重新挂接）。
        ShortcutController.shared.attach(
            panel: notchWindow, viewModel: viewModel, sessionMonitor: sessionMonitor)

        // Dynamically toggle mouse event handling based on notch state:
        // - Closed: ignoresMouseEvents = true (clicks pass through to menu bar/apps)
        // - Opened: 只在自己那张卡片上接收（见 updateMouseAcceptance()）
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .opened:
                    // 不抢键盘焦点的场合：悬停展开（默认 1s，鼠标只是路过）、启动动画与
                    // 通知触发的展开 —— 用户都没点任何东西，抢焦点会让他正在打的字丢进面板
                    // （面板里没有聚焦的输入框，字直接没了）。判据抽在视图模型里（可单测）。
                    //
                    // 接续状态那一跳同样不抢：显示设置变化不是「用户打开了面板」，
                    // 此刻键盘多半在系统设置手里。一次性消费。
                    let shouldTakeFocus = !self.suppressFocusForRestoredOpen
                    self.suppressFocusForRestoredOpen = false
                    if shouldTakeFocus, self.viewModel.takesKeyboardFocusOnOpen,
                        AppSettings.panelTakesFocus
                    {
                        NSApp.activate(ignoringOtherApps: false)
                        self.window?.makeKey()
                    }
                    self.refreshFullScreenGuard()
                    self.updateMouseAcceptance()
                case .closed, .popping:
                    self.window?.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)

        // 指针位置驱动「窗口收不收鼠标事件」。事件层已把这条流压成**边界事件**：指针跨进 /
        // 跨出视图模型写过去的兴趣区（展开态就是卡片矩形）时才发布一次（见
        // `EventMonitors.interestRect`），因此这里不必节流——订阅者关心的本来就只有
        // 「跨边界」这一件事，而卡内的高频移动曾经每次都白算一遍窗口属性。
        //
        // 关闭态与指针无关（窗口恒 `ignoresMouseEvents = true`，由上面的状态订阅负责），
        // 先挡掉：面板没开时不必跟着每一次跨界白算 `shouldIgnore`。
        EventMonitors.shared.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.viewModel.status == .opened else { return }
                self.updateMouseAcceptance()
            }
            .store(in: &cancellables)

        // 模态窗口（NSAlert / NSOpenPanel）结束后重算一次：`withNotchPanelYielded` 期间窗口
        // 被设成「让开鼠标」，它记下的快照在展开态已经不等于当前该有的值（该不该接收是随
        // 指针变化的），原样写回会让面板重新吞掉屏顶 750pt 的滚轮/手势，而且只靠「指针跨一次
        // 边界」才自愈（关闭模态那一次点击只产生 leftMouseDown，位置流不订阅它）。
        NotificationCenter.default.publisher(for: .notchPanelYieldEnded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMouseAcceptance() }
            .store(in: &cancellables)

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // 胶囊几何设置（高度或宽度）变化：只换关闭态胶囊矩形，不重建窗口。
        // 面板因此能一直开着，用户微调时胶囊实时跟手。
        NotificationCenter.default.publisher(for: .notchGeometryPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.viewModel.updateDeviceNotchRect(Self.closedNotchRect(for: self.screen))
            }
            .store(in: &cancellables)

        // 全屏守卫：空间切换、应用激活、屏幕参数变化都重新评估一次——面板是 level 27 +
        // `.fullScreenAuxiliary`，会画在全屏应用与视频之上（见 `refreshFullScreenGuard`）。
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            workspaceCenter.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFullScreenGuard() }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFullScreenGuard() }
            .store(in: &cancellables)

        // Perform boot animation after a brief delay (only on initial launch)
        if animateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                // 正被全屏守卫挡着时不演这段「快看我一眼」的动画：全屏里工作/看片的用户
                // 不需要一块盖在视频上的卡片。
                guard let self, !self.isHiddenForFullScreen else { return }
                self.viewModel.performBootAnimation()
            }
        }
    }

    /// 窗口上屏时也要过一遍全屏守卫：`WindowManager` 建好控制器就调 `showWindow`，
    /// 而它会把窗口直接放回来（全屏空间在前台时面板不该挂上去）。
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // 先把记忆清零，让 `refreshFullScreenGuard` 走一次完整对账（它会自己重新判定）。
        isHiddenForFullScreen = false
        refreshFullScreenGuard()
    }

    /// 面板只在**指针落在卡片里**时接收鼠标事件。
    /// 展开态窗口盖住整屏宽、屏顶 750pt（层级高过菜单栏），整段时间 `ignoresMouseEvents
    /// = false` 的话，卡片之外的滚轮 / 中键 / 拖拽 / 触控板手势都会被这个窗口吃掉 ——
    /// 用户看到的是「屏幕上半部分卡住了」，而 `NotchPanel.sendEvent` 只补投左/右「按下」，
    /// 滚轮这类事件没有兜底。因此接收范围跟着指针走：卡外一律放行（点击、滚轮、中键、拖拽、
    /// 手势都直接落到下层应用，菜单栏也恢复原生行为），只用卡内那一段接收 SwiftUI 的交互。
    /// 这个判据是**窗口级**的：`ignoresMouseEvents` 一挡就挡掉全部事件类型，因此不必
    /// （也不该）在这里按事件类型分叉——「别的类型也被吞掉」这个坑由这一层一次堵住。
    ///
    /// 判定与「点面板外收起」「点击转投」同源（都是同一张卡片矩形
    /// `NotchGeometry.openedScreenRect`，也就是 `NotchCard` 画出来的那一块）：卡外点击既会
    /// 被放行、也会被鼠标监听收掉面板，不会出现「点了没反应」。
    ///
    /// 卡内那一段里，滚轮归面板自己（对话与列表要滚动），中键与拖拽没有控件认领时由面板吞下
    /// ——那片像素本来就盖在面板上，穿过它交给下层应用才是错的。
    private func updateMouseAcceptance() {
        guard let window else { return }
        let shouldIgnore =
            isHiddenForFullScreen
            || viewModel.status != .opened
            || !viewModel.isScreenPointInPanel(NSEvent.mouseLocation)
        // 指针跨一次边界（或面板状态 / 全屏守卫变化）时都会走到这里，值没变就别写窗口属性。
        guard window.ignoresMouseEvents != shouldIgnore else { return }
        window.ignoresMouseEvents = shouldIgnore
    }

    // MARK: - 全屏空间守卫

    /// 重新评估全屏守卫：选中屏被一个**全屏窗口**（含全屏视频）整块盖住时，把面板藏起来并
    /// 让开鼠标；退出全屏后再放回来。
    ///
    /// 面板是 level 27 + `.fullScreenAuxiliary`：没有这道守卫，用户全屏看片、演示、开会时
    /// 屏幕顶边会一直挂着一块卡片。判据取实时窗口列表，只在通知到来时算（不跟着指针走）。
    ///
    /// **刻意只藏窗口、不收起面板**：状态照旧（悬停/通知仍可能把它展开），退出全屏后恢复
    /// 原来的样子——比「一次全屏就把用户正在读的面板清掉」更接近预期（同一条道理见
    /// `NotchPanelState`）。
    private func refreshFullScreenGuard() {
        guard let window else { return }
        let hidden = Self.isFullScreenSpaceFrontmost(on: screen)
        isHiddenForFullScreen = hidden

        guard !hidden else {
            window.orderOut(nil)
            window.ignoresMouseEvents = true
            return
        }
        if !window.isVisible { window.orderFrontRegardless() }
        updateMouseAcceptance()
    }

    /// 选中屏此刻是不是被全屏空间占着（取一次实时窗口列表）。
    nonisolated private static func isFullScreenSpaceFrontmost(on screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return isScreenCovered(
            by: windows,
            screenQuartzRect: quartzRect(
                for: screen.frame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0),
            ownPID: getpid())
    }

    /// 屏幕矩形换算到 **Quartz 坐标**（原点 = 主屏左上、y 向下）：窗口列表里的坐标都是这个系。
    nonisolated static func quartzRect(for frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// 窗口列表里有没有窗口**整块**盖住选中屏。
    ///
    /// 「全屏」与「最大化」的区别：全屏窗口贴满整块屏（连菜单栏那一条也一起占），最大化只到
    /// `visibleFrame`，因此「是否整块盖住屏幕矩形」就是判据。只认 layer 0 的普通窗口——
    /// 菜单栏、Dock 与面板自己都在更高的 layer 上，会被跳过（本进程的窗口再按 pid 排一次）。
    ///
    /// - Parameters:
    ///   - windows: `CGWindowListCopyWindowInfo` 的结果。
    ///   - screenQuartzRect: 选中屏的 Quartz 矩形（见 `quartzRect(for:primaryHeight:)`）。
    ///   - ownPID: 本进程 pid。
    nonisolated static func isScreenCovered(
        by windows: [[String: Any]],
        screenQuartzRect: CGRect,
        ownPID: pid_t
    ) -> Bool {
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, pid_t(owner) != ownPID
            else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            // 容差 1pt：窗口边界与屏幕边界在缩放比下会差零点几 pt。
            let rect = CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -1, dy: -1)
            if rect.contains(screenQuartzRect) { return true }
        }
        return false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 关闭态胶囊矩形：宽度与高度各按自己的设置解析（宽度默认取屏幕的刘海宽度，
    /// 高度自动模式在有刘海的屏幕上取刘海高度、外接屏取菜单栏高度）。
    private static func closedNotchRect(for screen: NSScreen) -> CGRect {
        let width = NotchWidthSelector.shared.resolvedWidth(for: screen)
        let height = NotchHeightSelector.shared.resolvedHeight(for: screen)
        return CGRect(
            x: (screen.frame.width - width) / 2,
            y: 0,
            width: width,
            height: height
        )
    }
}
