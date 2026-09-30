//
//  AppMotion.swift
//  AgentIsland
//
//  全应用共用的动效闸门：把「减弱动态效果」（系统辅助功能偏好）收成一个入口。
//
//  为什么需要它：`withAnimation` / `.animation` 只认一条曲线，系统的辅助功能偏好**不会**
//  自动作用到自定义动画上——各处于是各写一遍 `reduceMotion ? … : …`，很容易漏（改造前
//  全仓 0 处读 `accessibilityReduceMotion`，等于这一档偏好对应用无效）。这里把「减弱动态
//  时换哪条曲线」定在一处：调用方照旧传自己那条曲线，由 `pick` 换掉。
//
//  口径：`reduced` 只换「怎么到那儿」，**不换终态**。它是一条 0.12 秒的缓出，没有回弹、
//  没有长距离位移；调用方仍然负责在减弱动态时别做位移/缩放这类大动作——曲线本身管不了
//  这件事（它只描述时间，不描述走了多远）。
//

import SwiftUI

/// 应用的动效闸门。
///
/// `nonisolated`：曲线是纯值，视图（MainActor）与非隔离代码都要能取，标了才不会被默认的
/// MainActor 隔离挡住。
nonisolated enum AppMotion {
    /// 「减弱动态」时替代弹性 / 长过渡的曲线：短促的缓出，只让取值落到终点。
    ///
    /// 0.12 秒足以让人看出「这里变了」，又短到不构成一段可感知的运动；比它更短会变成
    /// 硬切（那正是这一档偏好要避免的「突现」），更长则又回到了「有一段动画」。
    static let reduced: Animation = .easeOut(duration: 0.12)

    /// 按「减弱动态」偏好挑曲线：开着给 `reduced`，否则原样返回。
    ///
    /// - Parameters:
    ///   - animation: 正常情况下的曲线（弹性、长过渡都可以）。
    ///   - reduceMotion: 系统的「减弱动态效果」偏好，调用方从环境读
    ///     （`@Environment(\.accessibilityReduceMotion)`）。
    static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}