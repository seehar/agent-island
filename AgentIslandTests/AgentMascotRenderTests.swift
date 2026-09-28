//
//  AgentMascotRenderTests.swift
//  AgentIslandTests
//
//  18 枚像素角色的渲染判据。角色是手绘的方块拼合，最容易出的事故是「某一枚在某个场景
//  里什么都没画出来」（少写一块、坐标写到了网格外、场景分支写错），而这类事故**编译
//  与本地化守卫都抓不到**——只有把每个 Agent 的每个场景都真的渲染一遍才看得见。
//
//  同时钉住两条用户可见的契约：
//    · 同一时刻永远画出同一帧（动效是纯函数，离屏定帧与探针才对得上）；
//    · 三套场景必须互不相同——否则「静止」档位下三档看起来是同一张图。
//

import AppKit
import SwiftUI
import Testing

@testable import AgentIsland

@Suite("像素角色渲染")
struct AgentMascotRenderTests {
    /// 三套场景。
    private static let scenes: [AgentMascotStatus] = [.idle, .working, .alert]
    /// 判「场景互不相同」时采样的时刻：0（定帧契约）、各场景的代表时刻与一个动作中段。
    private static let probeTimes: [Double] = [0, 0.28, 0.6, 1.5]

    // MARK: - 渲染

    /// 把一枚角色在给定时刻定帧渲染成图像（`nil` 表示渲染失败）。
    @MainActor
    private func frameImage(
        _ agent: AgentKind, _ status: AgentMascotStatus, at time: Double,
        size: CGFloat = 64, scale: CGFloat = 1
    ) -> CGImage? {
        let view = AgentMascot(agent: agent, status: status, size: size, frozenTime: time)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// 把一枚角色在给定时刻定帧渲染成 RGBA 字节（`nil` 表示渲染失败）。
    @MainActor
    private func render(
        _ agent: AgentKind, _ status: AgentMascotStatus, at time: Double, size: CGFloat = 64
    ) -> [UInt8]? {
        guard let image = frameImage(agent, status, at: time, size: size) else { return nil }

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

    /// 判定用的像素数：只看**实心**像素（alpha > 200），因此待审批的光晕不计入
    /// ——不然 alert 的墨迹永远比别的场景大，「场景互不相同」就成了恒真断言。
    private func solidInk(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 200 ? 1 : 0) }
    }

    private func differs(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        lhs != rhs
    }

    /// 两帧摆的是不是**同一个姿势**：只在「至少一帧是不透明像素」的位置上比较颜色。
    ///
    /// 为什么不是逐字节：待审批那一档多了一层品牌色径向光晕（alpha ≤ 115），逐字节比会
    /// 因为它而不等——一个把 alert 误画成 idle 的角色照样能通过。为什么也不是「实心像素数 +
    /// 包围盒」：抬一条腿、挪一格光标这类**位置**变化不改变总数与包围盒，同样会漏判。
    /// 把比较限制在两帧的不透明区域内，光晕天然出局，而位置与颜色的变化都看得见。
    /// 边缘抗锯齿会有几个像素抖动，因此给一点容忍度（与确定性用例同一口径）。
    private func samePosture(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var union = 0
        var differing = 0
        for offset in stride(from: 0, to: min(lhs.count, rhs.count), by: 4) {
            guard lhs[offset + 3] > 200 || rhs[offset + 3] > 200 else { continue }
            union += 1
            if lhs[offset...offset + 3] != rhs[offset...offset + 3] { differing += 1 }
        }
        return differing <= max(8, union / 500)
    }

    // MARK: - 用例

