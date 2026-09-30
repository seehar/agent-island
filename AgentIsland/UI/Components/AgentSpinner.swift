//
//  AgentSpinner.swift
//  AgentIsland
//
//  处理中状态的逐帧动画。帧表沿用各 Agent 自己 TUI 的：Claude Code 是
//  `·✢✳∗✻✽`；Oh My Pi / Pi 取自 pi 引擎（pi_natives）里的盲文转轮；OpenCode
//  取自其可执行文件内 spinner 的 frames 数组。无归属 Agent 时用同一套盲文转轮
//  ——它是本机多数 Agent 的通用语汇，也避免默认落回 Claude 的帧表。
//
//  两档「不转」：系统「减弱动态效果」开着，或动效速度档位是 0
//  （`AppSettings.mascotAnimationSpeed`，与角色共用同一条偏好）——都定格在帧表的第一帧，
//  不是空白。其余档位（0.5 / 1 / 2）缩放时间轴：`t` 与帧间隔一起按倍率换算，转轮真的变慢
//  或变快（节拍仍是各 Agent 那一套，只是播放速率不同）。
//

import SwiftUI

struct AgentSpinner: View {
    /// 归属的 Agent；nil 表示无归属的通用转轮。
    let agent: AgentKind?

    /// 字号，同时也是帧的占位宽度。
    var size: CGFloat = 12

    /// 覆盖转轮配色；nil 表示用该 Agent 的品牌色，无归属时退回应用强调色。
    var color: Color? = nil

    /// 系统「减弱动态效果」：开着就定格一帧，不建时钟。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 动效速度档位（与角色共用同一条偏好，见 `AppSettings.mascotAnimationSpeed`）。
    @AppStorage(AppSettings.mascotAnimationSpeedKey) private var animationSpeed: Double = 1

    /// 帧节拍。各 Agent 的 TUI 节拍并不相同（OpenCode 是 0.04s），但刘海里只有
    /// 12pt，照搬 TUI 的速度会像闪烁，所以统一到 0.15s。
    static let frameInterval: TimeInterval = 0.15

    var body: some View {
        if frozen {
            glyph(at: Self.epoch)
        } else {
            TimelineView(.periodic(from: Self.epoch, by: Self.frameInterval / speed)) { context in
                glyph(at: Self.epoch.addingTimeInterval(scaledSeconds(since: context.date)))
            }
        }
    }

    /// 这一帧的 `Text`。`date` 是**缩放后**的时刻：帧序列按档位倍率推进。
    private func glyph(at date: Date) -> some View {
        Text(Self.glyph(for: agent, at: date))
            .font(.system(size: size, weight: .bold))
            .foregroundColor(tint)
            .frame(width: size, alignment: .center)
    }

    /// 档位夹到 0 / 0.5 / 1 / 2（偏好域里可能是手改过的连续值）。
    private var speed: Double { AppSettings.clampedMascotAnimationSpeed(animationSpeed) }

    /// 是否定格：系统「减弱动态效果」或 0 档。定为帧表的**第一帧**（各 Agent 自己那一套的
    /// 起始帧），是这套语汇里最有代表性的一帧，也不依赖当前时刻。
    private var frozen: Bool { reduceMotion || speed == 0 }

    /// 从相位原点算起的秒数，按档位缩放。
    private func scaledSeconds(since date: Date) -> TimeInterval {
        date.timeIntervalSince(Self.epoch) * speed
    }

    /// 实际配色：调用方未覆盖时用该 Agent 的品牌色，无归属时退回应用强调色。
    private var tint: Color { color ?? agent?.brandColor ?? TerminalColors.prompt }

    /// 帧序列的相位原点。所有转轮共用它，因此同一 Agent 的多个转轮始终同相，
    /// 不会各走各的。
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// 某一时刻应显示的帧：按绝对时间取模，而不是各自计数。
    static func glyph(for agent: AgentKind?, at date: Date) -> String {
        let frames = frames(for: agent)
        let tick = Int((date.timeIntervalSince(epoch) / frameInterval).rounded(.down))
        return frames[tick % frames.count]
    }

    /// 各 Agent「处理中」的帧表。
    static func frames(for agent: AgentKind?) -> [String] {
        switch agent {
        case .claudeCode:
            return ["·", "✢", "✳", "∗", "✻", "✽"]
        default:
            // 其余 Agent（含无归属的 nil）统一用盲文转轮：它是本机多数 TUI 的通用语汇，
            // 也避免默认落回 Claude 的帧表。各 Agent 自己的帧表在拿到真机证据后再逐个补。
            return ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        AgentSpinner(agent: .claudeCode)
        AgentSpinner(agent: .ohMyPi)
        AgentSpinner(agent: .pi)
        AgentSpinner(agent: .opencode)
        AgentSpinner(agent: nil)
    }
    .frame(width: 40, height: 120)
    .background(.black)
}
