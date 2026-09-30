//
//  AppMotionTests.swift
//  AgentIslandTests
//
//  动效闸门与档位的判据：`AppMotion.pick` 只在「减弱动态效果」开着时换曲线；角色动效速度档位
//  夹到离散的 0 / 0.5 / 1 / 2 四档、缺键取 1（档位算错会直接表现为「角色不动了」或「角色飞快」，
//  是用户看得见的故障）；另外钉住转轮在「减弱动态」下确实定格——不建时钟、也不是空白。
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("动效闸门与档位")
struct AppMotionTests {
    /// `Animation` 不是 `Equatable`，用它的描述当等值代理（同一次构造的描述稳定）。
    private func describe(_ animation: Animation) -> String { String(describing: animation) }

    // MARK: - 闸门

    @Test("减弱动态：pick 换成短过渡，否则原样返回")
    func pickSwapsOnlyWhenReduced() {
        let spring: Animation = .spring(response: 0.4, dampingFraction: 0.6)
        #expect(describe(AppMotion.pick(spring, reduceMotion: false)) == describe(spring))
        #expect(describe(AppMotion.pick(spring, reduceMotion: true)) == describe(AppMotion.reduced))
        #expect(describe(AppMotion.pick(spring, reduceMotion: true)) != describe(spring))
    }

    @Test("reduced 是短过渡（0.12 秒），不是长曲线")
    func reducedIsShort() {
        #expect(describe(AppMotion.reduced).contains("0.12"))
    }

    // MARK: - 速度档位

    @Test("速度档位：夹到 0 / 0.5 / 1 / 2，取最接近的一档")
    func speedClampsToTiers() {
        for tier in AppSettings.mascotAnimationSpeedTiers {
            #expect(AppSettings.clampedMascotAnimationSpeed(tier) == tier)
        }
        #expect(AppSettings.clampedMascotAnimationSpeed(0.3) == 0.5)
        #expect(AppSettings.clampedMascotAnimationSpeed(0.7) == 0.5)
        #expect(AppSettings.clampedMascotAnimationSpeed(1.6) == 2)
        #expect(AppSettings.clampedMascotAnimationSpeed(9) == 2)
        #expect(AppSettings.clampedMascotAnimationSpeed(-4) == 0)
        // 并列时取更小的一档：结果确定，不随实现细节摇摆。
        #expect(AppSettings.clampedMascotAnimationSpeed(0.25) == 0)
        #expect(AppSettings.clampedMascotAnimationSpeed(1.5) == 1)
    }

    @Test("速度偏好：缺键取 1，写入按档位落盘到视图共用的那个键")
    func speedPersistsUnderTheDocumentedKey() throws {
        let suiteName = "AppMotionTests.speed"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        // 缺键 = 1（与改造前一致）：`double(forKey:)` 对缺失键返回 0，直接用会把角色定格。
        #expect(AppSettings.mascotAnimationSpeed(defaults: suite) == 1)

        AppSettings.setMascotAnimationSpeed(0.3, defaults: suite)
        #expect(AppSettings.mascotAnimationSpeed(defaults: suite) == 0.5)
        // 落盘的键必须就是视图 `@AppStorage` 用的那一个（不一致会表现成「设置了没反应」）。
        #expect(suite.double(forKey: AppSettings.mascotAnimationSpeedKey) == 0.5)

        AppSettings.setMascotAnimationSpeed(0, defaults: suite)
        #expect(AppSettings.mascotAnimationSpeed(defaults: suite) == 0)
    }

    // MARK: - 不建时钟的判据与 0 档

