//
//  AskAnswerBuilderTests.swift
//  AgentIslandTests
//
//  「ask 作答通道」的回传语义（R2 冻结版）：`answers` 的三种状态必须在字节上分得开。
//
//  * **键存在** = 该题被作答；
//  * **值为空数组** = 多选题的「明确一个都不选」，必须原样带走；
//  * **键缺失** = 该题未作答。
//
//  只有**所有键都缺失**（字典为空）时才不发 `answer`，折成 `deny`（放弃作答）。
//  单选不支持「不选」：它的空值等同未作答。
//
//  这一层是纯函数（`AskAnswerBuilder` + `AskSelection`），因此断言的是「选择 → 字节」，
//  不依赖 UI 也不依赖 socket。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("ask 作答决定")
struct AskAnswerBuilderTests {
    /// 与 `HookSocketServer.responseEncoder` 同口径（`.sortedKeys`）的编码器：
    /// 键序不稳定的话，字节级断言就不成立（见该静态编码器的注释）。
    private func bytes(_ response: HookResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(response),
            let text = String(data: data, encoding: .utf8)
        else { return "<encode failed>" }
        return text
    }

    @Test("空数组是「明确不选」，仍要发 answer 且原样带回")
    func explicitNoneIsAnAnswer() {
        let response = AskAnswerBuilder.response(answers: ["q1": []])
        #expect(response.decision == AskAnswerBuilder.decisionAnswer)
        #expect(response.answers?["q1"] == [])
        #expect(bytes(response) == #"{"answers":{"q1":[]},"decision":"answer"}"#)
        #expect(bytes(response).contains(#""q1":[]"#))
    }

    @Test("「明确不选」与正常作答并存时两键都在")
    func explicitNoneCoexistsWithAnswers() {
        let response = AskAnswerBuilder.response(answers: ["q1": [], "q2": ["A"]])
        #expect(response.decision == AskAnswerBuilder.decisionAnswer)
        #expect(response.answers == ["q1": [], "q2": ["A"]])
        #expect(bytes(response) == #"{"answers":{"q1":[],"q2":["A"]},"decision":"answer"}"#)
    }

    @Test("一个键都没有才算放弃作答：折成 deny 且不带 answers")
    func noKeysFoldsToDeny() {
        let response = AskAnswerBuilder.response(answers: [:])
        #expect(response.decision == AskAnswerBuilder.decisionDeny)
        #expect(response.answers == nil)
        #expect(bytes(response) == #"{"decision":"deny"}"#)
    }

    @Test("reason 与答案并存：deny 的原因是用户放弃作答")
    func reasonSurvivesOnDeny() {
        let response = AskAnswerBuilder.response(answers: [:], reason: "用户跳过")
        #expect(response.decision == AskAnswerBuilder.decisionDeny)
        #expect(response.reason == "用户跳过")
        #expect(response.answers == nil)
    }

    @Test("allow / deny / ask 原样透传，不出现 answers 键")
    func legacyDecisionsPassThrough() {
        let allow = AskAnswerBuilder.normalized(decision: "allow", answers: nil, reason: nil)
        #expect(allow.decision == "allow")
        #expect(allow.answers == nil)
        #expect(bytes(allow) == #"{"decision":"allow"}"#)

        let deny = AskAnswerBuilder.normalized(decision: "deny", answers: nil, reason: "nope")
        #expect(deny.decision == "deny")
        #expect(deny.answers == nil)
        #expect(bytes(deny) == #"{"decision":"deny","reason":"nope"}"#)

        let ask = AskAnswerBuilder.normalized(decision: "ask", answers: nil, reason: nil)
        #expect(ask.decision == "ask")
        #expect(ask.answers == nil)
        #expect(bytes(ask) == #"{"decision":"ask"}"#)
    }

    @Test("服务端兜底：answer 但一个键都没有 → deny（空回答不可能被发出去）")
    func emptyAnswersNeverLeaveAsAnswer() {
        let response = AskAnswerBuilder.normalized(decision: "answer", answers: [:], reason: nil)
        #expect(response.decision == AskAnswerBuilder.decisionDeny)
        #expect(response.answers == nil)
    }

    @Test("服务端兜底：answer 带「明确不选」照样发出")
    func explicitNoneSurvivesNormalization() {
        let response = AskAnswerBuilder.normalized(decision: "answer", answers: ["q1": []], reason: nil)
        #expect(response.decision == AskAnswerBuilder.decisionAnswer)
        #expect(response.answers == ["q1": []])
    }
}

@Suite("ask 选择状态")
struct AskSelectionTests {
    private func singleQuestion() -> AskQuestion {
        AskQuestion(
            id: "s1", question: "单选", options: [AskOption(label: "A"), AskOption(label: "B")])
    }

