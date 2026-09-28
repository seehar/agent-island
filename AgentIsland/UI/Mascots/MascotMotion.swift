//
//  MascotMotion.swift
//  AgentIsland
//
//  像素角色的动效语汇。所有运动都是「时间 t 的纯函数」，不留任何动画状态：同一时刻渲染出
//  的画面永远一致（可以离屏定帧逐帧比对），同屏的多枚角色也天然同相，不会各走各的。
//
//  这里是**词汇表**，不含任何角色专属逻辑：角色自己的招牌动作写在
//  `AgentIsland/UI/Mascots/<角色>.swift` 里，只能通过这里（以及 `MascotKit`）取运动。
//
//  预算：空闲 8fps、忙碌 20fps（见 `AgentMascotStatus.frameInterval`），每条曲线只有几次
//  乘加，角色是画布上的几十个矩形拼合，单帧成本与改造前的字形动效同一量级。
//
//  「随机」全部走确定性哈希（`hash01` / `stableSeed`）：每枚角色的眨眼与小动作相位跨进程、
//  跨机器都一致，离屏定帧探针对得上；各角色的节拍也因此错开，不会同屏跳成一排。
//

import CoreGraphics
import Foundation

enum MascotMotion {
    /// 所有角色共用的相位原点（与 `AgentSpinner` 同一个 epoch），保证同屏元素同步。
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - 确定性伪随机

    /// 稳定哈希：把整数槽位映射到 [0, 1)。用来让眨眼间隔、小动作选型这类「随机」
    /// 在没有状态的前提下也可复现。
    static func hash01(_ n: Int, seed: UInt64 = 0) -> CGFloat {
        var x =
            UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15 &+ seed &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        return CGFloat(x % 1_000_000) / 1_000_000
    }

    /// 字符串的稳定种子（FNV-1a）：同一枚角色的节拍跨进程一致，离屏定帧探针才能对得上。
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
    static func breathe(_ t: CGFloat, period: CGFloat = 4.2) -> CGFloat {
        let p = (t.truncatingRemainder(dividingBy: period)) / period
        switch p {
        case ..<0.32: return easeInOut(p / 0.32)
        case ..<0.42: return 1
        case ..<0.94: return 1 - easeInOut((p - 0.42) / 0.52)
        default: return 0
        }
    }

    /// 节拍序号：每 `beat` 秒进一拍。走步、踏步、打字这类「离散拍子」都用它当相位，
    /// 而不是各自计数——同一时刻取到的拍号永远一样，定帧可复现。
    static func beat(_ t: CGFloat, beat: CGFloat = 0.15) -> Int {
        Int((t / beat).rounded(.down))
    }

    /// 心跳脉冲：短促地跳到 1 再慢慢落回 0。
    static func pulse(_ t: CGFloat, period: CGFloat = 0.9) -> CGFloat {
        let p = (t.truncatingRemainder(dividingBy: period)) / period
        switch p {
        case ..<0.12: return easeOutBack(p / 0.12)
        case ..<0.55: return 1 - easeInOut((p - 0.12) / 0.43)
        default: return 0
        }
    }

