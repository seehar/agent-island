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

    @Test("周期曲线在循环边界上值连续、斜率也连续（C1）")
    func periodicCurvesMeetSmoothlyAtTheLoopPoint() {
        // 判据用**单侧差分**：各条周期曲线在边界附近都是平的（平的 0 或平的 1），因此两侧
        // 斜率都该是 0。`pulse` 曾在上升段用带回弹的缓出——值连续、斜率从 0 跳到 ≈39/周期，
        // 一个周期一次肉眼可辨的顿挫；这条用例就是钉住它的（改回去会当场红）。
        //
        // 这条判据只管**循环边界**（一期回到下一期的那一点）。窗口自身的起止处（眨眼开始
        // 闭眼、小动作与睡眠 Z 的淡入）斜率是故意陡的——那是一个「起手」，不是循环接缝，
        // 不在这里断言。
        let curves: [(name: String, value: (CGFloat) -> CGFloat, period: CGFloat)] = [
            ("breathe(4.2)", { MascotMotion.breathe($0, period: 4.2) }, 4.2),
            ("breathe(4.5)", { MascotMotion.breathe($0, period: 4.5) }, 4.5),
            ("blink", { MascotMotion.blink($0, seed: 7) }, 4.0),
            ("quirk", { MascotMotion.quirk($0, cycle: 6.0, seed: 42) }, 6.0),
            ("pulse", { MascotMotion.pulse($0, period: 0.9) }, 0.9),
        ]
        let step: CGFloat = 0.00001
        for curve in curves {
            #expect(
                curve.value(0) == curve.value(curve.period),
                "\(curve.name) 在循环边界上值不连续")
            let left = (curve.value(curve.period) - curve.value(curve.period - step)) / step
            let right = (curve.value(step) - curve.value(0)) / step
            #expect(abs(left) < 0.01, "\(curve.name) 在循环边界左侧斜率 \(left)（不是平的）")
            #expect(
                abs(right) < 0.01,
                "\(curve.name) 在循环边界右侧斜率 \(right)——值连续但斜率跳变")
        }
    }

    @Test("眨眼不早于 0.6s，且整个窗口留在自己的 4s 槽里")
    func blinkWindowStaysInsideItsSlot() {
        // 窗口起点 = `4 × (0.15 + 0.6 × hash)`，值域 [0.6, 3.0)：这是「静止档取 ≤0.45s 就一定
        // 睁着眼」的算术依据（拉长眨眼时长只让窗口向后长，不影响这个下界）；窗口尾（含连眨的
        // 第二段）不越过 3.52s，因此槽边界前后都是睁满的常数 1，循环点上值连续。
        for agent in AgentKind.allCases {
            let seed = MascotMotion.stableSeed(agent.rawValue)
            for step in stride(from: 0.0, through: 0.595, by: 0.005) {
                #expect(
                    MascotMotion.blink(CGFloat(step), seed: seed) == 1,
                    "\(agent.rawValue) 在 \(step)s 就眨眼了——静止档代表时刻会看到闭眼")
            }
            for slot in 0..<6 {
                let boundary = CGFloat(slot) * 4.0
                #expect(MascotMotion.blink(boundary - 0.001, seed: seed) == 1)
                #expect(MascotMotion.blink(boundary, seed: seed) == 1)
                #expect(MascotMotion.blink(boundary + 0.001, seed: seed) == 1)
            }
        }
    }

    @Test("每一次眨眼在空闲帧率下都看得见（否则这个「活着」的信号等于没有）")
    func everyBlinkIsVisibleAtTheIdleFrameRate() {
        // 0.14s 的窗口在 8fps 下只有半个帧间隔的「看得出闭上」段，实测 144 次眨眼只有 24 次能
        // 被采到；时长拉长到 0.30s 后这一段跨过一个帧间隔，每一次都采得到。判据不写死时长：
        // 先扫出每一段没睁满的时间片，再按**全局帧网格**（k × 0.125s）检查片内至少有一帧
        // 半闭以下——窗口整个落在两帧之间时这条会红。
        let interval = AgentMascotStatus.idle.frameInterval
        let step = 0.005
        for agent in AgentKind.allCases {
            let seed = MascotMotion.stableSeed(agent.rawValue)
            var windows: [(start: Double, end: Double)] = []
            var start: Double? = nil
            var end = 0.0
            for tick in 0...Int(60.0 / step) {
                let t = Double(tick) * step
                if MascotMotion.blink(CGFloat(t), seed: seed) < 1 {
                    if start == nil { start = t }
                    end = t
                } else if let windowStart = start {
                    windows.append((start: windowStart, end: end))
                    start = nil
                }
            }
            #expect(windows.count >= 8, "\(agent.rawValue) 60 秒里只眨了 \(windows.count) 次")
            for window in windows {
                var visible = false
                var tick = Int((window.start / interval).rounded(.up))
                while Double(tick) * interval <= window.end {
                    if MascotMotion.blink(CGFloat(Double(tick) * interval), seed: seed) <= 0.5 {
                        visible = true
                        break
                    }
                    tick += 1
                }
                #expect(
                    visible,
                    "\(agent.rawValue) 有一次眨眼（\(window.start)s 起）在空闲帧率下完全看不见")
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
