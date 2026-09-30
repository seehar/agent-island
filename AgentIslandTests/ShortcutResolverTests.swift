//
//  ShortcutResolverTests.swift
//  AgentIslandTests
//
//  按键解析（页面过滤、输入框守卫、冲突数据的确定性）与动作目标选择。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("快捷键解析")
struct ShortcutResolverTests {
    /// 全部动作都用默认绑定。
    private func defaultBindings() -> [ShortcutAction: ShortcutBinding] {
        Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, .chord($0.defaultChord)) })
    }

    @Test("动作目录与设置页行表同数：加动作必须同时改行表，否则页面会裁掉最后一行")
    func catalogShapeMatchesLayoutTable() {
        let panelActions = ShortcutAction.allCases.filter { $0.scope == .panel }
        let blocks = NotchMenuMetrics.blocks(for: .shortcuts)
        #expect(blocks.count == 2)

        // 两端各自独立地从动作枚举推出条数：行表用 `shortcutPanelRowCount`，页面用同一个
        // 筛选（`ShortcutsSettingsPage.panelActions`）。写死数字的旧版会让新加的动作落到
        // 解析式之外——面板按行表撑高，行表少了就在页面上被裁掉最后一行。
        #expect(
            blocks[1].rows.count == panelActions.count,
            "行表 \(blocks[1].rows.count) 行 vs 面板内动作 \(panelActions.count) 条")
        #expect(NotchMenuMetrics.shortcutPanelRowCount == panelActions.count)

        // 另一张卡只有全局那一条（目前唯一的全局动作就是唤出/收起）。
        #expect(blocks[0].rows.count == ShortcutAction.allCases.count - panelActions.count)
        #expect(ShortcutAction.summon.scope == .global)
        #expect(panelActions.contains(.summon) == false)
    }

    @Test("默认绑定在各自的生效页面上都能解析出来")
    func defaultChordsResolveOnTheirPages() {
        let bindings = defaultBindings()
        for action in ShortcutAction.allCases where action.scope == .panel {
            #expect(!action.pages.isEmpty, "\(action.rawValue) 没有声明生效页面")
            for page in action.pages {
                let resolved = ShortcutResolver.action(
                    for: action.defaultChord, bindings: bindings,
                    context: ShortcutContext(page: page))
                #expect(resolved == action, "\(action.rawValue) 在 \(page) 上没解析出来")
            }
        }
    }

    @Test("全局动作永不被本地监视解析：同一次按键不能处理两遍")
    func globalActionNeverResolvesLocally() {
        let bindings = defaultBindings()
        for page in [
            ShortcutAction.Page.instances, .chat, .settings, .statistics,
        ] {
            #expect(
                ShortcutResolver.action(
                    for: ShortcutAction.summon.defaultChord, bindings: bindings,
                    context: ShortcutContext(page: page)) == nil)
        }
    }

    @Test("页面过滤：只在本页生效的动作不会跨页命中")
    func pageFiltering() {
        let bindings = defaultBindings()
        // 重新统计只在统计页
        #expect(
            ShortcutResolver.action(
                for: ShortcutAction.rescan.defaultChord, bindings: bindings,
                context: ShortcutContext(page: .instances)) == nil)
        // 列表导航、打开对话、聚焦终端只在列表页
        for action in [
            ShortcutAction.moveSelectionUp, .moveSelectionDown, .openChat, .focusTerminal,
        ] {
            #expect(
                ShortcutResolver.action(
                    for: action.defaultChord, bindings: bindings,
                    context: ShortcutContext(page: .chat)) == nil,
                "\(action.rawValue) 不该在对话页命中")
        }
    }

    @Test("输入框聚焦时：只有返回/收起与批准仍然生效")
    func textEditingGuard() {
        let bindings = defaultBindings()
        let allowed: [ShortcutAction] = [.dismiss, .approve]
        let blocked: [ShortcutAction] = [
            .deny, .moveSelectionUp, .moveSelectionDown, .openChat, .focusTerminal, .openSettings,
            .toggleStatistics,
        ]

        for page in [
            ShortcutAction.Page.instances, .chat, .settings, .statistics,
        ] {
            for action in allowed where action.pages.contains(page) {
                #expect(
                    ShortcutResolver.action(
                        for: action.defaultChord, bindings: bindings,
                        context: ShortcutContext(page: page, isTextEditing: true)) == action,
                    "\(action.rawValue) 在输入框聚焦时应当仍然生效")
            }
            for action in blocked where action.pages.contains(page) {
                #expect(
                    ShortcutResolver.action(
                        for: action.defaultChord, bindings: bindings,
                        context: ShortcutContext(page: page, isTextEditing: true)) == nil,
                    "\(action.rawValue) 在输入框聚焦时应当让位给文本编辑")
            }
        }
    }

    @Test("未绑定的动作永不命中")
    func unboundNeverMatches() {
        var bindings = defaultBindings()
        bindings[.openChat] = .unbound

        // 它自己的生效页面上也不命中，别的页面同样不命中（清空 = 彻底不生效）
        for page in [
            ShortcutAction.Page.instances, .chat, .settings, .statistics,
        ] {
            #expect(
                ShortcutResolver.action(
                    for: ShortcutAction.openChat.defaultChord, bindings: bindings,
                    context: ShortcutContext(page: page)) == nil)
        }

        // 清空是按动作生效的：另一个动作也清空后，它的组合同样不再命中
        bindings[.dismiss] = .unbound
        #expect(
            ShortcutResolver.action(
                for: ShortcutAction.dismiss.defaultChord, bindings: bindings,
                context: ShortcutContext(page: .instances)) == nil)
    }

    @Test("同一按键被多个动作绑定：按声明顺序取第一个（确定性）")
    func duplicateBindingIsDeterministic() {
        var bindings = defaultBindings()
        bindings[.approve] = .chord(ShortcutAction.dismiss.defaultChord)

        #expect(
            ShortcutResolver.action(
                for: ShortcutAction.dismiss.defaultChord, bindings: bindings,
                context: ShortcutContext(page: .instances)) == .dismiss)
    }

    @Test("不相交页面上的同键共存：列表页是打开对话、统计页是重新统计")
    func disjointPagesShareAChord() {
        var bindings = defaultBindings()
        bindings[.rescan] = .chord(ShortcutAction.openChat.defaultChord)
        let chord = ShortcutAction.openChat.defaultChord

        #expect(
            ShortcutResolver.action(
                for: chord, bindings: bindings, context: ShortcutContext(page: .instances))
                == .openChat)
        #expect(
            ShortcutResolver.action(
                for: chord, bindings: bindings, context: ShortcutContext(page: .statistics))
                == .rescan)
    }
}

