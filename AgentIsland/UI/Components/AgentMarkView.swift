//
//  AgentMarkView.swift
//  AgentIsland
//
//  把 `AgentMarkGeometry` 画成一枚单色标记。只用 SwiftUI Canvas + CoreGraphics，
//  不引用应用内任何其它类型（独立探针可把它与 AgentMarks.swift 一起编译）。
//
//  坐标口径（与 AgentLogo 里的 PixelMark 一致）：`viewBox` 是字形自己的包围盒（官方
//  SVG 的坐标已整体平移到该包围盒原点，PNG 轮廓化则直接以像素坐标计），渲染时按
//  min(宽比, 高比) 等比缩放到画布内居中——视图自身的高度恒为 `size`，宽度按 viewBox
//  宽高比推导，于是不同标记在同一 size 下视觉高度一致，非正方形 viewBox 也不会被压扁。
//
//  填充规则：一律用 even-odd（`FillStyle(eoFill: true)`）。轮廓化的字形把「洞」
//  写成独立的子路径（如 Qoder 的斜槽、Codex 里的提示符挖空），官方 SVG 里
//  的挖空同理——这个规则已被取证探针逐枚比对过（见 AgentMarks.swift 的注释）。
//

import SwiftUI

/// 一枚单色矢量标记。高度 = size，宽度 = size × viewBox 宽高比。
struct AgentMarkView: View {
    let geometry: AgentMarkGeometry
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvasSize in
            let viewBox = geometry.viewBox
            let vw = max(viewBox.width, 1)
            let vh = max(viewBox.height, 1)
            // 等比缩放居中：先按较紧的那一边求比例，再把 viewBox 的中心对到画布中心
            let scale = min(canvasSize.width / vw, canvasSize.height / vh)
            let dx = (canvasSize.width - vw * scale) / 2
            let dy = (canvasSize.height - vh * scale) / 2
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: dx, y: dy))

            switch geometry.shape {
            case .rects(let rects):
                for rect in rects {
                    context.fill(
                        Path(rect).applying(transform), with: .color(color))
                }
            case .path(let data):
                let path = SVGPath.path(from: data).applying(transform)
                context.fill(
                    path, with: .color(color), style: FillStyle(eoFill: true))
            }
        }
        .frame(width: size * aspectRatio, height: size)
    }

    /// 宽度按 viewBox 宽高比推导；viewBox 退化时按 1 兜底，避免 0/NaN 尺寸。
    private var aspectRatio: CGFloat {
        max(geometry.viewBox.width, 1) / max(geometry.viewBox.height, 1)
    }
}

// MARK: - 最小 SVG path 解析器

