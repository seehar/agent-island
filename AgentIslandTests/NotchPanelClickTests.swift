//
//  NotchPanelClickTests.swift
//  AgentIslandTests
//
//  面板点击归属：展开时**面板内部**的点击全部归 SwiftUI（头部条带里的按钮优先），
//  鼠标监听只处理「点面板外面 → 收起」。这里钉住那次修复——判定带曾经是**关闭态胶囊**
//  矩形，用户把胶囊调宽后头部按钮落进带里（300pt 时带右边缘 1110，统计按钮命中区
//  [1089, 1111]），点击被抢走：灵动岛收起而不是切页。
//

import CoreGraphics
import Foundation
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
}
