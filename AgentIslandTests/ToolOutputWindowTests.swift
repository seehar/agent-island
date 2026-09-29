//
//  ToolOutputWindowTests.swift
//  AgentIslandTests
//
//  长输出的折叠窗口：`ToolOutputWindow` 只做「可见几行 / 还剩几行 / 要不要给展开入口 /
//  按钮用哪条文案」四个判断，与 SwiftUI 无关，所以这里直接钉算术，不渲染任何视图。
//
//  其中的折行估算是给「靠 `lineLimit` 按视觉行裁剪」的文本用的：只看换行符会漏掉
//  「整段 JSON 挤在一行」这类输出，它在界面上早被裁掉却拿不到展开入口。
//

import Testing

@testable import AgentIsland

@Suite("长输出的折叠窗口")
struct ToolOutputWindowTests {
    @Test("折叠态只露出上限行数，展开态露出全部")
    func visibleLineCountFollowsExpansion() {
        #expect(ToolOutputWindow.visibleLineCount(total: 400, limit: 15, isExpanded: false) == 15)
        #expect(ToolOutputWindow.visibleLineCount(total: 400, limit: 15, isExpanded: true) == 400)
        // 没到上限时两种状态都是全部，不因为「展开过」而变多
        #expect(ToolOutputWindow.visibleLineCount(total: 3, limit: 15, isExpanded: false) == 3)
        #expect(ToolOutputWindow.visibleLineCount(total: 3, limit: 15, isExpanded: true) == 3)
    }

    @Test("空内容与非法上限都不会露出负数行")
    func degenerateInputsAreClamped() {
        #expect(ToolOutputWindow.visibleLineCount(total: 0, limit: 15, isExpanded: false) == 0)
        #expect(ToolOutputWindow.visibleLineCount(total: 0, limit: 15, isExpanded: true) == 0)
        // 上限为负（调用点传错）时按 0 处理，而不是落到 min(total, -1)
        #expect(ToolOutputWindow.visibleLineCount(total: 5, limit: -1, isExpanded: false) == 0)
    }

    @Test("「还有 N 行」取隐藏行数：展开后归零，且不为负")
    func hiddenLineCountMatchesVisibleWindow() {
        #expect(ToolOutputWindow.hiddenLineCount(total: 400, limit: 15, isExpanded: false) == 385)
        #expect(ToolOutputWindow.hiddenLineCount(total: 400, limit: 15, isExpanded: true) == 0)
        #expect(ToolOutputWindow.hiddenLineCount(total: 3, limit: 15, isExpanded: false) == 0)
        #expect(ToolOutputWindow.hiddenLineCount(total: 3, limit: -1, isExpanded: false) == 3)
    }

    @Test("只有真被截断过才给展开入口")
    func toggleOnlyWhenTruncated() {
        #expect(ToolOutputWindow.isTruncated(total: 16, limit: 15))
        #expect(!ToolOutputWindow.isTruncated(total: 15, limit: 15))
        #expect(!ToolOutputWindow.isTruncated(total: 0, limit: 0))
    }

    @Test("展开 / 收起按钮的文案归属")
    func toggleLabelFollowsExpansion() {
        #expect(
            ToolOutputWindow.toggleLabel(total: 412, isExpanded: false)
                == ToolOutputWindow.ToggleLabel.showAll(lineCount: 412))
        #expect(
            ToolOutputWindow.toggleLabel(total: 412, isExpanded: true)
                == ToolOutputWindow.ToggleLabel.collapse)
        // 行数缺失/负数时给 0，不会拼出「Show all -3 lines」
        #expect(
            ToolOutputWindow.toggleLabel(total: -3, isExpanded: false)
                == ToolOutputWindow.ToggleLabel.showAll(lineCount: 0))
    }

    @Test("折行文本的行数估算：逻辑行数与折行数取大者")
    func wrappedLineCountEstimate() {
        // 逻辑行更多时用逻辑行数
        #expect(
            ToolOutputWindow.estimatedWrappedLineCount(of: "a\nb\nc", charactersPerLine: 64) == 3)

        // 整段挤在一行（逻辑行数 1）但长度超过一行容量：按折行数算，否则这类输出
        // 在界面上早被裁掉，却没有展开入口
        let singleLine = String(repeating: "x", count: 200)
        #expect(
            ToolOutputWindow.estimatedWrappedLineCount(of: singleLine, charactersPerLine: 64) == 4)

        // 边界：恰好一整行不算折行，多一个字符就多一行
        #expect(ToolOutputWindow.estimatedWrappedLineCount(of: "12345", charactersPerLine: 5) == 1)
        #expect(ToolOutputWindow.estimatedWrappedLineCount(of: "123456", charactersPerLine: 5) == 2)

        // 非法容量（0）不能除以零
        #expect(ToolOutputWindow.estimatedWrappedLineCount(of: "abc", charactersPerLine: 0) == 3)
    }
}