/// 把 SVG path 的 `d` 数据解析成 `Path`。支持 M/m L/l H/h V/v C/c S/s Q/q T/t Z/z；
/// 不支持弧命令 A/a（取源的规则是：源里出现弧就改用 PNG 轮廓化）。
/// 曲线不展直，直接交给 CoreGraphics，缩放后依然是矢量。
private enum SVGPath {
    static func path(from data: String) -> Path {
        var path = Path()
        var scanner = Scanner(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        /// 上一段的第二控制点，供 S/T 的隐式反射用
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while let command = scanner.nextCommand() {
            let relative = command.isLowercase
            switch Character(command.uppercased()) {
            case "M", "L":
                let isMove = command.uppercased() == "M"
                var first = true
                while let point = scanner.nextPoint() {
                    let target = relative ? current + point : point
                    if first && isMove {
                        path.move(to: target)
                        start = target
                    } else {
                        path.addLine(to: target)
                    }
                    current = target
                    first = false
                    if !scanner.hasNextNumber { break }
                }
                lastCubicControl = nil
                lastQuadControl = nil
            case "H":
                while let value = scanner.nextNumber() {
                    let target = CGPoint(x: relative ? current.x + value : value, y: current.y)
                    path.addLine(to: target)
                    current = target
                    if !scanner.hasNextNumber { break }
                }
                lastCubicControl = nil
                lastQuadControl = nil
            case "V":
                while let value = scanner.nextNumber() {
                    let target = CGPoint(x: current.x, y: relative ? current.y + value : value)
                    path.addLine(to: target)
                    current = target
                    if !scanner.hasNextNumber { break }
                }
                lastCubicControl = nil
                lastQuadControl = nil
            case "C":
                while let a = scanner.nextPoint(), let b = scanner.nextPoint(), let c = scanner.nextPoint() {
                    let control1 = relative ? current + a : a
                    let control2 = relative ? current + b : b
                    let target = relative ? current + c : c
                    path.addCurve(to: target, control1: control1, control2: control2)
                    lastCubicControl = control2
                    lastQuadControl = nil
                    current = target
                    if !scanner.hasNextNumber { break }
                }
            case "S":
                while let b = scanner.nextPoint(), let c = scanner.nextPoint() {
                    let control2 = relative ? current + b : b
                    let target = relative ? current + c : c
                    let control1 = lastCubicControl.map { CGPoint(x: 2*current.x - $0.x, y: 2*current.y - $0.y) } ?? current
                    path.addCurve(to: target, control1: control1, control2: control2)
                    lastCubicControl = control2
                    lastQuadControl = nil
                    current = target
                    if !scanner.hasNextNumber { break }
                }
            case "Q":
                while let a = scanner.nextPoint(), let b = scanner.nextPoint() {
                    let control = relative ? current + a : a
                    let target = relative ? current + b : b
                    path.addQuadCurve(to: target, control: control)
                    lastQuadControl = control
                    lastCubicControl = nil
                    current = target
                    if !scanner.hasNextNumber { break }
                }
            case "T":
                while let b = scanner.nextPoint() {
                    let target = relative ? current + b : b
                    let control = lastQuadControl.map { CGPoint(x: 2*current.x - $0.x, y: 2*current.y - $0.y) } ?? current
                    path.addQuadCurve(to: target, control: control)
                    lastQuadControl = control
                    lastCubicControl = nil
                    current = target
                    if !scanner.hasNextNumber { break }
                }
            case "Z":
                path.closeSubpath()
                current = start
                lastCubicControl = nil
                lastQuadControl = nil
            default:
                break
            }
        }
        return path
    }

    /// 逐字符扫描 `d`：命令字母与数字分开取，数字支持负号、小数与科学计数法。
    private struct Scanner {
        private let chars: [Character]
        private var index = 0

        init(_ data: String) { chars = Array(data) }

        private mutating func skipSeparators() {
            while index < chars.count {
                let c = chars[index]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                    index += 1
                } else {
                    break
                }
            }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            while index < chars.count {
                let c = chars[index]
                if c.isLetter {
                    index += 1
                    return c
                }
                if c.isNumber || c == "-" || c == "+" || c == "." {
                    index += 1          // 落单的数字：跳过，别让后面的命令被静默丢掉
                } else {
                    index += 1
                }
            }
            return nil
        }

        var hasNextNumber: Bool {
            var probe = self
            return probe.nextNumber() != nil
        }

        mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let begin = index
            if chars[index] == "-" || chars[index] == "+" { index += 1 }
            var sawDigit = false
            while index < chars.count, chars[index].isNumber {
                index += 1
                sawDigit = true
            }
            if index < chars.count, chars[index] == "." {
                index += 1
                while index < chars.count, chars[index].isNumber {
                    index += 1
                    sawDigit = true
                }
            }
            if sawDigit, index < chars.count, chars[index] == "e" || chars[index] == "E" {
                let exponentStart = index
                index += 1
                if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
                var exponentDigits = 0
                while index < chars.count, chars[index].isNumber {
                    index += 1
                    exponentDigits += 1
                }
                if exponentDigits == 0 { index = exponentStart }
            }
            guard sawDigit else {
                index = begin
                return nil
            }
            return CGFloat(Double(String(chars[begin..<index])) ?? 0)
        }

        mutating func nextPoint() -> CGPoint? {
            guard let x = nextNumber(), let y = nextNumber() else { return nil }
            return CGPoint(x: x, y: y)
        }
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}