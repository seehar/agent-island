//
//  AgentMascotShowcase.swift
//  AgentIsland
//
//  轮播的 Agent 角色缩略图：每 `rotateInterval` 秒换一位 Agent，循环 `AgentKind.allCases`。
//
//  用在「标记动态」的入口行上：那个入口讲的是**所有** Agent 的动画，指向某一个品牌是
//  「张冠李戴」（与头部标记的归属规则同一条），轮播因此既传达了「不止一个」，
//  又让这一行在列表里一眼看得出「里面是活的」。
//
//  它**不带黑底舞台**：调用方要给一个黑底方块（角色的部件里有挖空与白色像素，
//  黑底才读得出形状），见 `SettingsBadge.Source.mascot`。
//

import SwiftUI

struct AgentMascotShowcase: View {
    /// 舞台边长（调用方通常给图标块的边长）。
    var size: CGFloat = 22

    /// 换角色的间隔：太短会闪、太长就看不出是轮播。
    static let rotateInterval: TimeInterval = 2.5

    var body: some View {
        TimelineView(.periodic(from: MascotMotion.epoch, by: Self.rotateInterval)) { context in
            let elapsed = context.date.timeIntervalSince(MascotMotion.epoch)
            let kinds = AgentKind.allCases
            let index = Int(elapsed / Self.rotateInterval) % kinds.count
            // 角色的动画由 `AgentMascot` 自己的时钟推进（这里只负责挑 Agent）。
            AgentMascot(agent: kinds[index], status: .working, size: size)
        }
    }
}
