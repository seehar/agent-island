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
//  动效速度档位（`AppSettings.mascotAnimationSpeed`）在这里也要读：轮播节拍按倍率缩放，
//  「定格」档（0）整行不再轮换——那一档的语义是「画面上没有东西在动」，而轮播正是这一行
//  在动的那一部分，因此停在同一枚 Agent 的定格帧上（角色本身也由 `AgentMascot` 按同一档
//  定帧）。代价是这一行的标记不再轮换——它本来是「所有 Agent」的表达，停在一枚上确实弱了
//  一档；要看全 18 枚就进「标记动态」页。
//
//  系统「减弱动态效果」**不**在这里停轮播：它管的是角色的动画，而 `AgentMascot` 自己会把
//  角色定格（见其头部），轮播只是换一枚角色、本身没有运动。停掉它反而会让这一行永久指向
//  某一枚品牌——那正是这个组件要避免的「张冠李戴」。
//

import SwiftUI

struct AgentMascotShowcase: View {
    /// 舞台边长（调用方通常给图标块的边长）。
    var size: CGFloat = 22

    /// 动效速度档位（与角色、转轮共用同一条偏好）。
    @AppStorage(AppSettings.mascotAnimationSpeedKey) private var animationSpeed: Double = 1

    /// 换角色的间隔：太短会闪、太长就看不出是轮播。
    static let rotateInterval: TimeInterval = 2.5

    var body: some View {
        if frozen {
            AgentMascot(agent: firstKind, status: .working, size: size)
        } else {
            TimelineView(.periodic(from: MascotMotion.epoch, by: Self.rotateInterval / speed)) {
                context in
                // 角色的动画由 `AgentMascot` 自己的时钟推进（这里只负责挑 Agent）。
                AgentMascot(agent: kind(at: context.date), status: .working, size: size)
            }
        }
    }

    /// 定格档要显示的那一枚：`AgentKind.allCases` 的第一枚（顺序与列表一致，跨启动稳定）。
    private var firstKind: AgentKind { AgentKind.allCases[0] }

    /// 档位夹到 0 / 0.5 / 1 / 2（偏好域里可能是手改过的连续值）。
    private var speed: Double { AppSettings.clampedMascotAnimationSpeed(animationSpeed) }

    /// 是否停住：只有 0 档（「定格」）不轮换。
    private var frozen: Bool { speed == 0 }

    /// 某一时刻该显示哪一枚 Agent。时刻与节拍**一起**按档位缩放，因此倍率改变时轮到的
    /// 那一枚不会跳。
    private func kind(at date: Date) -> AgentKind {
        let kinds = AgentKind.allCases
        let elapsed = date.timeIntervalSince(MascotMotion.epoch) * speed
        let index = Int(elapsed / Self.rotateInterval) % kinds.count
        return kinds[index]
    }
}