//
//  MascotMotionTests.swift
//  AgentIslandTests
//
//  像素角色的动效语汇是「时间的纯函数」——同一时刻永远算出同一个值，且各通道都落在
//  画得出来的范围里（NaN 或过大的位移会让角色飞出刘海）。这里把这两条钉住，
//  也钉住几处「像活物」的判据（眨眼多数时间睁着、小动作不机械、跳跃只向上）。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("角色动效语汇")
struct MascotMotionTests {
    /// 采样时刻：按 0.05s 步长覆盖呼吸、眨眼、小动作、打字节拍的多个周期。
    private static let samples: [CGFloat] = stride(from: 0.0, through: 60.0, by: 0.05).map {
        CGFloat($0)
    }

    @Test("呼吸：起点是呼到底、过程中吸满过，且值域不出 0…1")
    func breatheIsARealBreath() {
        let values = Self.samples.map { MascotMotion.breathe($0) }
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(values.contains { $0 > 0.95 }, "呼吸从没吸满过，读起来会像节拍器")
        #expect(values.contains { $0 < 0.05 }, "呼吸从没呼到底")
    }

    @Test("眨眼：多数时间睁着，但确实闭上过")
    func blinkIsMostlyOpenWithRealBlinks() {
        for agent in AgentKind.allCases {
            let seed = MascotMotion.stableSeed(agent.rawValue)
            let values = Self.samples.map { MascotMotion.blink($0, seed: seed) }
            #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
            let openShare = values.filter { $0 > 0.9 }.count
            #expect(
                Double(openShare) / Double(values.count) > 0.8,
                "\(agent.rawValue) 的眨眼占用了太多时间")
            #expect(
                values.contains { $0 < 0.2 },
                "\(agent.rawValue) 在 60 秒里一次都没闭上眼")
        }
    }

    @Test("小动作：不机械（有跳过的周期），也不会每周期都来")
    func quirksAreIrregular() {
        let cycle: CGFloat = 7
        let cycles = 100
        var fired = 0
        for index in 0..<cycles {
            let start = CGFloat(index) * cycle
            let window = stride(from: start, to: start + cycle, by: 0.05).map { CGFloat($0) }
            if window.contains(where: { MascotMotion.quirk($0, cycle: cycle, seed: 42) > 0 }) {
                fired += 1
            }
        }
        #expect(fired > cycles / 2, "小动作太罕见，看起来像死物")
        #expect(fired < cycles, "每个周期都来一次，节奏会读成定时器")
    }

    @Test("打字节拍：同一槽位的抖动稳定，节拍按时间推进")
    func typingBeatIsStableAndAdvances() {
        let first = MascotMotion.typingBeat(0.19, seed: 7)
        let again = MascotMotion.typingBeat(0.19, seed: 7)
        #expect(first.slot == again.slot && first.active == again.active)
        let later = MascotMotion.typingBeat(1.03, seed: 7)
        #expect(later.slot > first.slot, "打字节拍没有随时间推进")
    }

    @Test("关键帧插值：两端钳位、中间单调")
    func lerpClampsAndInterpolates() {
        let frames: [(at: CGFloat, value: CGFloat)] = [(0, 0), (0.5, 4), (1, 1)]
        #expect(MascotMotion.lerp(frames, at: -1) == 0)
        #expect(MascotMotion.lerp(frames, at: 0) == 0)
        #expect(MascotMotion.lerp(frames, at: 0.5) == 4)
        #expect(MascotMotion.lerp(frames, at: 1) == 1)
        #expect(MascotMotion.lerp(frames, at: 9) == 1)
        #expect(MascotMotion.lerp(frames, at: 0.25) == 2)
    }

    @Test("起跳截顶：按视口高度等比缩放，三跳「一跳比一跳矮」的比例不变")
    func alertRiseFactorCapsTheJump() {
        // 不越顶的幅度：系数 1，关键帧逐值保留。
        #expect(MascotMotion.alertRiseFactor(maxRise: 3, bodyTop: 6, svgTop: 3) == 1)
        // 越顶的幅度：截顶后身体顶边正好越过视口上边缘「余量」那么多（余量是允许的越顶）。
        let factor = MascotMotion.alertRiseFactor(maxRise: 10, bodyTop: 6, svgTop: 4)
        #expect(factor > 0 && factor < 1)
        #expect(abs((6 + (-10 * factor)) - (4 - 0.6)) < 0.0001, "截顶后身体没落在视口上边缘的余量处")
        // 等比缩放：一跳比一跳矮的顺序与比例都保留（逐个钳位会把三跳压成一样高）。
        let hops: [CGFloat] = [-10, -8, -5]
        let scaled = hops.map { $0 * factor }
        #expect(scaled[0] < scaled[1] && scaled[1] < scaled[2])
        #expect(abs(scaled[1] / scaled[0] - 0.8) < 0.0001)
        // 视口太扁时下限兜底，且幅度非正时不炸。
        #expect(MascotMotion.alertRiseFactor(maxRise: 10, bodyTop: 3, svgTop: 3) > 0)
        #expect(MascotMotion.alertRiseFactor(maxRise: 0, bodyTop: 6, svgTop: 3) == 1)
    }

    @Test("确定性哈希与种子跨调用稳定")
    func hashAndSeedAreStable() {
        #expect(MascotMotion.stableSeed("claude") == MascotMotion.stableSeed("claude"))
        #expect(MascotMotion.stableSeed("claude") != MascotMotion.stableSeed("codex"))
        #expect(MascotMotion.hash01(3, seed: 7) == MascotMotion.hash01(3, seed: 7))
        for index in 0..<200 {
            let value = MascotMotion.hash01(index)
            #expect(value >= 0 && value < 1)
        }
    }

    @Test("帧预算：空闲 8fps、忙碌 20fps；静止档取各场景的代表时刻")
    func statusBudgets() {
        #expect(AgentMascotStatus.idle.frameInterval == 0.125)
        #expect(AgentMascotStatus.working.frameInterval == 0.05)
        #expect(AgentMascotStatus.alert.frameInterval == 0.05)
        // 静止档不能三个场景都取 0：空闲与处理中的差别在动作序列里，不是某一帧。
        #expect(AgentMascotStatus.idle.stillInstant != AgentMascotStatus.working.stillInstant)
        for status in [AgentMascotStatus.idle, .working, .alert] {
            #expect(status.stillInstant >= 0)
        }
    }

    @Test("静止档的代表时刻必须让每个角色都睁着眼")
    func stillInstantsKeepEveryAgentAwake() {
        // 眨眼相位由 seed 决定，18 枚各不相同：代表时刻一旦落进某一枚的眨眼窗口，它在
        // 「静止」档就会以闭着眼的样子出现（实测 t=1.5 正中 gemini 的眨眼窗口）。
        // 各 seed 的首次眨眼都从 t ≥ 0.6 才开始，所以代表时刻必须落在它之前。
        for status in [AgentMascotStatus.idle, .working, .alert] {
            for agent in AgentKind.allCases {
                let seed = MascotMotion.stableSeed(agent.rawValue)
                #expect(
                    MascotMotion.blink(status.stillInstant, seed: seed) == 1,
                    "\(agent.rawValue) 的 \(status) 代表时刻 \(status.stillInstant)s 落在眨眼窗口里")
            }
        }
    }

    @Test("会话阶段到活动状态的映射")
    func statusMapsFromPhase() {
        #expect(AgentMascotStatus(.processing) == .working)
        #expect(AgentMascotStatus(.compacting) == .working)
        #expect(AgentMascotStatus(.idle) == .idle)
        #expect(AgentMascotStatus(.waitingForInput) == .idle)
    }
}