@Suite("快捷键作用目标")
struct ShortcutTargetingTests {
    /// 一个待批会话。
    private func awaiting(sessionId: String, lastActivity: Date = Date()) -> SessionState {
        SessionState(
            agent: .claudeCode,
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-\(sessionId)", toolName: "Bash", toolInput: nil,
                    receivedAt: lastActivity)),
            lastActivity: lastActivity
        )
    }

    private func idle(sessionId: String, lastActivity: Date = Date()) -> SessionState {
        SessionState(
            agent: .claudeCode, sessionId: sessionId, cwd: "/tmp/\(sessionId)",
            phase: .idle, lastActivity: lastActivity)
    }

    @Test("上下移动：无选中时按方向落到两端，到边界不环绕，空列表不动作")
    func movedSelectionIndexBoundaries() {
        // 空列表：不动
        #expect(ShortcutTargeting.movedSelectionIndex(current: nil, offset: 1, count: 0) == nil)
        #expect(ShortcutTargeting.movedSelectionIndex(current: 0, offset: -1, count: 0) == nil)

        // 还没有选中项：向下落第一行，向上落最后一行
        #expect(ShortcutTargeting.movedSelectionIndex(current: nil, offset: 1, count: 4) == 0)
        #expect(ShortcutTargeting.movedSelectionIndex(current: nil, offset: -1, count: 4) == 3)

        // 中间：正常加减
        #expect(ShortcutTargeting.movedSelectionIndex(current: 2, offset: 1, count: 4) == 3)
        #expect(ShortcutTargeting.movedSelectionIndex(current: 2, offset: -1, count: 4) == 1)

        // 边界：停住，不绕回另一头
        #expect(ShortcutTargeting.movedSelectionIndex(current: 0, offset: -1, count: 4) == 0)
        #expect(ShortcutTargeting.movedSelectionIndex(current: 3, offset: 1, count: 4) == 3)

        // 单行：怎么按都是它
        #expect(ShortcutTargeting.movedSelectionIndex(current: nil, offset: 1, count: 1) == 0)
        #expect(ShortcutTargeting.movedSelectionIndex(current: 0, offset: -1, count: 1) == 0)
    }

    @Test("打开对话的目标：选中优先，没有选中时取第一行")
    func selectionTargetPrefersSelection() {
        let first = idle(sessionId: "first")
        let second = idle(sessionId: "second")
        let ordered = [first, second]

        #expect(ShortcutTargeting.selectionTarget(in: ordered, selected: nil)?.sessionId == "first")
        #expect(
            ShortcutTargeting.selectionTarget(in: ordered, selected: second.sessionKey)?.sessionId
                == "second")
    }

    @Test("选中的会话已经不在列表里：回落第一行，而不是什么都不做")
    func selectionTargetFallsBackWhenSelectionIsGone() {
        let only = idle(sessionId: "only")
        let stale = SessionKey(agent: .claudeCode, sessionId: "gone")

        #expect(ShortcutTargeting.selectionTarget(in: [only], selected: stale)?.sessionId == "only")
    }

    @Test("批准/拒绝的目标：选中的行待批就用它，否则取最靠前的待批行")
    func approvalTargetPrefersSelectedPending() {
        let pending = awaiting(sessionId: "pending")
        let plain = idle(sessionId: "plain")
        let other = awaiting(sessionId: "other")
        let ordered = [pending, plain, other]

        // 没有选中 → 第一个待批（列表里最靠上的那张卡片）
        #expect(
            ShortcutTargeting.approvalTarget(in: ordered, selected: nil)?.sessionId == "pending")
        // 选中项待批 → 用它
        #expect(
            ShortcutTargeting.approvalTarget(in: ordered, selected: other.sessionKey)?.sessionId
                == "other")
        // 选中项不待批 → 回落第一个待批，而不是选中的那一行
        #expect(
            ShortcutTargeting.approvalTarget(in: ordered, selected: plain.sessionKey)?.sessionId
                == "pending")
    }

    @Test("没有任何待批时：批准/拒绝没有目标")
    func approvalTargetIsNilWithoutPending() {
        let ordered = [idle(sessionId: "a"), idle(sessionId: "b")]
        #expect(ShortcutTargeting.approvalTarget(in: ordered, selected: nil) == nil)
    }
}

