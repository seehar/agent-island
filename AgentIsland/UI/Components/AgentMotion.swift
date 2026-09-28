//
//  AgentMotion.swift
//  AgentIsland
//
//  刘海标记的动效语汇。做法参考 CodeIsland 的像素角色动画：所有运动都是「时间 t 的
//  纯函数」，不留任何动画状态——同一时刻渲染出的画面永远一致（可以离屏定帧逐帧比对），
//  同屏的多枚标记也天然同相，不会各走各的。
//
//  预算与 CodeIsland 一致：空闲 8fps、忙碌 20fps，每条曲线只有几次乘加，14pt 的标记
//  足够便宜。标记本身是各家的品牌字形（不是吉祥物），所以动作按三层叠：
//    · 通用层（所有标记都有）：呼吸、眨眼、偶发的小动作（歪头 / 轻抬 / 抖触须）
//    · 招牌层（处理中）：按字形的几何形态选动作——螃蟹的腿与触须、π 的两条腿、OpenCode
//      的内孔、像素 P 的压扁弹跳这类动部件；圆环自转、星形闪烁、块状摇摆这类动整枚
//    · 提示层（待审批）：三连跳 + 品牌色光晕脉冲，把「过来看看」做得比大小写更响
//
//  每枚标记的眨眼与小动作相位由 `stableSeed(rawValue)` 定，因此跨进程、跨机器都一致，
//  离屏定帧探针对得上；各 Agent 的招牌动作节拍也因此错开，不会同屏跳成一排。
//

import SwiftUI

/// 标记当前的活动状态，决定用哪套动作。
enum AgentLogoActivity: Hashable {
    /// 没在跑：轻微呼吸，像活物在喘气
    case idle
    /// 处理中：走动 / 跳动 / 闪烁
    case working
    /// 等待审批：一串逐渐衰减的弹跳 + 光晕，提示用户过来看
    case alert

    /// 由会话阶段推导。映射只写在这一处，避免各处各写一遍。
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
}

/// 一帧里标记的运动结果。整体位移与缩放由调用方施加（SwiftUI 的位移、缩放与旋转不会
/// 裁切，也就不必给画布留余量），各「角色块」的局部变化由画布自己吃下去。
struct AgentLogoMotion {
    /// 整体竖直位移，负值向上
    var dy: CGFloat = 0
    /// π 两条腿抬起的高度（左、右），正值 = 抬脚
    var legLift: (CGFloat, CGFloat) = (0, 0)
    /// 内孔的不透明度倍率（OpenCode 的「眼睛」）
    var innerOpacity: Double = 1
    /// Claude 螃蟹的走路相位；nil 表示腿脚不动
    var walkPhase: Int?
    /// 横向缩放：>1 压扁、<1 拉长，与 `scaleY` 配出起跳/落地的挤压拉伸
    var scaleX: CGFloat = 1
    /// 纵向缩放
    var scaleY: CGFloat = 1
    /// 整体旋转（度）
    var rotation: Double = 0
    /// 睁眼程度：1 = 睁满、0 = 闭合（只有画得出眼睛的标记吃这个参数）
    var blink: Double = 1
    /// 注意力的光晕强度 0…1（待审批时用品牌色脉冲）
    var glow: Double = 0
    /// 触须 / 小件的局部上下摆（正值 = 左侧抬起、右侧落下）
    var sway: CGFloat = 0
}

enum AgentMotion {
    /// 所有标记共用的相位原点（与 AgentSpinner 同一个 epoch），保证同屏元素同步。
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - 确定性伪随机

