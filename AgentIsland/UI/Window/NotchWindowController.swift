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

    init(screen: NSScreen, animateOnLaunch: Bool = true) {
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

        // 点击转投（见 `ClickForwarding`）：只有卡片之外的点击才交给下层应用，判据与
        // 收起都取视图模型那套几何/状态——与「点面板外收起」同源，且收起由转投这条路径
        // 自己保证（鼠标监听只掩码左键，右键转投不会经过它）。
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
                    if self.viewModel.takesKeyboardFocusOnOpen, AppSettings.panelTakesFocus {
                        NSApp.activate(ignoringOtherApps: false)
                        self.window?.makeKey()
                    }
                    self.updateMouseAcceptance()
                case .closed, .popping:
                    self.window?.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)

        // 指针位置（**未节流**）驱动「窗口收不收鼠标事件」。视图模型那条流节流 50ms，
        // 用它做这个判据会让「刚进卡片就点」的第一下被判在卡外而丢掉。
        EventMonitors.shared.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMouseAcceptance() }
            .store(in: &cancellables)

        // 模态窗口（NSAlert / NSOpenPanel）结束后重算一次：`withNotchPanelYielded` 期间窗口
        // 被设成「让开鼠标」，它记下的快照在展开态已经不等于当前该有的值（该不该接收是随
        // 指针变化的），原样写回会让面板重新吞掉屏顶 750pt 的滚轮/手势，而且只靠「指针动一下」
        // 才自愈（关闭模态那一次点击只产生 leftMouseDown，位置流不订阅它）。
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

        // Perform boot animation after a brief delay (only on initial launch)
        if animateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    /// 面板只在**指针落在卡片里**时接收鼠标事件。
    /// 展开态窗口盖住整屏宽、屏顶 750pt（层级高过菜单栏），整段时间 `ignoresMouseEvents
    /// = false` 的话，卡片之外的滚轮 / 中键 / 拖拽 / 触控板手势都会被这个窗口吃掉 ——
    /// 用户看到的是「屏幕上半部分卡住了」，而 `NotchPanel.sendEvent` 只补投左/右「按下」，
    /// 滚轮这类事件没有兜底。因此接收范围跟着指针走：卡外一律放行，点击与滚动直接落到下层
    /// 应用（菜单栏也恢复原生行为），只用卡内那一段接收 SwiftUI 的交互。
    ///
    /// 判定与「点面板外收起」「点击转投」同源（都是 `NotchGeometry.openedScreenRect`）：
    /// 卡外点击既会被放行、也会被鼠标监听收掉面板，不会出现「点了没反应」。
    /// - Note: 判据用的是 `NotchGeometry.openedScreenRect`（比卡片**视觉范围**左右各小 3pt、
    ///   底部小 30pt）——那是「点面板外收起」与「点击转投」同源的既有矩形，本批刻意不另立
    ///   一套：那条底部窄带因此仍按「卡外」处理（点击放行给下层并顺手收起面板），与改动前
    ///   的观感一致。三条路径共用同一个矩形，不会出现「窗口判卡内、收起判卡外」。
    private func updateMouseAcceptance() {
        guard let window else { return }
        let shouldIgnore =
            viewModel.status != .opened
            || !viewModel.isScreenPointInPanel(NSEvent.mouseLocation)
        // 指针每移动一次都会走到这里（未节流），值没变就别写窗口属性。
        guard window.ignoresMouseEvents != shouldIgnore else { return }
        window.ignoresMouseEvents = shouldIgnore
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
