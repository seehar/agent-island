//
//  NotchMenuSubscriptionTests.swift
//  AgentIslandTests
//
//  面板尺寸的**订阅**不变量（值选择器就地展开）。
//
//  两条都要钉：
//  1. **每一个值选择器展开都要撑高面板、且都要被订阅**。面板内的点击不走
//     `handleMouseDown`（落在面板内会直接 return），只有订阅路径才会让 `openedSize` 重算；
//     漏一个的症状是「展开那一行面板不长高、内容被下边缘裁掉」——版面表与高度公式本身
//     都是对的，预算用例抓不到它（本仓历史上漏过三次）。
//  2. **展开增量不被夹掉**：`panelHeight` 把静态内容夹到本面上限之后再加展开增量，
//     因此一个选择器展开时面板正好长高它那么多。
import Combine
import CoreGraphics
import Testing

@testable import AgentIsland

@MainActor
@Suite("设置面板的尺寸订阅", .serialized)
struct NotchMenuSubscriptionTests {
    /// 与真实窗口同形：内置刘海 32 → chrome 44。
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 180, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750,
            hasPhysicalNotch: true)
    }

    /// 该模型的固定开销（与 `NotchViewModel.panelChromeHeight` 同式）。
    private func chrome(_ model: NotchViewModel) -> CGFloat {
        max(24, model.deviceNotchRect.height) + 12
    }

    /// 触发一次变化，返回 `NotchViewModel` 重发布的次数。
    private func republications(_ model: NotchViewModel, change: () -> Void) -> Int {
        var count = 0
        var bag = Set<AnyCancellable>()
        model.objectWillChange
            .sink { _ in count += 1 }
            .store(in: &bag)
        change()
        return count
    }

    /// 把「还参与高度账」的三项复位成中性：用例自己建立前置，不依赖别的用例留下的状态。
    private func resetHeightContributors() {
        AgentDirSelector.shared.expandedKind = nil
        NewAPIAccountPageState.shared.isEditingCredentials = false
        NewAPIAccountPageState.shared.setAccountCount(1)
        NewAPIAccountPageState.shared.setOptionalDetailRowCount(0)
    }

    /// 走**浮层**展示的每一个选择器：新增一个选择行时这里补一行（它是「浮层清单」的镜像）。
    private var valuePickers:
        [(name: String, section: NotchMenuSection, picker: any PickerExpansionControlling)]
    {
        [
            ("语言", .general, LanguageSelector.shared),
            ("屏幕", .general, ScreenSelector.shared),
            ("胶囊高度", .general, NotchHeightSelector.shared),
            ("胶囊宽度", .general, NotchWidthSelector.shared),
            ("内容字号", .general, TextSizeSelector.shared),
            ("面板尺寸", .general, PanelSizeSelector.shared),

            ("悬停展开", .behavior, HoverExpandSelector.shared),
            ("空闲胶囊", .behavior, IdleNotchVisibilitySelector.shared),
            ("关闭态刘海", .behavior, ClosedCapsuleLayoutSelector.shared),
            ("已结束会话", .behavior, SessionRetentionSelector.shared),
            ("行信息密度", .behavior, SessionRowDensitySelector.shared),
            ("单击动作", .behavior, SessionRowClickActionSelector.shared),
            ("刷新频率", .behavior, RefreshCadenceSelector.shared),

            ("通知音效", .notifications, SoundSelector.shared),
            ("安静时段", .notifications, QuietHoursSelector.shared),
            ("提示音范围", .notifications, NotificationScopeSelector.shared),
            ("完成提示", .notifications, CompletionBadgeSelector.shared),

            ("运行前询问什么", .agents, ApprovalAskScopeSelector.shared),
            ("应用未运行时", .agents, ApprovalDegradationSelector.shared),
            ("待批自动展开", .agents, ApprovalAutoExpandSelector.shared),
        ]
    }

    @Test("值选择器就地展开：撑高面板，且每一个都被订阅")
    func valuePickersGrowThePanelAndAreObserved() {
        let model = makeViewModel()
        model.contentType = .menu
        resetHeightContributors()
        defer { resetHeightContributors() }

        for (name, section, picker) in valuePickers {
            picker.isPickerExpanded = false
            model.menuSection = section

            let collapsed = model.openedSize.height
            #expect(
                collapsed == NotchMenuMetrics.contentHeight(for: section) + chrome(model),
                "「\(name)」所在的 \(section.rawValue) 页高度里还有展开项：内容 \(NotchMenuMetrics.contentHeight(for: section)) + 开销 \(chrome(model)) ≠ \(collapsed)"
            )

            let count = republications(model) { picker.isPickerExpanded = true }
            #expect(count > 0, "「\(name)」展开时没有重发布：漏了它的订阅")
            #expect(
                model.openedSize.height > collapsed,
                "「\(name)」展开后 \(section.rawValue) 页的面板没有变高")
            #expect(
                model.openedSize.height <= NotchMenuMetrics.maxDashboardHeight,
                "「\(name)」展开后越过了窗口上限")

            picker.isPickerExpanded = false
        }
    }

    @Test("还就地展开的两处仍然撑高面板，且都被订阅（漏订阅 ⇒ 面板不重算）")
    func inlineEditorsStillGrowThePanelAndAreObserved() {
        let model = makeViewModel()
        model.contentType = .menu
        resetHeightContributors()
        defer { resetHeightContributors() }

        // ① 智能体页的行内目录编辑器：展开后面板变高。带编辑器时该页已越过 640、被夹到上限
        // （夹取登记在 `NotchMenuMetricsTests.clampedPairs`），因此这里只钉「确实算进了高度」。
        model.menuSection = .agents
        let agentsCollapsed = model.openedSize.height
        let editorRepublications = republications(model) {
            AgentDirSelector.shared.expandedKind = .claudeCode
        }
        #expect(
            editorRepublications > 0,
            "目录编辑器展开时 NotchViewModel 没有重发布：漏了 `AgentDirSelector.$expandedKind` 的订阅")
        #expect(
            model.openedSize.height > agentsCollapsed,
            "目录编辑器展开后面板没有变高（\(agentsCollapsed) → \(model.openedSize.height)）")

        // ② 额度页：**读数态**高度随账号数变（列表窗口按行数撑），**编辑态**折叠成一行 ⇒
        // 与账号数无关。这正是「两个运行时项不会叠加」的意思。
        model.menuSection = .quota
        NewAPIAccountPageState.shared.setAccountCount(1)
        let oneAccount = model.openedSize.height
        NewAPIAccountPageState.shared.setAccountCount(4)
        let fourAccounts = model.openedSize.height
        #expect(
            fourAccounts > oneAccount,
            "读数态下账号数没有撑高额度页（\(oneAccount) → \(fourAccounts)）")

        let quotaRepublications = republications(model) {
            NewAPIAccountPageState.shared.isEditingCredentials = true
        }
        #expect(
            quotaRepublications > 0,
            "「编辑凭据」展开时 NotchViewModel 没有重发布：漏了 `NewAPIAccountPageState` 的订阅")

        NewAPIAccountPageState.shared.setAccountCount(1)
        let editingOne = model.openedSize.height
        NewAPIAccountPageState.shared.setAccountCount(4)
        let editingFour = model.openedSize.height
        #expect(
            editingFour == editingOne,
            "编辑凭据态下高度跟着账号数变了（\(editingOne) → \(editingFour)）：列表应当折叠成一行")
    }

    @Test("面板尺寸档仍然被订阅：换档立刻改变面板宽度")
    func panelSizeSelectorStillRePublishesAndChangesWidth() {
        let model = makeViewModel()
        model.contentType = .menu
        model.menuSection = .general

        let previous = PanelSizeSelector.shared.option
        defer { PanelSizeSelector.shared.select(previous) }

        PanelSizeSelector.shared.select(.standard)
        let standard = model.openedSize.width
        let count = republications(model) { PanelSizeSelector.shared.select(.compact) }

        #expect(count > 0, "换面板尺寸档时 NotchViewModel 没有重发布：漏了 `PanelSizeSelector` 的订阅")
        #expect(
            model.openedSize.width < standard,
            "紧凑档的面板宽度没有变窄：`openedSize.width` 没有按档位缩放")
    }

    @Test("离开设置面或换页时收起展开的浮层（浮层的主人随页面卸载）")
    func leavingTheSettingsFaceCollapsesTheOverlay() {
        let model = makeViewModel()
        model.contentType = .menu
        model.menuSection = .general

        let picker = HoverExpandSelector.shared
        defer { picker.isPickerExpanded = false }

        // 走**真实路径** `toggleExpansion()`（行内点按就是它）：顺带在 `PickerExpansion`
        // 登记，收起才找得到这一块。直接改 `isPickerExpanded` 不登记，那是测试自己的失真。
        picker.isPickerExpanded = false
        picker.toggleExpansion()
        #expect(picker.isPickerExpanded)

        model.menuSection = .behavior
        #expect(!picker.isPickerExpanded, "换页后上一页的浮层没有收起")

        model.menuSection = .general
        picker.toggleExpansion()
        model.notchClose()
        #expect(!picker.isPickerExpanded, "收起面板后浮层没有收起（它下次会凭空冒出来）")
        #expect(model.contentType == .instances)
    }
}
