//
//  AgentMascot.swift
//  AgentIsland
//
//  18 个 Agent 的运行时**像素角色**：刘海头部与「标记动态」页都从这里取。
//
//  分工（改这一层之前先读这一段）：
//    · 本文件：活动状态、时钟、Agent → 角色的路由（以及单测要读的起跳截顶入参）。
//    · `MascotMotion` / `MascotKit`：曲线与绘制工具（不含任何角色专属逻辑）。
//    · `Mascots/<角色>.swift`：一枚角色的画法与三套场景。
//
//  三套场景的语义（每枚角色都必须做到）：
//    · `idle`：睡觉——趴着打盹、呼吸起伏、头顶飘 Z，偶尔翻个身；
//    · `working`：按该角色自己的形态做**招牌动作**（打字、齿轮转、等化器跳、绕行…），
//      一眼看得出它在干活，而不是「所有角色一起上下弹」；
//    · `alert`：注意到你了——3.5 秒一轮的起跳（一跳比一跳矮）+ 瞪眼 + 头顶惊叹号。
//
//  `alert` 的起跳由**每一枚角色自己**画（姿态、影子、惊叹号都在同一个画布里，影子因此
//  留在地上而不是跟着跳）。周期统一是 3.5 秒、语义统一是「三跳、一跳比一跳矮、惊叹号」，
//  所以它仍是一个统一的**应用级**信号（「有事等你」）——只是不再由本文件的公共层施加位移，
//  而且个别角色（Pi / Hermes）沿用上游自己那张略有出入的位移表。
//
//  场景移植自 CodeIsland（MIT，Copyright (c) 2026 wxtsky）：坐标常量、配色与关键帧逐值保留，
//  但**时间一律显式传参**（`t` 由本文件的时钟给出），因此每一帧都是 `t` 的纯函数。
//
//  姿态约定：`t == 0` 必须是该场景最有代表性的一帧（不眨眼、不压扁、不位移）——
//  离屏定帧探针与单测都取这一帧，因此这不是审美问题而是契约。「静止」档位另取
//  各场景的代表时刻（见 `AgentMascotStatus.stillInstant`）。
//
//  三种「不建时钟」的情形（都画代表帧，都不是空白帧，也都不随墙上时钟走）：
//    · 调用方给了 `frozenTime`（画廊、探针、单测）——以它为准，与用户偏好无关；
//    · 系统「减弱动态效果」开着（`accessibilityReduceMotion`）；
//    · 动效速度档位是 0 档（`AppSettings.mascotAnimationSpeed`）。
//  其余档位（0.5 / 1 / 2）**缩放时间轴**：`t` 与帧间隔一起按倍率换算，动画是真的变慢 /
//  变快，而不是只改变采样密度。
//

import SwiftUI

/// 角色当前的活动状态，由会话阶段推导。
enum AgentMascotStatus: Hashable {
    /// 没在跑：趴着打盹（呼吸 + 飘 Z），像活物在喘气。
    case idle
    /// 处理中：该角色自己的招牌动作。
    case working
    /// 等待审批：起跳 + 瞪眼 + 惊叹号（姿态由每枚角色自己画）。
    case alert

    /// 由会话阶段推导。映射只写在这一处，避免各调用点各写一遍。
    init(_ phase: SessionPhase) {
        if phase.isWaitingForApproval {
            self = .alert
        } else if phase == .processing || phase == .compacting {
            self = .working
        } else {
            self = .idle
        }
    }

    /// 帧间隔：忙碌时更细腻，空闲时省电。
    var frameInterval: TimeInterval {
        switch self {
        case .idle: return 0.125
        case .working, .alert: return 0.05
        }
    }