    @Test("每个 Agent 的每个场景都画得出东西（少写一块/坐标出界会被抓到）")
    @MainActor
    func everySceneDrawsInk() {
        for agent in AgentKind.allCases {
            for scene in Self.scenes {
                guard let pixels = render(agent, scene, at: 0) else {
                    Issue.record("\(agent.rawValue) 的 \(scene) 渲染失败")
                    continue
                }
                let ink = solidInk(pixels)
                #expect(
                    ink > 150,
                    "\(agent.rawValue) 的 \(scene) 只画出 \(ink) 个像素——角色没画出来或画在了网格外"
                )
            }
        }
    }

    /// 实心像素的包围盒：给「姿态指纹」用（元组不可比较，因此给它一个具体类型）。
    private struct SolidBounds: Equatable {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    /// 实心像素（alpha > 200）的包围盒：`nil` 表示这一帧什么都没有。
    private func solidBounds(_ pixels: [UInt8], width: Int) -> SolidBounds? {
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 200 {
            let index = offset / 4
            let x = index % width
            let y = index / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return SolidBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    @Test("同一时刻永远画出同一帧（动效是时间的纯函数）")
    @MainActor
    func sameInstantRendersIdentically() {
        // 判据不是逐字节相同：`ImageRenderer` 自己会带一点抗锯齿噪声（实测同一二进制、
        // 同一时刻跑两次，边缘像素偶尔差几个；并行跑整套用例时更容易出现）。真正要钉住的
        // 是**姿态**——如果某个角色用了 `Date()` / 随机数 / 视图状态，差异会是一个部件
        // 的量级，而不是边缘那几个像素。所以：
        //   ① 姿态指纹（实心像素数 + 实心像素包围盒）必须逐项完全一致；
        //   ② 逐字节差异必须远小于一个部件（帧面积的 0.2% 以内）。
        for agent in AgentKind.allCases {
            for scene in Self.scenes {
                guard
                    let first = render(agent, scene, at: 1.234),
                    let second = render(agent, scene, at: 1.234)
                else {
                    Issue.record("\(agent.rawValue) 的 \(scene) 渲染失败")
                    continue
                }
                guard first.count == second.count else {
                    Issue.record(
                        "\(agent.rawValue) 的 \(scene) 两次渲染的帧尺寸不同（\(first.count) / \(second.count) 字节）"
                    )
                    continue
                }
                let width = Int(Double(first.count / 4).squareRoot())
                #expect(
                    solidInk(first) == solidInk(second),
                    "\(agent.rawValue) 的 \(scene) 两次渲染的实心像素数不同")
                #expect(
                    solidBounds(first, width: width) == solidBounds(second, width: width),
                    "\(agent.rawValue) 的 \(scene) 两次渲染的姿态不同（包围盒不一致）")

                var diff = 0
                for offset in stride(from: 0, to: first.count, by: 4)
                where first[offset...offset + 2] != second[offset...offset + 2] {
                    diff += 1
                }
                let tolerance = max(8, first.count / 4 / 500)
                #expect(
                    diff <= tolerance,
                    "\(agent.rawValue) 的 \(scene) 两次渲染差了 \(diff) 个像素（上限 \(tolerance)）——动效不是纯函数")
            }
        }
    }

    @Test("三套场景互不相同：静止档位下不会看到同一个姿态")
    @MainActor
    func scenesAreDistinguishable() {
        for agent in AgentKind.allCases {
            for scene in Self.scenes {
                // 静止档位要看到的那一帧，必须与另外两档摆成**不同的姿势**——用户在「静止」
                // 档挑档位时看到的就是这一帧。判据用姿态指纹而不是逐字节：待审批自带光晕，
                // 逐字节比会「因为多了层光晕」而不等，把「画错姿势」也判成通过。
                guard let still = render(agent, scene, at: scene.stillInstant) else {
                    Issue.record("\(agent.rawValue) 的 \(scene) 渲染失败")
                    continue
                }
                for other in Self.scenes where other != scene {
                    guard let otherStill = render(agent, other, at: other.stillInstant) else {
                        continue
                    }
                    #expect(
                        samePosture(still, otherStill) == false,
                        "\(agent.rawValue)：\(scene) 与 \(other) 在静止档位下摆的是同一个姿态"
                    )
                }
            }
        }
    }

    @Test("空闲与处理中在采样时刻里都动过（不是一张静止的图）")
    @MainActor
    func scenesActuallyMove() {
        // 只判空闲与处理中：这两档的**统一层不施加任何位移/缩放/光晕**，画面变与不变完全由
        // 角色自己决定，逐字节比才能证明「角色真的在动」。待审批那一档由统一层的三连跳驱动，
        // 逐字节比必然不等（角色自己站着不动也会通过），而「角色自己在这一档动没动」不构成
        // 契约（姿态可以是静止的，见 `AgentMascot` 头注释）。
        for agent in AgentKind.allCases {
            for scene in [AgentMascotStatus.idle, .working] {
                guard
                    let base = render(agent, scene, at: Self.probeTimes[0])
                else { continue }
                let moved = Self.probeTimes.dropFirst().contains { time in
                    guard let other = render(agent, scene, at: time) else { return false }
                    return differs(base, other)
                }
                #expect(moved, "\(agent.rawValue) 的 \(scene) 在所有采样时刻都一样，等于没动")
            }
        }
    }

    // MARK: - 人工核对用的接触表

    /// 接触表落在固定目录，与 `AgentSettingsLayoutTests` 的 `/tmp/agents-page-probe`
    /// 同一约定：`/tmp` 下、不入库、跑完就在那儿（人工核对时直接打开看）。
    private let probeDirectory = URL(fileURLWithPath: "/tmp/agent-mascot-probe", isDirectory: true)

    /// 把所有角色 × 三套场景（取「静止」档位要显示的那一帧）拼成对照图写到 /tmp。
    ///
    /// 像素角色是手绘方块：编译、本地化与上面的像素判据只能证明「画了东西、三档互不相同」，
    /// 证明不了「像那个产品、像个人」。所以留一张可视图给改动者与复核者看。
    @Test("写两张接触表到 /tmp（18 枚 × 3 场景，27pt 与 64pt，人工核对用）")
    @MainActor
    func writesContactSheets() throws {
        let directory = probeDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, size) in [("contact-sheet-27", CGFloat(27)), ("contact-sheet-64", CGFloat(64))] {
            guard let sheet = contactSheet(size: size) else {
                Issue.record("\(name) 渲染失败")
                continue
            }
            let url = directory.appendingPathComponent("\(name).png")
            let rep = NSBitmapImageRep(cgImage: sheet)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                Issue.record("\(name) 编码 PNG 失败")
                continue
            }
            try data.write(to: url)
            // 断言「写得可读」而不是 `fileExists`（后者在 write 不抛异常时恒真）：
            // 重新解码出来，尺寸要与刚渲染的图一致。
            guard let reloaded = NSBitmapImageRep(data: data) else {
                Issue.record("\(name) 写出的 PNG 解不回来")
                continue
            }
            #expect(
                reloaded.pixelsWide == sheet.width && reloaded.pixelsHigh == sheet.height,
                "\(name) 落盘尺寸 \(reloaded.pixelsWide)×\(reloaded.pixelsHigh) 与渲染的 \(sheet.width)×\(sheet.height) 不符")
            print("[标记动态] 接触表 \(url.path) \(sheet.width)×\(sheet.height)")
        }
    }

    /// 拼接触表：行 = Agent（顺序同 `AgentKind.allCases`），列 = 三套场景。
    @MainActor
    private func contactSheet(size: CGFloat, scale: CGFloat = 2) -> CGImage? {
        let cell = Int(size * scale)
        let gap = 8
        let columns = Self.scenes.count
        let rows = AgentKind.allCases.count
        let width = columns * cell + (columns + 1) * gap
        let height = rows * cell + (rows + 1) * gap
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (rowIndex, agent) in AgentKind.allCases.enumerated() {
            for (columnIndex, scene) in Self.scenes.enumerated() {
                guard
                    let image = frameImage(
                        agent, scene, at: scene.stillInstant, size: size, scale: scale)
                else { continue }
                // CGContext 的 y 轴向上：行号反过来放，第一枚 Agent 才落在图的顶部。
                let rect = CGRect(
                    x: gap + columnIndex * (cell + gap),
                    y: height - gap - (rowIndex + 1) * cell - rowIndex * gap,
                    width: cell,
                    height: cell)
                context.draw(image, in: rect)
            }
        }
        return context.makeImage()
    }
}
