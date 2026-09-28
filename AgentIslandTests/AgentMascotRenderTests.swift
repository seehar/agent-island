//
//  AgentMascotRenderTests.swift
//  AgentIslandTests
//
//  18 枚像素角色的渲染判据。角色是 Canvas 上按 SVG 单位手绘的拼合图形，最容易出的事故是
//  「某一枚在某个场景里什么都没画出来」（少写一块、坐标画到了视口外、场景分支写错），
//  而这类事故**编译与本地化守卫都抓不到**——只有把每个 Agent 的每个场景都真的渲染一遍才看得见。
//
//  同时钉住三条用户可见的契约：
//    · 同一时刻永远画出同一帧（动效是纯函数，离屏定帧与探针才对得上）；
//    · 三套场景必须互不相同——否则「静止」档位下三档看起来是同一张图；
//    · 待审批的起跳**不许把身体抛出画布**（顶点那一帧仍看得见身体）。
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
        // 只判空闲与处理中：这两档的画面变与不变完全由角色自己决定（起跳档自带三连跳，
        // 逐字节比必然不等，证明不了「角色自己也在动」）。
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

    @Test("待审批的顶点不把身体抛出画布：按各角色自己的截顶入参推导")
    @MainActor
    func alertApexKeepsTheBodyInFrame() {
        // 判据用**算式**而不是渲染出的像素比例：离屏实测过，「顶点那一帧的实心像素数 ÷ 静止档
        // 那一帧」对 16 枚里的 12 枚拦不住「把截顶系数去掉」这种回退——Pi / Hermes 的位移表在
        // 静止档取样的那一刻（0.35s）已经接近它们自己的顶点，两帧同样被裁，比值天然接近 1。
        // 算式读的是各角色自己暴露的 `alertSpec`（`drawAlert` 的 `rise` 与它同源），
        // 而「身体顶边有没有越过视口上边缘」与渲染出来会不会被裁掉是同一件事。
        for agent in AgentKind.allCases {
            let spec = AgentMascot.alertSpec(for: agent)
            #expect(
                spec.apexBodyTop >= spec.svgTop - spec.overshoot - 0.0001,
                "\(agent.rawValue) 的起跳顶点把身体顶边抬到 \(spec.apexBodyTop)（视口上边缘 \(spec.svgTop)）——身体会被裁出画布"
            )
        }
    }

    @Test("睡眠 Z 的提亮档：黑舞台上读得出来、不换色相、不被洗成灰")
    func sleepZTintStaysReadableAndOnHue() {
        // 输入是各角色 `sleepZ` 实际会传的那几支：18 个品牌色（中性档的几个角色直接用它），
        // 外加三支与品牌色不同的角色机身色。判据是**值域**性质——具体谁配哪一支由接触表人工核对
        // （像素角色是手绘方块，颜色搭配没法用断言证明「像不像那个角色」）。
        let samples: [(name: String, color: Color)] =
            AgentKind.allCases.map { ($0.rawValue, $0.brandColor) }
            + [
                ("cline 机身绿", Color(mascotHex: 0x00B37D)),
                ("copilot 机身玫红", Color(mascotHex: 0xCC3366)),
                ("pi 机身青绿", Color(red: 0.14, green: 0.49, blue: 0.53)),
            ]

        func hue(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat? {
            let maxComponent = max(red, green, blue)
            let minComponent = min(red, green, blue)
            let chroma = maxComponent - minComponent
            guard chroma > 0.02 else { return nil }
            let normalized: CGFloat
            switch maxComponent {
            case red: normalized = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
            case green: normalized = (blue - red) / chroma + 2
            default: normalized = (red - green) / chroma + 4
            }
            return (normalized / 6 + 1).truncatingRemainder(dividingBy: 1)
        }

        func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
            0.2126 * red + 0.7152 * green + 0.0722 * blue
        }

        func components(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            return (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        }

        for (name, color) in samples {
            guard let base = components(color) else {
                Issue.record("\(name)：颜色换算失败")
                continue
            }
            let lifted = color.liftedTowardWhite(MascotDraw.ZLadder.sleepZLift)
            guard let lit = components(lifted) else {
                Issue.record("\(name)：提亮档换算失败")
                continue
            }
            let baseLuminance = luminance(base.red, base.green, base.blue)
            let litLuminance = luminance(lit.red, lit.green, lit.blue)
            // 人眼在峰值那一刻看到的是「提亮档 × 峰值不透明度」，可读性按它算。
            let displayed = litLuminance * Double(MascotDraw.ZLadder.peakOpacity)
            #expect(
                displayed >= 0.30,
                "\(name) 的睡眠 Z 在峰值只有 \(displayed) 的亮度——会在黑舞台上糊掉")
            #expect(
                litLuminance >= baseLuminance - 0.0001,
                "\(name) 的睡眠 Z 比原色还暗——提亮方向反了")
            guard
                let baseHue = hue(base.red, base.green, base.blue),
                let litHue = hue(lit.red, lit.green, lit.blue)
            else { continue }  // 中性灰（cursor / opencode / grok / copilot / cline 的品牌档）没有色相
            let delta = abs(baseHue - litHue) * 360
            #expect(
                min(delta, 360 - delta) < 3,
                "\(name) 的睡眠 Z 色相偏了 \(min(delta, 360 - delta))°——不再是这支颜色")
            // 提亮不能把彩色洗成灰（洗成灰的话上面那条色相检查会因 chroma 太小而静默跳过）。
            let litChroma = max(lit.red, lit.green, lit.blue) - min(lit.red, lit.green, lit.blue)
            #expect(
                litChroma >= 0.10,
                "\(name) 的睡眠 Z 被洗成了灰（chroma \(litChroma)）——读不出颜色")
        }
    }

    @Test("睡眠 Z：三枚排成斜梯（互不重叠、不出画布），且任一时刻不会三枚全亮")
    func sleepZLadderStaysReadable() {
        // 判据取几何（与 `zGlyph` 同源的 `zGlyphRect`）而不是渲染出的像素：Z 可能压在同色
        // 身体上（Codex 的白云、Grok 的白环），按颜色阈值找脚印必漏。
        var visibleCounts: [Int] = []
        let sizes: [CGFloat] = [14, 26, 44, 64]
        for size in sizes {
            // 身体顶边之上的可用高度：实测是画布的 0.17…0.31（15×12 的趴姿视口），这里取
            // 「画布里的任意高度」做全量性质检查——比逐枚角色取真实入参更能挡住越界。
            let bands = stride(from: 1.5, through: size, by: 0.5).map { CGFloat($0) }
            for band in bands {
                guard let ladder = MascotDraw.zLadder(bodyTopY: band, size: size) else { continue }
                // 上浮到最高（envelope = 1）时也不许出画布。
                let rects = ladder.ghosts.indices.map { ladder.rect(slot: $0, float: 1) }
                for (index, rect) in rects.enumerated() {
                    #expect(
                        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= size && rect.maxY <= size,
                        "\(size)pt、头顶余量 \(band)：第 \(index) 枚 Z 出画布了（\(rect)）")
                }
                for i in rects.indices {
                    for j in rects.indices where j > i {
                        let overlap = rects[i].intersection(rects[j])
                        #expect(
                            overlap.isNull || overlap.isEmpty,
                            "\(size)pt、头顶余量 \(band)：第 \(i) 与第 \(j) 枚 Z 叠在一起（\(overlap)）")
                    }
                }
                for step in 0..<Int(MascotDraw.ZLadder.cycle / 0.05) {
                    visibleCounts.append(ladder.visibleSlots(t: CGFloat(step) * 0.05).count)
                }
            }
        }
        #expect(visibleCounts.max() ?? 0 <= 2, "某一时刻三枚 Z 同时在亮——又会糊成一坨")
        let mean = Double(visibleCounts.reduce(0, +)) / Double(max(1, visibleCounts.count))
        #expect(mean > 0.8, "大部分时刻一枚 Z 都不亮（平均 \(mean) 枚）")
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
