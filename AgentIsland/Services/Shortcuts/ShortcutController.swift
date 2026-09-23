//
//  ShortcutController.swift
//  AgentIsland
//
//  快捷键的唯一分发点：本地监视、全局热键、录制模式与动作执行都在这里。
//

import AppKit
import Combine
import os

/// 快捷键控制器。
///
/// 分工：`ShortcutBindings` 管「某个动作绑了什么键」，`ShortcutResolver` 管「这个键该做
/// 什么」，本类只负责**副作用**——装监视、注册全局热键、把动作落到视图模型与会话监视器上。
@MainActor
final class ShortcutController: ObservableObject {
    static let shared = ShortcutController()

    /// 录制过程中的一次拒绝原因（视图负责把它翻成文案，模型里不放文案）。
    enum RecordingRejection: Equatable {
        /// 该组合已被另一个动作占用。
        case conflicting(ShortcutAction)
        /// 可打印字符没带修饰键。
        case needsModifier
        /// 不受支持的键（F 键、多媒体键等）。
        case unsupportedKey
        /// 全局组合必须带 ⌥ 或 ⌃。
        case globalNeedsOptionOrControl
    }

    /// 正在录制的动作；非空时本地监视进入录制模式（消费所有按键）。
    @Published private(set) var recording: ShortcutAction?
    /// 上次录制的拒绝原因，`cancelRecording()` 时清空。
    @Published private(set) var rejection: RecordingRejection?
    /// 全局热键当前是否注册成功；false 时设置页给一行提示。
    @Published private(set) var globalHotKeyAvailable = true

    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Shortcuts")

    private var didStart = false
    private var keyMonitor: KeyEventMonitor?
    private let hotKey = GlobalHotKey()
    private var cancellables = Set<AnyCancellable>()
    /// 当前窗口的状态订阅（换窗口时替换，避免越挂越多）。
    private var statusCancellable: AnyCancellable?

    /// 面板（弱引用：窗口随屏幕变化重建）。
    private weak var panel: NSWindow?
    /// 面板视图模型（弱引用：同上）。
    private weak var viewModel: NotchViewModel?
    /// 会话监视器（弱引用：由窗口控制器持有）。
    private weak var sessionMonitor: ClaudeSessionMonitor?

    /// 热键唤出前的原前台应用：只在热键路径上记录，收起时把前台交还给它。
    private var focusReturnTarget: NSRunningApplication?

    private init() {}

    // MARK: - 生命周期

    /// 装配监视与全局热键。由 `AppDelegate` 调用一次（应用生命周期内只装一次）。
    func start() {
        guard !didStart else { return }
        didStart = true

        // 测试宿主里不装：单测不该注册系统级热键，也不该接管键盘事件。
        guard !AppEnvironment.isRunningTests else {
            Self.logger.info("跳过快捷键装配（运行在测试宿主里）")
            return
        }

        hotKey.onPressed = { [weak self] in self?.perform(.summon) }

        let monitor = KeyEventMonitor { [weak self] event in
            self?.handle(event) ?? false
        }
        monitor.start()
        keyMonitor = monitor

        ShortcutBindings.shared.$bindings
            .sink { [weak self] _ in self?.registerGlobalHotKey() }
            .store(in: &cancellables)

        registerGlobalHotKey()
    }

