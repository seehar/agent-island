//
//  AgentMascot.swift
//  AgentIsland
//
//  18 个 Agent 的运行时**像素角色**：刘海头部与「标记动态」页都从这里取。
//
//  分工（改这一层之前先读这一段）：
//    · 本文件：活动状态、时钟、待审批的统一动作层、Agent → 角色的路由。
//    · `MascotMotion` / `MascotKit`：曲线与绘制工具（不含任何角色专属逻辑）。
//    · `Mascots/<角色>.swift`：一枚角色的画法与三套场景。
//
//  三套场景的语义（每枚角色都必须做到）：
//    · `idle`：像活物——呼吸 + 眨眼，偶发一次小动作（歪头 / 抖耳朵 / 换只脚站）；
//    · `working`：按该角色自己的形态做**招牌动作**（腿走、齿轮转、等化器跳、点绕行…），
//      一眼看得出它在干活，而不是「所有角色一起上下弹」；
//    · `alert`：换成「注意到你了」的姿态（瞪眼 / 举钳 / 张大）。**动作**由本文件的统一层
//      施加：三连跳 + 品牌色光晕。统一层刻意不按角色分化——它是应用级信号（有事等你），
//      18 枚各不相同会把这个信号削弱。角色这一档的姿态可以是静止的，也**可以仍在动**
//      （如 Factory 的辐条转得更快）；但整体位移与缩放一律留给统一层：角色自己的位移
//      只能来自它这一档的形态（如把「兜帽拉高」画成兜帽更高，而不是整只角色上移）。
//
//  姿态约定：`t == 0` 必须是该场景最有代表性的一帧（不眨眼、不压扁、不位移）——
//  离屏定帧探针与单测都取这一帧，因此这不是审美问题而是契约。「静止」档位另取
//  各场景的代表时刻（见 `AgentMascotStatus.stillInstant`）。
//

import SwiftUI

/// 角色当前的活动状态，由会话阶段推导。
enum AgentMascotStatus: Hashable {
    /// 没在跑：呼吸 + 眨眼，像活物在喘气。
    case idle
    /// 处理中：该角色自己的招牌动作。
    case working
    /// 等待审批：停下来盯着你（配合统一的弹跳与光晕）。
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
    ///    各 seed 的首次眨眼都从 t ≥ 0.6 才开始，因此取 ≤ 0.3 的时刻对所有角色都睁着眼。
    ///  · **有代表性**：空闲取静息帧（呼吸到底、四平八稳），处理中取动作中段（走步已经迈出去，
    ///    多数角色的招牌动作在这一刻都已离开静息位，静止档因此看得出与空闲的差别），
    ///    待审批取姿态帧。空闲与处理中的差别主要落在**动作序列**上，静止档看得到的那部分
    ///    来自各角色自己那条「状态驱动的常驻姿势差」（见各自的 `draw*`）。
    ///
    /// 待审批档是例外：多数角色在那里的姿态是静止的，但**允许**仍在动（`FactoryMascot`
    /// 的辐条在待审批时转得更快），此时定帧取的是该场景的代表姿态。
    /// 这条口径由 `MascotMotionTests`（`blink(stillInstant, seed) == 1`）与
    /// `AgentMascotRenderTests`（三档在代表时刻的姿态指纹互不相同）一起钉住。
    var stillInstant: Double {
        switch self {
        case .idle: return 0
        case .working: return 0.45
        case .alert: return 0
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

    var body: some View {
        AgentMascotFrames(agent: agent, size: size, status: status, frozenTime: frozenTime)
    }
}

// MARK: - 时钟 + 统一层 + 路由

private struct AgentMascotFrames: View {
    let agent: AgentKind
    let size: CGFloat
    let status: AgentMascotStatus
    let frozenTime: Double?

    var body: some View {
        if let frozenTime {
            frame(at: frozenTime, status: status)
        } else {
            TimelineView(.periodic(from: MascotMotion.epoch, by: status.frameInterval)) {
                context in
                frame(at: context.date.timeIntervalSince(MascotMotion.epoch), status: status)
            }
        }
    }

    private func frame(at time: Double, status: AgentMascotStatus) -> some View {
        let t = CGFloat(time)
        let attention = status == .alert ? MascotMotion.attention(t, size: size) : .init()
        return character(status: status, t: t)
            .background(glow(intensity: attention.glow))
            .scaleEffect(x: attention.scaleX, y: attention.scaleY, anchor: .bottom)
            .offset(y: attention.dy)
    }

    /// Agent → 角色。新增 Agent 时必须在这里补一支（穷举 switch，编译器会提醒）。
    @ViewBuilder
    private func character(status: AgentMascotStatus, t: CGFloat) -> some View {
        switch agent {
        case .claudeCode:
            ClaudeMascot(status: status, t: t, size: size)
        case .ohMyPi:
            OhMyPiMascot(status: status, t: t, size: size)
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

    /// 待审批的品牌色光晕：画在角色后面，**常亮一点余晖**（0.25）并与三连跳同拍增强。
    /// 用径向渐变而不是 `blur`——20fps 下模糊的离屏渲染太贵。
    @ViewBuilder
    private func glow(intensity: CGFloat) -> some View {
        if intensity > 0.01 {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            agent.brandColor.opacity(0.45 * intensity),
                            agent.brandColor.opacity(0),
                        ],
                        center: .center,
                        startRadius: size * 0.15,
                        endRadius: size * 0.85
                    )
                )
                .frame(width: size * 1.7, height: size * 1.7)
        }
    }
}