    /// 稳定哈希：把整数槽位映射到 [0, 1)。用来让眨眼间隔、小动作选型这类「随机」
    /// 在没有状态的前提下也可复现。
    static func hash01(_ n: Int, seed: UInt64 = 0) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15 &+ seed &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        return Double(x % 1_000_000) / 1_000_000
    }

    /// 字符串的稳定种子（FNV-1a）。同一个 Agent 的眨眼与小动作相位跨进程一致，
    /// 离屏定帧探针才能对得上。
    static func stableSeed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - 曲线

    /// 呼吸：0 = 呼到底，1 = 吸满。吸气快、顶端停一下、呼气慢，底部再留一段静止，
    /// 这样才像活物而不是节拍器。
    static func breathe(_ t: Double, period: Double = 4.2) -> Double {
        let p = (t.truncatingRemainder(dividingBy: period)) / period
        switch p {
        case ..<0.32: return easeInOut(p / 0.32)
        case ..<0.42: return 1
        case ..<0.94: return 1 - easeInOut((p - 0.42) / 0.52)
        default: return 0
        }
    }

    /// 跳动：一个节拍里起跳再落回，其余时间停在地上。返回高度系数（0…约 1.1）。
    static func hop(_ t: Double, beat: Double = 0.55) -> Double {
        let p = (t.truncatingRemainder(dividingBy: beat)) / beat
        guard p < 0.4 else { return 0 }
        return easeOutBack(p / 0.4)
    }

    /// 落地压扁量 0…1：起跳段为 0，落地瞬间涨到 1 再落回。与 `hop` 同一个节拍相位。
    static func landingSquash(_ t: Double, beat: Double = 0.55) -> Double {
        let p = (t.truncatingRemainder(dividingBy: beat)) / beat
        guard p >= 0.30, p < 0.5 else { return 0 }
        return sin((p - 0.30) / 0.2 * .pi)
    }

    /// 走路的步伐相位，每 `beat` 换一步（与螃蟹原来的定时器同为 0.15s）。
    static func stepPhase(_ t: Double, beat: Double = 0.15) -> Int {
        Int((t / beat).rounded(.down))
    }

    /// 提示弹跳：一次三连跳，一跳比一跳矮，然后安静到周期结束。
    /// 返回高度系数（0…约 1.1）。
    static func alertBounce(_ t: Double, cycle: Double = 3.5) -> Double {
        let p = t.truncatingRemainder(dividingBy: cycle)
        let hops: [(start: Double, weight: Double)] = [(0, 1.0), (0.45, 0.6), (0.85, 0.3)]
        for hop in hops {
            let local = (p - hop.start) / 0.35
            if local >= 0 && local < 1 {
                return hop.weight * easeOutBack(local)
            }
        }
        return 0
    }

    /// 心跳脉冲：短促地跳到 1 再慢慢落回 0（OpenCode 内孔明暗用）。
    static func pulse(_ t: Double, period: Double = 0.9) -> Double {
        let p = (t.truncatingRemainder(dividingBy: period)) / period
        switch p {
        case ..<0.12: return easeOutBack(p / 0.12)
        case ..<0.55: return 1 - easeInOut((p - 0.12) / 0.43)
        default: return 0
        }
    }

    /// 闪烁：短促地涨到 1 再落回 0，读起来像在发光（Gemini 的四角星用）。
    static func twinkle(_ t: Double, period: Double = 1.15) -> Double {
        let p = (t.truncatingRemainder(dividingBy: period)) / period
        switch p {
        case ..<0.18: return easeOutBack(p / 0.18)
        case ..<0.5: return 1 - easeInOut((p - 0.18) / 0.32)
        default: return 0
        }
    }

    /// 连续自转的角度（度）。整圈取模，因此与绝对时间一起可定帧（Qoder / Grok 用）。
    static func spin(_ t: Double, period: Double) -> Double {
        (t / period).truncatingRemainder(dividingBy: 1) * 360
    }

    // MARK: - 眨眼与小动作

    /// 自然的眨眼：1 = 睁满，0 = 闭合。间隔不规则（2.4–5.6s），约六分之一是连眨两下
    /// ——这是小尺寸标记上最像「活着」的信号。
    static func blink(_ t: Double, seed: UInt64 = 0) -> Double {
        let slotLength = 4.0
        let slot = Int((t / slotLength).rounded(.down))
        let start = slotLength * (0.15 + 0.6 * hash01(slot, seed: seed))
        let local = t - Double(slot) * slotLength

        let duration = 0.14
        func lid(_ dt: Double) -> Double {
            guard dt >= 0, dt < duration else { return 1 }
            let p = dt / duration
            // 闭得快、睁得慢一点
            return p < 0.4 ? 1 - (p / 0.4) : (p - 0.4) / 0.6
        }

        var openness = lid(local - start)
        if hash01(slot, seed: seed ^ 0xB11) < 0.18 {
            openness = min(openness, lid(local - start - 0.22))
        }
        return openness
    }

    /// 空闲小动作的包络：一个周期里至多一次，约 30% 的周期跳过——节奏因此不机械。
    /// 窗口内返回 0→1→0 的包络，其余时间返回 0。
    static func quirk(
        _ t: Double, cycle: Double = 7.0, duration: Double = 0.8, seed: UInt64 = 0
    ) -> Double {
        let slot = Int((t / cycle).rounded(.down))
        guard hash01(slot, seed: seed ^ 0x9D2C) > 0.30 else { return 0 }
        let start = cycle * (0.2 + 0.55 * hash01(slot, seed: seed))
        let local = t - Double(slot) * cycle - start
        guard local >= 0, local < duration else { return 0 }
        return sin(local / duration * .pi)
    }

    /// 当前周期的小动作选型（0..<count），让同一枚标记在「歪头 / 轻抬 / 抖须」之间轮换。
    static func quirkVariant(
        _ t: Double, cycle: Double = 7.0, count: Int, seed: UInt64 = 0
    ) -> Int {
        guard count > 0 else { return 0 }
        let slot = Int((t / cycle).rounded(.down))
        return Int(hash01(slot, seed: seed ^ 0x51DE) * Double(count)) % count
    }

    // MARK: - 各 Agent 的招牌动作

    /// 标记的几何形态：决定「处理中」能做什么动作。字形有没有可独立运动的部件、
    /// 轮廓是圆是方，动作的落点完全不同。
    private enum MarkForm {
        /// Claude 螃蟹：腿、触须、眼睛都能各自动
        case crab
        /// omp 的 π / pi 的像素 P：矩形组，腿能抬、整枚能压扁弹跳
        case pixelLegs
        /// OpenCode 的外框 + 内孔：内孔能脉冲
        case innerWell
        /// 圆滚的轮廓：适合自转（Qoder 的缺口环、Grok 的斜环）
        case round
        /// 四角星：适合闪烁（Gemini 的 sparkle）
        case star
        /// 方块 / 块状字形：整枚摇摆、浮动或脉动
        case frame
    }

    private static func form(_ agent: AgentKind) -> MarkForm {
        switch agent {
        case .claudeCode: return .crab
        case .ohMyPi, .pi: return .pixelLegs
        case .opencode: return .innerWell
        case .qoder, .grok: return .round
        case .gemini: return .star
        // 其余（codex / cursor / copilot / factory / codeBuddy / kimi / cline / trae /
        // traeCli / deepSeekHarness / hermes）都是整块的方块或块状字形。
        default: return .frame
        }
    }

    /// 该 Agent 在这一时刻该摆成什么样。
    static func motion(
        for agent: AgentKind, activity: AgentLogoActivity, at t: Double, size: CGFloat
    ) -> AgentLogoMotion {
        var motion = AgentLogoMotion()
        // 位移量随尺寸缩放：14pt 的刘海与 34pt 的预览用同一套参数
        let unit = max(0.6, size * 0.1)
        let seed = stableSeed(agent.rawValue)

        switch activity {
        case .idle:
            idleMotion(&motion, t: t, unit: unit, seed: seed)
        case .working:
            workingMotion(&motion, agent: agent, t: t, unit: unit, seed: seed)
        case .alert:
            alertMotion(&motion, t: t, unit: unit)
        }
        return motion
    }

    /// 通用层：呼吸 + 纵向拉伸 + 眨眼 + 偶发的小动作。
    private static func idleMotion(
        _ motion: inout AgentLogoMotion, t: Double, unit: CGFloat, seed: UInt64
    ) {
        let breath = breathe(t)
        motion.dy = -unit * 0.7 * breath
        // 呼吸也带一点纵向拉伸：像胸腔起伏，比纯位移更像活物
        motion.scaleY = 1 + 0.03 * breath
        motion.blink = blink(t, seed: seed)

        let twitch = quirk(t, cycle: 7.0, duration: 0.8, seed: seed)
        guard twitch > 0 else { return }
        switch quirkVariant(t, cycle: 7.0, count: 3, seed: seed) {
        case 0:
            let direction: Double = hash01(2, seed: seed) < 0.5 ? -1 : 1
            motion.rotation += twitch * 6 * direction
        case 1:
            motion.dy -= unit * 0.6 * twitch
        default:
            motion.sway = twitch * unit * 0.8
        }
    }

    /// 招牌层：按字形形态选动作。
    private static func workingMotion(
        _ motion: inout AgentLogoMotion, agent: AgentKind, t: Double, unit: CGFloat, seed: UInt64
    ) {
        switch form(agent) {
        case .crab:
            // 螃蟹：四相走步 + 随步子轻颠 + 触须反向摆 + 偶尔眨眼
            motion.walkPhase = stepPhase(t) % 4
            motion.dy = -unit * 0.8 * hop(t, beat: 0.6)
            motion.sway = unit * 0.6 * sin(t * 2 * .pi / 0.6)
            motion.blink = blink(t, seed: seed)
        case .pixelLegs:
            if agent == .ohMyPi {
                // π：两条腿交替抬脚，像站在地上原地踏步
                let lift = unit * 0.8
                let isLeftUp = stepPhase(t, beat: 0.3) % 2 == 0
                motion.legLift = isLeftUp ? (lift, 0) : (0, lift)
                motion.dy = -unit * 0.4 * hop(t, beat: 0.6)
            } else {
                // 像素 P：整枚起跳，起跳拉长、落地压扁
                motion.dy = -unit * 1.4 * hop(t, beat: 0.55)
                let squash = landingSquash(t, beat: 0.55)
                motion.scaleX = 1 + 0.10 * squash
                motion.scaleY = 1 - 0.12 * squash
            }
        case .innerWell:
            // OpenCode：内孔明暗脉冲 + 轻微起伏，像机器在闪眼
            let p = pulse(t)
            // `pulse` 的回弹会略微过冲，不透明度必须钳在 1 以内
            motion.innerOpacity = min(1, 0.35 + 0.65 * p)
            motion.scaleY = 1 + 0.04 * p
            motion.dy = -unit * 0.4 * p
        case .round:
            // Qoder 的缺口环 / Grok 的斜环：整圈自转（周期各不同，避免同相）
            motion.rotation = spin(t, period: agent == .grok ? 3.6 : 2.8)
            motion.dy = -unit * 0.5 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.8))
        case .star:
            // Gemini 的四角星：闪烁（短促涨大再落回）+ 轻微摇摆
            let twinkle = twinkle(t, period: 1.15)
            motion.scaleX = 0.92 + 0.18 * twinkle
            motion.scaleY = 0.92 + 0.18 * twinkle
            motion.rotation = 6 * sin(t * 2 * .pi / 2.6)
        case .frame:
            frameMotion(&motion, t: t, unit: unit, seed: seed)
        }
    }

    /// 块状字形的招牌动作。三种候选按 Agent 的稳定种子分配、节拍也各不同——
    /// 全屏都做同一个动作会读成「同一个动画播了 18 遍」。
    private static func frameMotion(
        _ motion: inout AgentLogoMotion, t: Double, unit: CGFloat, seed: UInt64
    ) {
        let variant = Int(hash01(0, seed: seed) * 3) % 3
        let period = 2.0 + 1.2 * hash01(1, seed: seed)
        let phase = t * 2 * .pi / period

        switch variant {
        case 0:
            // 左右摇摆：方块像在晃脑 / 点头
            motion.rotation = 8 * sin(phase)
            motion.dy = -unit * 0.3 * (0.5 + 0.5 * sin(phase * 2))
        case 1:
            // 上下浮动
            motion.dy = -unit * 1.1 * (0.5 + 0.5 * sin(phase))
        default:
            // 脉动：横向涨、纵向缩，像在用力
            let k = 0.5 + 0.5 * sin(phase)
            motion.scaleX = 1 + 0.06 * k
            motion.scaleY = 1 - 0.05 * k
        }
    }

    /// 提示层：三连跳 + 挤压拉伸 + 品牌色光晕。
    private static func alertMotion(_ motion: inout AgentLogoMotion, t: Double, unit: CGFloat) {
        let bounce = alertBounce(t)
        motion.dy = -unit * 1.3 * bounce
        // 起跳拉长、落地压扁：比纯位移更有重量
        motion.scaleX = 1 - 0.06 * bounce
        motion.scaleY = 1 + 0.10 * bounce
        // 光晕与跳跃同拍：跳到哪儿亮到哪儿，安静时留一点余晖
        // 跳跃的回弹会略微过冲，强度必须钳在 1 以内
        motion.glow = min(1, 0.25 + 0.75 * bounce)
    }

    // MARK: - 缓动

    /// 两端平滑的标准缓动
    static func easeInOut(_ p: Double) -> Double {
        let c = min(max(p, 0), 1)
        return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
    }

    /// 带回弹的缓出：起跳/落地用，比线性更有力气
    static func easeOutBack(_ p: Double, overshoot: Double = 1.70158) -> Double {
        let c = min(max(p, 0), 1) - 1
        return 1 + (overshoot + 1) * c * c * c + overshoot * c * c
    }
}

// MARK: - 定帧（离屏渲染探针用）

private struct AgentLogoStaticTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// 覆盖标记的动画时间，用于离屏逐帧核对动效；App 运行时始终是 nil。
    var agentLogoStaticTime: Double? {
        get { self[AgentLogoStaticTimeKey.self] }
        set { self[AgentLogoStaticTimeKey.self] = newValue }
    }
}