    /// 「静止」档位要定格的时刻。取时刻要同时满足两件事：
    ///
    ///  · **睁着眼**：`blink` 的相位由角色的 seed 决定，18 枚各不相同；t 若落在某一枚的
    ///    眨眼窗口里，它就会以「闭着眼」的样子出现在静止档（实测 t=1.5 正中 gemini 的眨眼）。
    ///    各 seed 的首次眨眼都从 t ≥ 0.6 才开始，因此取 ≤ 0.55 的时刻对所有角色都睁着眼。
    ///  · **有代表性**：空闲取静息帧（呼吸到底、四平八稳），处理中取动作中段（走步已经迈出去，
    ///    多数角色的招牌动作在这一刻都已离开静息位），待审批取**第一次起跳刚离地**那一帧
    ///    ——静止档看到的必须是「有人在喊你」那一帧，而不是站着不动的平常样。
    ///
    /// 待审批档取 0.35s（周期 3.5s 的 pct 0.10）：落在各角色**自己的**惊觉窗口里——
    /// 多数角色的瞪眼窗口是 pct 0.03…0.15（t 0.105…0.525，0.35 在窗内，而 0.55 已出窗），
    /// 惊叹号在这一段满亮（bangOpacity = 1），身体刚离开地面。取 0.35 而不是更晚还因为
    /// **首次眨眼的下限**：各角色的眨眼 seed 不同，最紧的一枚（Gemini，seed 0x40E）从
    /// t = 0.65 起才可能闭眼，0.35 对全部角色都睁着眼。
    /// 这条口径由 `MascotMotionTests`（`blink(stillInstant, seed) == 1`）与
    /// `AgentMascotRenderTests`（三档在代表时刻的姿态指纹互不相同）一起钉住。
    var stillInstant: Double {
        switch self {
        case .idle: return 0
        case .working: return 0.45
        case .alert: return 0.35
        }
    }
}

/// 一个 Agent 的运行时角色。
///
/// `frozenTime` 给定时刻时只画那一帧、不建时钟：画廊、轮播缩略图、探针与单测都走这条路
/// （时间**显式传参**，不走环境变量——环境值在离屏渲染里一旦没传到，就会静默退回
/// 「按当前时刻现算」，那是随机画面的来源）。
struct AgentMascot: View {
    let agent: AgentKind

    /// 当前活动状态，由调用方按会话阶段传入。
    var status: AgentMascotStatus

    /// 舞台边长。角色画在 `size × size` 的方形舞台里，纵向留出起跳的余量。
    var size: CGFloat = 27

    /// 定格时刻（秒）：给值时只画这一帧，不建时钟。
    var frozenTime: Double? = nil

    /// 系统「减弱动态效果」偏好：开着时按定格帧画，不建时钟（见 `frozenInstant`）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 画布的点→设备像素比：绘制层的坐标吸附要用它（见 `MascotPixelGrid`）。
    /// `Canvas` 的绘制闭包读不到环境值，所以只能在这一层交给绘制层。
    @Environment(\.displayScale) private var displayScale

    /// 动效速度档位：`@AppStorage` 而不是直接读 `AppSettings`——偏好改了要立刻重绘
    /// （UserDefaults 不是可观察对象），而且每个调用点都不必各自转发这个值。
    @AppStorage(AppSettings.mascotAnimationSpeedKey) private var animationSpeed: Double = 1

    var body: some View {
        let _ = (MascotPixelGrid.scale = displayScale)
        AgentMascotFrames(
            agent: agent, size: size, status: status,
            frozenTime: Self.frozenInstant(
                status: status, explicit: frozenTime, reduceMotion: reduceMotion, speed: speed),
            speed: speed)
    }

    /// 档位夹到 0 / 0.5 / 1 / 2（偏好域里可能是手改过的连续值）。
    private var speed: Double { AppSettings.clampedMascotAnimationSpeed(animationSpeed) }
}

// MARK: - 时钟 + 路由

private struct AgentMascotFrames: View {
    let agent: AgentKind
    let size: CGFloat
    let status: AgentMascotStatus
    let frozenTime: Double?
    /// 播放倍率（调用方已保证大于 0：0 档在 `AgentMascot` 里就定帧了）。
    let speed: Double

    var body: some View {
        if let frozenTime {
            frame(at: frozenTime, status: status)
        } else {
            TimelineView(
                .periodic(from: MascotMotion.epoch, by: status.frameInterval / speed)
            ) { context in
                frame(
                    at: context.date.timeIntervalSince(MascotMotion.epoch) * speed,
                    status: status)
            }
        }
    }

    private func frame(at time: Double, status: AgentMascotStatus) -> some View {
        character(status: status, t: CGFloat(time))
    }