    @Test("不建时钟的判据：显式定帧 > 减弱动态 / 0 档 > 时钟")
    func frozenInstantPrecedence() {
        for status in [AgentMascotStatus.idle, .working, .alert] {
            // 正常情况：走时钟。
            #expect(
                AgentMascot.frozenInstant(
                    status: status, explicit: nil, reduceMotion: false, speed: 1) == nil)
            // 「减弱动态」与 0 档都取该场景的**代表帧**——不是空白，也不是随机的一帧。
            #expect(
                AgentMascot.frozenInstant(
                    status: status, explicit: nil, reduceMotion: true, speed: 1)
                    == status.stillInstant)
            #expect(
                AgentMascot.frozenInstant(
                    status: status, explicit: nil, reduceMotion: false, speed: 0)
                    == status.stillInstant)
            // 其余档位照常走时钟（它们只是缩放时间轴）。
            for speed in [0.5, 2.0] {
                #expect(
                    AgentMascot.frozenInstant(
                        status: status, explicit: nil, reduceMotion: false, speed: speed) == nil)
            }
            // 显式定帧优先：画廊与探针要的就是那一帧，不该被用户偏好改写。
            #expect(
                AgentMascot.frozenInstant(
                    status: status, explicit: 1.234, reduceMotion: true, speed: 0) == 1.234)
        }
    }

    @Test("0 档（定格）：角色与转轮都停在代表帧上，不随时间走")
    @MainActor
    func zeroTierFreezesMascotAndSpinner() {
        // 档位存在偏好域里、视图用 `@AppStorage` 读它（`accessibilityReduceMotion` 是只读的
        // 环境键，注入不进离屏渲染），所以这条判据走真实链路：在标准偏好域里写一次、跑完还原。
        let key = AppSettings.mascotAnimationSpeedKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        AppSettings.setMascotAnimationSpeed(0, defaults: .standard)

        let status = AgentMascotStatus.working
        guard
            let expected = render(
                AgentMascot(
                    agent: .claudeCode, status: status, size: 64,
                    frozenTime: status.stillInstant)),
            let frozen = render(AgentMascot(agent: .claudeCode, status: status, size: 64))
        else {
            Issue.record("角色渲染失败")
            return
        }
        #expect(
            pixelDiff(frozen, expected) <= tolerance(frozen),
            "0 档没有停在代表帧（\(status.stillInstant)s）上")
        #expect(solidInk(frozen) > 150, "0 档的角色帧没画出角色")

        let spinner = AgentSpinner(agent: .claudeCode, size: 24)
        guard let spinnerFirst = render(spinner) else {
            Issue.record("转轮渲染失败")
            return
        }
        #expect(ink(spinnerFirst) > 0, "0 档的转轮帧是空白")
        // 跨过帧节拍（转轮 0.15s、角色忙碌档 0.05s）再看：还在走时钟的话，两帧都会变。
        Thread.sleep(forTimeInterval: 0.4)
        guard let spinnerLater = render(spinner), let frozenLater = render(
            AgentMascot(agent: .claudeCode, status: status, size: 64))
        else {
            Issue.record("第二次渲染失败")
            return
        }
        #expect(pixelDiff(spinnerFirst, spinnerLater) <= tolerance(spinnerFirst), "0 档的转轮还在转")
        #expect(pixelDiff(frozen, frozenLater) <= tolerance(frozen), "0 档的角色还在动")
        // 定格的是转轮帧表的第一帧（各 Agent 自己那一套的起始帧）。
        #expect(
            AgentSpinner.glyph(for: .claudeCode, at: Date(timeIntervalSinceReferenceDate: 0))
                == AgentSpinner.frames(for: .claudeCode)[0])
    }

    // MARK: - 渲染工具（与角色渲染测试同一口径）

    /// 定帧渲染成 RGBA 字节。
    @MainActor
    private func render<V: View>(_ view: V) -> [UInt8]? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// 画出来的像素数（alpha > 0）。
    private func ink(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
    }

    /// 判定用的像素数：只看实心像素（alpha > 200），与角色渲染测试同一阈值。
    private func solidInk(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 200 ? 1 : 0) }
    }

    /// 两张同尺寸帧的差异像素数。
    private func pixelDiff(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count else { return Int.max }
        return stride(from: 0, to: lhs.count, by: 4).reduce(0) {
            $0 + (lhs[$1...$1 + 2] != rhs[$1...$1 + 2] ? 1 : 0)
        }
    }

    /// `ImageRenderer` 自带一点抗锯齿噪声，与角色渲染测试用同一条容忍度。
    private func tolerance(_ pixels: [UInt8]) -> Int {
        max(8, pixels.count / 4 / 500)
    }
}