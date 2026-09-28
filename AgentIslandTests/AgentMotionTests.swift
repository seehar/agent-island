//
//  AgentMotionTests.swift
//  AgentIslandTests
//
//  动效是「时间的纯函数」——同一时刻渲染出的画面必须永远一致，且各通道都落在画得出来
//  的范围里（NaN 或过大的位移会让标记飞出刘海）。这里把这两条钉住，也钉住「招牌动作
//  确实用到了各字形可动的部件，而不是一律弹跳」。
//

import CoreGraphics
import Foundation
import Testing

@testable import AgentIsland

@Suite("标记动效")
struct AgentMotionTests {
    /// 采样时刻：按 0.05s 步长覆盖呼吸、眨眼、走步、三连跳的多个周期。
    private static let samples: [Double] = stride(from: 0.0, through: 40.0, by: 0.05).map { $0 }

    private static let activities: [AgentLogoActivity] = [.idle, .working, .alert]

    @Test("同一时刻永远算出同一个动作（纯函数，可离屏定帧）")
    func motionIsPure() {
        for agent in AgentKind.allCases {
            for activity in Self.activities {
                for t in [0.0, 1.234, 7.5, 33.33] {
                    let a = AgentMotion.motion(for: agent, activity: activity, at: t, size: 14)
                    let b = AgentMotion.motion(for: agent, activity: activity, at: t, size: 14)
                    #expect(a.dy == b.dy)
                    #expect(a.rotation == b.rotation)
                    #expect(a.scaleX == b.scaleX)
                    #expect(a.scaleY == b.scaleY)
                    #expect(a.blink == b.blink)
                    #expect(a.glow == b.glow)
                    #expect(a.walkPhase == b.walkPhase)
                    #expect(a.legLift.0 == b.legLift.0)
                    #expect(a.legLift.1 == b.legLift.1)
                    #expect(a.innerOpacity == b.innerOpacity)
                    #expect(a.sway == b.sway)
                }
            }
        }
    }

    @Test("每个 Agent 的每个状态都算得出有限、克制的动作")
    func motionChannelsStayInRange() {
        for agent in AgentKind.allCases {
            for activity in Self.activities {
                for size in [CGFloat(12), 14, 32] {
                    let unit = max(0.6, size * 0.1)
                    // 圆滚字形的两枚整圈自转，其余只做小幅摇摆
                    let isSpinner = agent == .qoder || agent == .grok
                    for t in Self.samples {
                        let m = AgentMotion.motion(for: agent, activity: activity, at: t, size: size)
                        #expect(m.dy.isFinite && m.dy <= 0 && m.dy >= -unit * 2.0)
                        #expect(m.scaleX.isFinite && m.scaleX > 0.5 && m.scaleX < 1.6)
                        #expect(m.scaleY.isFinite && m.scaleY > 0.5 && m.scaleY < 1.6)
                        #expect(m.rotation.isFinite)
                        if isSpinner && activity == .working {
                            // 招牌动作是整圈自转：角度只增不减（0..<360）
                            #expect(m.rotation >= 0 && m.rotation <= 360)
                        } else {
                            // 其余（含自转型标记的空闲小动作）只做小幅摇摆
                            #expect(abs(m.rotation) <= 12)
                        }
                        #expect(m.blink >= 0 && m.blink <= 1)
                        #expect(m.glow >= 0 && m.glow <= 1)
                        #expect(m.innerOpacity >= 0.3 && m.innerOpacity <= 1)
                        #expect(m.sway.isFinite && abs(m.sway) <= unit)
                        if let phase = m.walkPhase { #expect((0..<4).contains(phase)) }
                    }
                }
            }
        }
    }

    @Test("只有待审批发光：空闲与处理中一律不发光")
    func onlyAlertGlows() {
        for agent in AgentKind.allCases {
            for t in Self.samples {
                #expect(AgentMotion.motion(for: agent, activity: .alert, at: t, size: 20).glow > 0.2)
                #expect(AgentMotion.motion(for: agent, activity: .idle, at: t, size: 20).glow == 0)
                #expect(AgentMotion.motion(for: agent, activity: .working, at: t, size: 20).glow == 0)
            }
        }
    }

    @Test("眨眼在多数时间睁着，且确实闭上过")
    func blinkIsMostlyOpenWithRealBlinks() {
        var shut = 0
        let total = Self.samples.count
        for t in Self.samples {
            let value = AgentMotion.blink(t, seed: AgentMotion.stableSeed("claude"))
            #expect(value >= 0 && value <= 1)
            if value < 0.5 { shut += 1 }
        }
        #expect(shut > 0, "整段时间一次都没闭眼，等于没有眨眼")
        #expect(Double(shut) / Double(total) < 0.15, "闭眼占比过高，标记会像在闪烁")
    }

    @Test("确定性哈希与种子跨调用稳定")
    func hashAndSeedAreStable() {
        #expect(AgentMotion.stableSeed("claude") == AgentMotion.stableSeed("claude"))
        #expect(AgentMotion.stableSeed("claude") != AgentMotion.stableSeed("codex"))
        #expect(AgentMotion.hash01(3, seed: 7) == AgentMotion.hash01(3, seed: 7))
        for n in 0..<50 {
            let v = AgentMotion.hash01(n)
            #expect(v >= 0 && v < 1)
        }
    }

    @Test("招牌动作用到了各字形可动的部件，不是一律弹跳")
    func signaturesUseGlyphParts() {
        let t = 0.35
        func working(_ agent: AgentKind) -> AgentLogoMotion {
            AgentMotion.motion(for: agent, activity: .working, at: t, size: 20)
        }
        // 螃蟹：走步相位（四条腿因此交替）
        #expect(working(.claudeCode).walkPhase != nil)
        // π：两条腿交替抬起
        let omp = working(.ohMyPi)
        #expect(omp.legLift.0 != 0 || omp.legLift.1 != 0)
        // OpenCode：内孔明暗脉冲
        #expect(working(.opencode).innerOpacity != 1)
        // Qoder 的缺口环：自转
        #expect(working(.qoder).rotation != 0)
        // Gemini 的四角星：闪烁（缩放）
        #expect(working(.gemini).scaleX != 1)
    }
}