    /// Agent → 角色。新增 Agent 时必须在这里补一支（穷举 switch，编译器会提醒）。
    @ViewBuilder
    private func character(status: AgentMascotStatus, t: CGFloat) -> some View {
        switch agent {
        case .claudeCode:
            ClaudeMascot(status: status, t: t, size: size)
        case .ohMyPi:
            // 与 Pi 共用同一份画法，但配色是 omp 的品牌紫（`Palette.ohMyPi`）。
            PiMascot(status: status, t: t, size: size, palette: .ohMyPi)
        case .pi:
            PiMascot(status: status, t: t, size: size)
        case .opencode:
            OpenCodeMascot(status: status, t: t, size: size)
        case .codex:
            CodexMascot(status: status, t: t, size: size)
        case .gemini:
            GeminiMascot(status: status, t: t, size: size)
        case .cursor:
            CursorMascot(status: status, t: t, size: size)
        case .copilot:
            CopilotMascot(status: status, t: t, size: size)
        case .qoder:
            QoderMascot(status: status, t: t, size: size)
        case .factory:
            FactoryMascot(status: status, t: t, size: size)
        case .codeBuddy:
            CodeBuddyMascot(status: status, t: t, size: size)
        case .workBuddy:
            // WorkBuddy 内嵌 CodeBuddy CLI，共用同一枚像素角色（与 Pi/omp 同一先例）。
            CodeBuddyMascot(status: status, t: t, size: size)
        case .kimi:
            KimiMascot(status: status, t: t, size: size)
        case .cline:
            ClineMascot(status: status, t: t, size: size)
        case .grok:
            GrokMascot(status: status, t: t, size: size)
        case .trae:
            TraeMascot(status: status, t: t, size: size)
        case .traeCli:
            TraeMascot(status: status, t: t, size: size)
        case .deepSeekHarness:
            DeepSeekHarnessMascot(status: status, t: t, size: size)
        case .hermes:
            HermesMascot(status: status, t: t, size: size)
        }
    }
}

// MARK: - 起跳截顶入参（单测读）

extension AgentMascot {
    /// 不建时钟时要画的那一帧；`nil` 表示照常走时钟（三种情形的清单见本文件头部）。
    ///
    /// 口径集中在这一处（视图与单测读同一个函数）：
    ///  · **显式给的定帧优先**——画廊、探针与单测要的就是那一帧，不该被用户的偏好改写；
    ///  · 否则「减弱动态」或 0 档都取该场景的**代表帧**（`stillInstant`）：静止档看到的是
    ///    「有人在里头」那一帧，不是空白，也不是随机的一帧；时间点固定，不随墙上时钟走。
    ///
    /// - Parameters:
    ///   - status: 该角色当前的活动状态。
    ///   - explicit: 调用方显式给的定帧时刻（`AgentMascot.frozenTime`）。
    ///   - reduceMotion: 系统的「减弱动态效果」偏好。
    ///   - speed: 已夹到 0 / 0.5 / 1 / 2 的播放倍率。
    static func frozenInstant(
        status: AgentMascotStatus, explicit: Double?, reduceMotion: Bool, speed: Double
    ) -> Double? {
        if let explicit { return explicit }
        return (reduceMotion || speed == 0) ? status.stillInstant : nil
    }

    /// 该 Agent 的起跳截顶入参：`AgentMascotRenderTests` 用它断言「顶点不会把身体抛出视口」。
    ///
    /// 与 `AgentMascotFrames.character(...)` 同构，**新增 Agent 时两处一起补**（都是穷举 switch，
    /// 编译器会提醒）。
    static func alertSpec(for agent: AgentKind) -> MascotAlertSpec {
        switch agent {
        case .claudeCode: return ClaudeMascot.alertSpec
        case .ohMyPi, .pi: return PiMascot.alertSpec
        case .opencode: return OpenCodeMascot.alertSpec
        case .codex: return CodexMascot.alertSpec
        case .gemini: return GeminiMascot.alertSpec
        case .cursor: return CursorMascot.alertSpec
        case .copilot: return CopilotMascot.alertSpec
        case .qoder: return QoderMascot.alertSpec
        case .factory: return FactoryMascot.alertSpec
        case .codeBuddy, .workBuddy: return CodeBuddyMascot.alertSpec
        case .kimi: return KimiMascot.alertSpec
        case .cline: return ClineMascot.alertSpec
        case .grok: return GrokMascot.alertSpec
        case .trae, .traeCli: return TraeMascot.alertSpec
        case .deepSeekHarness: return DeepSeekHarnessMascot.alertSpec
        case .hermes: return HermesMascot.alertSpec
        }
    }
}