    /// 自然的眨眼：1 = 睁满，0 = 闭合。间隔不规则（2.4–5.6s），约六分之一是连眨两下
    /// ——这是小尺寸角色上最像「活着」的信号。
    static func blink(_ t: CGFloat, seed: UInt64 = 0) -> CGFloat {
        let slotLength: CGFloat = 4.0
        let slot = Int((t / slotLength).rounded(.down))
        let start = slotLength * (0.15 + 0.6 * hash01(slot, seed: seed))
        let local = t - CGFloat(slot) * slotLength

        let duration: CGFloat = 0.14
        func lid(_ dt: CGFloat) -> CGFloat {
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
        _ t: CGFloat, cycle: CGFloat = 7.0, duration: CGFloat = 0.8, seed: UInt64 = 0
    ) -> CGFloat {
        let slot = Int((t / cycle).rounded(.down))
        guard hash01(slot, seed: seed ^ 0x9D2C) > 0.30 else { return 0 }
        let start = cycle * (0.2 + 0.55 * hash01(slot, seed: seed))
        let local = t - CGFloat(slot) * cycle - start
        guard local >= 0, local < duration else { return 0 }
        return sin(local / duration * .pi)
    }

    /// 当前周期的小动作选型（0..<count），让同一枚角色在「歪头 / 抖耳朵 / 换脚站」之间轮换。
    static func quirkVariant(
        _ t: CGFloat, cycle: CGFloat = 7.0, count: Int, seed: UInt64 = 0
    ) -> Int {
        guard count > 0 else { return 0 }
        let slot = Int((t / cycle).rounded(.down))
        return Int(hash01(slot, seed: seed ^ 0x51DE) * CGFloat(count)) % count
    }

    /// 打字节拍：底拍之外带确定性的微小抖动（同一个槽位永远抖同样多），
    /// 手因此不会像节拍器那样敲。`active` 为假时是两次按键之间的停顿。
    static func typingBeat(
        _ t: CGFloat, cadence: CGFloat = 0.16, seed: UInt64 = 0
    ) -> (active: Bool, slot: Int) {
        let slot = Int((t / cadence).rounded(.down))
        let jitter = hash01(slot, seed: seed) * 0.35
        let local = (t / cadence).truncatingRemainder(dividingBy: 1)
        return (local > jitter * 0.5, slot)
    }

    /// 关键帧插值：`keyframes` 的横坐标是 0…1 的进度、纵坐标是值（不做单位换算），
    /// 超出两端时钳在首尾。角色的「一整套动作」用它描述比手写 if 更好读、也好改。
    static func lerp(_ keyframes: [(at: CGFloat, value: CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first, let last = keyframes.last else { return 0 }
        if pct <= first.at { return first.value }
        for index in 1..<keyframes.count {
            let next = keyframes[index]
            if pct <= next.at {
                let previous = keyframes[index - 1]
                let span = next.at - previous.at
                guard span > 0 else { return next.value }
                let p = (pct - previous.at) / span
                return previous.value + (next.value - previous.value) * p
            }
        }
        return last.value
    }

    // MARK: - 缓动

    /// 两端平滑的标准缓动。
    static func easeInOut(_ p: CGFloat) -> CGFloat {
        let c = min(max(p, 0), 1)
        return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
    }

    /// 带回弹的缓出：起跳 / 落地用，比线性更有力气。
    static func easeOutBack(_ p: CGFloat, overshoot: CGFloat = 1.70158) -> CGFloat {
        let c = min(max(p, 0), 1) - 1
        return 1 + (overshoot + 1) * c * c * c + overshoot * c * c
    }

    // MARK: - 待审批的起跳幅度

    /// 起跳关键帧的**截顶系数**：把上游那套「一跳比一跳矮」的位移等比缩到身体不会飞出视口。
    ///
    /// 上游的顶点（Clawd 是 -10 个 SVG 单位）比它自己的视口还高——实拍顶点那一帧只剩腿、
    /// 叹号和影子，身体整块被 `clipped()` 裁掉，看着像散了架。这里按「身体顶边到视口上边缘
    /// 的距离 + 一点越顶余量」定上限，再按最大跳幅等比缩放整条曲线（等比而不是逐个钳位：
    /// 逐个钳位会把三跳压成一样高，「一跳比一跳矮」就没了）。
    ///
    /// - Parameters:
    ///   - maxRise: 该角色关键帧表里最大的跳幅（正值，例如 10）
    ///   - bodyTop: 身体顶边的 SVG 纵坐标（静息时）
    ///   - svgTop: 该场景视口的上边缘 SVG 纵坐标
    ///   - overshoot: 允许越过视口上边缘多少（单位与上面两个相同；0.6 约是块顶被削掉一丝）
    static func alertRiseFactor(
        maxRise: CGFloat, bodyTop: CGFloat, svgTop: CGFloat, overshoot: CGFloat = 0.6
    ) -> CGFloat {
        guard maxRise > 0 else { return 1 }
        let limit = max(0.8, bodyTop - svgTop + overshoot)
        return min(1, limit / maxRise)
    }
}

/// 一枚角色的起跳截顶入参：`drawAlert` 用它算 `rise`，单测用它断言「顶点不会把身体抛出视口」
/// ——两处同一个来源，改一处就同时被钉住（`AgentMascot.alertSpec(for:)`）。
struct MascotAlertSpec: Equatable {
    /// 该角色关键帧表里最大的跳幅（正值，例如 10）。
    let maxRise: CGFloat
    /// 静息时身体主体顶边的 SVG 纵坐标。
    let bodyTop: CGFloat
    /// 起跳场景视口的上边缘 SVG 纵坐标。
    let svgTop: CGFloat
    /// 允许越过视口上边缘多少（0 = 顶点时身体顶边正好贴上边缘；视口没有纵向余量时必须取 0）。
    let overshoot: CGFloat

    init(maxRise: CGFloat, bodyTop: CGFloat, svgTop: CGFloat, overshoot: CGFloat = 0.6) {
        self.maxRise = maxRise
        self.bodyTop = bodyTop
        self.svgTop = svgTop
        self.overshoot = overshoot
    }

    /// 截顶系数：`drawAlert` 里就是 `let rise = jumpY * spec.riseFactor`。
    var riseFactor: CGFloat {
        MascotMotion.alertRiseFactor(
            maxRise: maxRise, bodyTop: bodyTop, svgTop: svgTop, overshoot: overshoot)
    }

    /// 顶点那一刻身体顶边的 SVG 纵坐标：**小于 `svgTop` 就是已经飞出视口被裁掉了**。
    var apexBodyTop: CGFloat { bodyTop - maxRise * riseFactor }
}