    /// 多选题夹具：`freeText` 与真实信封一致置真（omp 侧恒 true，Claude 侧本仓也置 true）。
    private func multiQuestion(_ id: String = "m1") -> AskQuestion {
        AskQuestion(
            id: id, question: "多选 \(id)", multiSelect: true, freeText: true,
            options: [AskOption(label: "X"), AskOption(label: "Y")])
    }

    @Test("多选题没勾选 = 零选：以空数组进字典（不是缺键）")
    func uncheckedMultiSelectIsZeroSelect() {
        let selection = AskSelection()
        #expect(selection.answers(for: [multiQuestion()])["m1"] == [])
    }

    @Test("单选没选中 = 未作答：不进字典（单选没有零选态）")
    func uncheckedSingleSelectIsMissing() {
        let selection = AskSelection()
        #expect(selection.answers(for: [singleQuestion()]).isEmpty)
    }

    @Test("全部都是多选时，零交互也能提交：未勾选的题即零选")
    func allMultiSelectCardIsSubmittableWithoutInteraction() {
        let selection = AskSelection()
        let questions = [multiQuestion("m1"), multiQuestion("m2")]
        #expect(selection.canSubmit(for: questions))
        let answers = selection.answers(for: questions)
        #expect(answers == ["m1": [], "m2": []])
        // 整单都是零选：仍然是 answer（不是 deny——deny 是「跳过 / 取消」，会终止本轮）
        #expect(AskAnswerBuilder.response(answers: answers).decision == AskAnswerBuilder.decisionAnswer)
    }

    @Test("含未选中的单选时不可提交；选中后即可（多选仍可留零选）")
    func singleSelectBlocksSubmitUntilAnswered() {
        var selection = AskSelection()
        let questions = [singleQuestion(), multiQuestion()]
        #expect(!selection.canSubmit(for: questions))

        selection.toggle("A", in: singleQuestion())
        #expect(selection.canSubmit(for: questions))
        #expect(selection.answers(for: questions) == ["s1": ["A"], "m1": []])

        // 取消勾选 → 又不可提交
        selection.toggle("A", in: singleQuestion())
        #expect(!selection.canSubmit(for: questions))
    }

    @Test("单选也能靠自由文本作答（等价于原生「Other」）")
    func singleSelectCanBeAnsweredWithText() {
        var selection = AskSelection()
        let question = AskQuestion(
            id: "s1", question: "单选", freeText: true,
            options: [AskOption(label: "A"), AskOption(label: "B")])
        #expect(!selection.canSubmit(for: [question]))
        selection.setFreeText("自己写一个", for: "s1")
        #expect(selection.canSubmit(for: [question]))
        #expect(selection.answers(for: [question])["s1"] == ["自己写一个"])
    }

    @Test("没有问题可答时不可提交（畸形负载的兜底）")
    func emptyQuestionListIsNotSubmittable() {
        #expect(!AskSelection().canSubmit(for: []))
    }

    @Test("多选普通作答按选项声明顺序收集")
    func multiSelectKeepsOptionOrder() {
        var selection = AskSelection()
        selection.toggle("Y", in: multiQuestion())
        selection.toggle("X", in: multiQuestion())
        #expect(selection.answers(for: [multiQuestion()])["m1"] == ["X", "Y"])
    }

    @Test("单选：换选即替换；再点一次取消 → 该题回到未作答")
    func singleSelectReplacesAndCanClear() {
        var selection = AskSelection()
        selection.toggle("A", in: singleQuestion())
        selection.toggle("B", in: singleQuestion())
        #expect(selection.answers(for: [singleQuestion()])["s1"] == ["B"])
        selection.toggle("B", in: singleQuestion())
        #expect(selection.answers(for: [singleQuestion()]).isEmpty)
    }

    @Test("零选与另一题正常作答并存：两条都在（wire 上分得开）")
    func zeroSelectCoexistsWithOtherAnswers() {
        var selection = AskSelection()
        selection.toggle("A", in: singleQuestion())
        let answers = selection.answers(for: [singleQuestion(), multiQuestion()])
        #expect(answers == ["s1": ["A"], "m1": []])
        #expect(
            AskAnswerBuilder.response(answers: answers).decision == AskAnswerBuilder.decisionAnswer)
    }

    @Test("hasInput 只反映「用户输入」，用于未勾选提示行")
    func hasInputReflectsSelectionOrText() {
        var selection = AskSelection()
        #expect(!selection.hasInput(in: multiQuestion()))
        selection.toggle("X", in: multiQuestion())
        #expect(selection.hasInput(in: multiQuestion()))
        selection.toggle("X", in: multiQuestion())
        #expect(!selection.hasInput(in: multiQuestion()))

        var typed = AskSelection()
        typed.setFreeText("   ", for: "m1")
        #expect(!typed.hasInput(in: multiQuestion()))
        typed.setFreeText(" 有字 ", for: "m1")
        #expect(typed.hasInput(in: multiQuestion()))
    }
}
