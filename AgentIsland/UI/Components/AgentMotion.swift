//
//  AgentMotion.swift
//  AgentIsland
//
//  刘海标记的动效语汇。做法参考 CodeIsland 的像素角色动画：所有运动都是「时间 t 的
//  纯函数」，不留任何动画状态——同一时刻渲染出的画面永远一致（可以离屏定帧逐帧比对），
//  同屏的多枚标记也天然同相，不会各走各的。
//
//  预算与 CodeIsland 一致：空闲 8fps、忙碌 20fps，每条曲线只有几次乘加，14pt 的标记
//  足够便宜。标记本身是各家的品牌字形（不是吉祥物），所以动作只用「呼吸 / 走 / 跳 /
//  脉冲」这套与形状无关的语汇，各 Agent 挑一种作为自己的招牌动作。
//

import SwiftUI

/// 标记当前的活动状态，决定用哪套动作。
enum AgentLogoActivity: Equatable {
    /// 没在跑：轻微呼吸，像活物在喘气
    case idle
    /// 处理中：走动 / 跳动
    case working
    /// 等待审批：一串逐渐衰减的弹跳，提示用户过来看
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

/// 一帧里标记的运动结果。整体位移由调用方施加（SwiftUI 位移不会裁切，也就不必给
/// 画布留余量），各「角色块」的局部变化由画布自己吃下去。
struct AgentLogoMotion {
    /// 整体竖直位移，负值向上
    var dy: CGFloat = 0
    /// π 两条腿抬起的高度（左、右），正值 = 抬脚
    var legLift: (CGFloat, CGFloat) = (0, 0)
    /// 内孔的不透明度倍率（OpenCode 的「眼睛」）
    var innerOpacity: Double = 1
    /// Claude 螃蟹的走路相位；nil 表示腿脚不动
    var walkPhase: Int?
}

enum AgentMotion {
    /// 所有标记共用的相位原点（与 AgentSpinner 同一个 epoch），保证同屏元素同步。
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

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

    // MARK: - 各 Agent 的招牌动作

    /// 该 Agent 在这一时刻该摆成什么样。
    static func motion(
        for agent: AgentKind, activity: AgentLogoActivity, at t: Double, size: CGFloat
    ) -> AgentLogoMotion {
        var motion = AgentLogoMotion()
        // 位移量随尺寸缩放：14pt 的刘海与 44pt 的放大预览用同一套参数
        let unit = max(0.6, size * 0.1)

        switch activity {
        case .idle:
            // 幅度按尺寸缩放，14pt 下约 1px：看得出在呼吸，又不至于晃
            motion.dy = -unit * 0.7 * breathe(t)
        case .alert:
            motion.dy = -unit * 1.3 * alertBounce(t)
        case .working:
            switch agent {
            case .claudeCode:
                // 螃蟹：四相走步 + 随步子轻颠
                motion.walkPhase = stepPhase(t) % 4
                motion.dy = -unit * 0.8 * hop(t, beat: 0.6)
            case .ohMyPi:
                // π：两条腿交替抬脚，像是站在地上原地踏步
                let lift = unit * 0.8
                let isLeftUp = stepPhase(t, beat: 0.3) % 2 == 0
                motion.legLift = isLeftUp ? (lift, 0) : (0, lift)
            case .pi:
                // 像素 P：整枚标记原地弹跳
                motion.dy = -unit * 1.4 * hop(t, beat: 0.55)
            case .opencode:
                // 方框：内孔明暗脉冲，像机器在闪眼
                motion.innerOpacity = 0.35 + 0.65 * pulse(t)
            default:
                // 其余 Agent 的标记是一整枚品牌字形（没有可独立运动的部件），
                // 因此统一用「整枚原地弹跳」——运动只落在位移上，与形状无关。
                motion.dy = -unit * 1.4 * hop(t, beat: 0.55)
            }
        }
        return motion
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