@MainActor
@Suite("返回/收起：展开块优先")
struct ShortcutDismissTests {
    /// 一个只有展开态的参与方：登记处只认 `PickerExpansionControlling`，不必是真正的选择器。
    private final class FakePicker: PickerExpansionControlling {
        var isPickerExpanded = false
    }

    private func makeModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 300, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowHeight: 750,
            hasPhysicalNotch: false
        )
    }

    @Test("Esc：先收起展开的选项列表，收掉了就不离开设置页")
    func escapeCollapsesExpandedPickerBeforeLeavingThePage() {
        // 登记处是全局共享状态：先清干净，起点才有意义。
        while PickerExpansion.collapseCurrent() {}

        let model = makeModel()
        model.notchOpen(reason: .click)
        model.contentType = .menu

        let picker = FakePicker()
        picker.isPickerExpanded = true
        PickerExpansion.willExpand(picker)

        ShortcutController.shared.dismiss(viewModel: model)

        #expect(picker.isPickerExpanded == false, "Esc 应当先把展开的选项列表收起来")
        #expect(model.contentType == .menu, "这一次按键不该把整页也带走")

        // 展开块已经收起：下一次 Esc 才轮到面上的逐层返回。
        ShortcutController.shared.dismiss(viewModel: model)
        #expect(model.contentType == .instances)
    }

    @Test("没有展开块时 Esc 照旧逐层返回：设置页 → 会话列表")
    func escapeWithoutExpansionLeavesThePage() {
        while PickerExpansion.collapseCurrent() {}

        let model = makeModel()
        model.notchOpen(reason: .click)
        model.contentType = .menu

        ShortcutController.shared.dismiss(viewModel: model)
        #expect(model.contentType == .instances)
    }

    @Test("登记陈旧（登记还在、其实已经收起）时不吞掉这一次 Esc")
    func staleRegistrationDoesNotSwallowEscape() {
        while PickerExpansion.collapseCurrent() {}

        let model = makeModel()
        model.notchOpen(reason: .click)
        model.contentType = .menu

        // 有的路径直接改 `isPickerExpanded`、不走登记处，登记因此可能是陈旧的。
        let picker = FakePicker()
        PickerExpansion.willExpand(picker)

        ShortcutController.shared.dismiss(viewModel: model)
        #expect(model.contentType == .instances, "收起态的选择器不该吃掉 Esc")
    }
}