    /// 挂接当前窗口的部件。窗口随屏幕变化重建时会被重新调用。
    func attach(panel: NSWindow, viewModel: NotchViewModel, sessionMonitor: ClaudeSessionMonitor) {
        self.panel = panel
        self.viewModel = viewModel
        self.sessionMonitor = sessionMonitor

        // 状态回到关闭：把前台交还给热键唤出前的应用。
        // 换窗口时先撤掉上一次的订阅：publisher 属于旧视图模型，留着只会越挂越多。
        statusCancellable?.cancel()
        statusCancellable = viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .closed || status == .popping else { return }
                self?.restoreFocusIfNeeded()
            }
    }

    // MARK: - 录制

    /// 进入录制：设置页点某一行时调用。
    func beginRecording(_ action: ShortcutAction) {
        // 录制期间先注销全局热键：否则要重录的组合会被它自己先吃掉（Carbon 热键在
        // 系统层面拦截，事件根本到不了本地监视）。
        hotKey.unregister()
        rejection = nil
        recording = action
    }

    /// 结束录制（取消或写入之后）。
    func cancelRecording() {
        recording = nil
        rejection = nil
        registerGlobalHotKey()
    }

    // MARK: - 按键处理

    /// 本地监视回调：返回 true 表示消费这个按键。
    private func handle(_ event: NSEvent) -> Bool {
        if let recording {
            handleRecording(event, action: recording)
            return true
        }

        // 只认落在刘海面板上、且面板确实是 key window 的按键：面板因通知展开而键盘仍在
        // 别处时不该抢键，模态面板（NSAlert）期间也不该抢。
        guard let panel, event.window === panel, panel.isKeyWindow, NSApp.isActive else {
            return false
        }
        guard let chord = KeyChord.from(event) else { return false }

        let context = ShortcutContext(
            page: currentPage,
            isTextEditing: event.window?.firstResponder is NSTextView
        )
        guard
            let action = ShortcutResolver.action(
                for: chord, bindings: ShortcutBindings.shared.bindings, context: context)
        else { return false }

        perform(action)
        return true
    }

    /// 录制模式：消费所有按键，Esc 取消、裸 ⌫ 清空、其余按键尝试写成绑定。
    private func handleRecording(_ event: NSEvent, action: ShortcutAction) {
        // Esc 取消
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        // 裸 ⌫ 清空绑定
        if event.keyCode == 51, KeyChord.Modifier(event.modifierFlags).isEmpty {
            ShortcutBindings.shared.clear(action)
            cancelRecording()
            return
        }

        guard let chord = KeyChord.from(event) else {
            rejection = .unsupportedKey
            return
        }
        guard chord.isRecordable else {
            rejection = .needsModifier
            return
        }
        if action.allowsGlobalBinding,
            chord.modifiers.intersection([.option, .control]).isEmpty
        {
            // 全局热键会被系统吞掉：不加这条，用户把唤出绑成 ⌘C 就等于全系统失去复制。
            rejection = .globalNeedsOptionOrControl
            return
        }
        if let conflicting = ShortcutBindings.shared.conflict(for: chord, excluding: action) {
            rejection = .conflicting(conflicting)
            return
        }

        ShortcutBindings.shared.set(chord, for: action)
        cancelRecording()
    }

    // MARK: - 动作执行

    private var currentPage: ShortcutAction.Page {
        guard let viewModel else { return .instances }
        switch viewModel.contentType {
        case .chat: return .chat
        case .menu: return viewModel.menuSection == .statistics ? .statistics : .settings
        case .instances: return .instances
        }
    }

    private func perform(_ action: ShortcutAction) {
        guard let viewModel else { return }

        switch action {
        case .summon:
            performSummon(viewModel: viewModel)
        case .dismiss:
            switch viewModel.contentType {
            case .chat: viewModel.exitChat()
            case .menu: viewModel.exitMenu()
            case .instances: viewModel.notchClose()
            }
        case .openSettings:
            viewModel.toggleMenu()
        case .toggleStatistics:
            viewModel.toggleStatistics()
        case .rescan:
            Task { await UsageStatsIndexer.shared.rebuildNow() }
        case .moveSelectionUp:
            moveSelection(by: -1, viewModel: viewModel)
        case .moveSelectionDown:
            moveSelection(by: 1, viewModel: viewModel)
        case .openChat:
            guard let target = selectionTarget(viewModel: viewModel) else { return }
            viewModel.showChat(for: target)
        case .focusTerminal:
            guard let target = selectionTarget(viewModel: viewModel) else { return }
            focusTerminal(for: target, viewModel: viewModel)
        case .approve:
            guard let target = approvalTarget(viewModel: viewModel) else { return }
            // 交互式提问不是「批准」：入口是去刘海上作答，按键不越俎代庖。
            guard !isInteractivePending(target) else { return }
            sessionMonitor?.approvePermission(key: target.sessionKey)
        case .deny:
            guard let target = approvalTarget(viewModel: viewModel) else { return }
            // 提问按「跳过」处理：折成 deny 即本轮取消，与卡片上的跳过同一语义。
            sessionMonitor?.denyPermission(key: target.sessionKey, reason: nil)
        }
    }

    /// 唤出/收起：关着就展开并接管键盘；开着但键盘不在我们手上就接管键盘；已经拿着就收起。
    private func performSummon(viewModel: NotchViewModel) {
        switch viewModel.status {
        case .opened where NSApp.isActive:
            viewModel.notchClose()
        case .opened:
            takeKeyboardFocus()
        case .closed, .popping:
            viewModel.notchOpen(reason: .hotkey)
            takeKeyboardFocus()
        }
    }

    private func moveSelection(by offset: Int, viewModel: NotchViewModel) {
        let ordered = visibleSessions()
        guard !ordered.isEmpty else { return }

        let current = ordered.firstIndex { $0.sessionKey == viewModel.selectedSessionKey }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), ordered.count - 1)
        } else {
            // 还没有选中项：向下从第一行开始，向上从最后一行开始（方向感一致）。
            next = offset > 0 ? 0 : ordered.count - 1
        }
        viewModel.selectedSessionKey = ordered[next].sessionKey
    }

    private func selectionTarget(viewModel: NotchViewModel) -> SessionState? {
        ShortcutTargeting.selectionTarget(
            in: visibleSessions(), selected: viewModel.selectedSessionKey)
    }

    private func approvalTarget(viewModel: NotchViewModel) -> SessionState? {
        // 对话页先认「正在看的这个会话」的待批：用户的眼睛就在那儿。
        if case .chat(let snapshot) = viewModel.contentType,
            let current = sessionMonitor?.instances.first(where: {
                $0.sessionKey == snapshot.sessionKey
            }),
            current.phase.isWaitingForApproval
        {
            return current
        }
        return ShortcutTargeting.approvalTarget(
            in: pendingOrderedSessions(), selected: viewModel.selectedSessionKey)
    }

    /// 列表页的键盘导航目标：按**列表显示顺序**（视图写回的键）映射回当前会话状态。
    /// 顺序只有一处实现（视图），键盘不会走到看不见的行上。
    private func visibleSessions() -> [SessionState] {
        guard let viewModel, let sessionMonitor else { return [] }
        let byKey = Dictionary(
            sessionMonitor.instances.map { ($0.sessionKey, $0) },
            uniquingKeysWith: { first, _ in first })
        return viewModel.visibleSessionKeys.compactMap { byKey[$0] }
    }

    /// 待批目标的兜底顺序：待批会话不会被列表的过滤挡掉（过滤只针对已结束与空闲），
    /// 因此这里直接按状态排一遍即可。
    private func pendingOrderedSessions() -> [SessionState] {
        SessionListOrdering.sorted(sessionMonitor?.instances ?? [])
    }

    private func isInteractivePending(_ session: SessionState) -> Bool {
        guard let toolName = session.pendingToolName else { return false }
        return session.agent.isInteractiveTool(toolName)
    }

    /// 聚焦终端：与列表行同一个回退链——定位不到就退回打开对话（点了总要有反馈）。
    private func focusTerminal(for session: SessionState, viewModel: NotchViewModel) {
        Task { @MainActor in
            let focused = await TerminalFocuser.shared.focus(
                pid: session.pid, workingDirectory: session.cwd)
            guard !focused else { return }
            viewModel.showChat(for: session)
        }
    }

    // MARK: - 全局热键与键盘焦点

    private func registerGlobalHotKey() {
        guard didStart, !AppEnvironment.isRunningTests else { return }
        guard recording == nil else { return }
        guard let chord = ShortcutBindings.shared.chord(for: .summon) else {
            hotKey.unregister()
            globalHotKeyAvailable = true
            return
        }
        let registered = hotKey.register(chord)
        if !registered {
            Self.logger.notice("唤出热键注册失败：\(chord.displayLabel, privacy: .public)")
        }
        globalHotKeyAvailable = registered
    }

    /// 让面板接管键盘焦点（热键唤出路径专用：用户主动按热键就是要用键盘）。
    private func takeKeyboardFocus() {
        guard let panel else { return }

        if focusReturnTarget == nil,
            NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid()
        {
            focusReturnTarget = NSWorkspace.shared.frontmostApplication
        }
        NSApp.activate(ignoringOtherApps: false)
        panel.makeKey()
    }

    /// 收起面板时把前台交还给唤出前的应用。
    ///
    /// 只有当此刻前台仍是我们时才交还：用户如果已经点了别的窗口，交还就会把人家抢回来。
    private func restoreFocusIfNeeded() {
        guard let target = focusReturnTarget else { return }
        focusReturnTarget = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
        // 激活是异步的（约 0.5–1.2s，见 TerminalFocuser 的实测），不等结果。
        target.activate(options: [.activateAllWindows])
    }
}
