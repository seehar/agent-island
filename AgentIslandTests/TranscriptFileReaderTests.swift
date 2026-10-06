//
//  TranscriptFileReaderTests.swift
//  AgentIslandTests
//
//  `TranscriptFileReader.firstRecordField` 是各 Provider 取 `cwd` / 会话 id 的唯一入口，
//  也是会话发现器判断「这条记录属于谁」的判据。它原来的实现只读固定 8 KB 前缀，再把整段
//  前缀当一个 UTF-8 字符串切行——两个缺陷都只在**首行很长**时暴露：
//    · 前缀切在半个 JSON 上 → 那一行解析不出来；
//    · 前缀切在半个多字节字符上 → 整段 `String(data:encoding:.utf8)` 直接返回 nil。
//  实测受影响的是 WorkBuddy / CodeBuddy（把整段注入上下文写成第一条 user 消息，首行 14 KB）：
//  `cwd` 取不到 ⇒ 会话在发现器里被**静默跳过**，面板里一条都没有。
//  这里的用例按这两个缺陷各钉一条，外加「预算耗尽不许无限读」的边界。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("记录头部读取")
struct TranscriptFileReaderTests {
    /// 取 `cwd` 字段：与各 Provider 调用它的方式一致（`predicate` 认记录类型、`value` 取值）。
    private func cwd(
        in file: URL, predicate: @escaping ([String: Any]) -> Bool = { $0["cwd"] != nil }
    )
        throws -> String?
    {
        try TranscriptFileReader.firstRecordField(
            in: file.path,
            predicate: predicate,
            value: { $0["cwd"] as? String })
    }

    private func makeDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return AgentProviderRoot.canonical(raw)
    }

    @Test("首行远大于一次读取量时不被截断：cwd 照样取得到")
    func oversizedFirstLineIsReadWhole() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // WorkBuddy / CodeBuddy 的首行就是这种形状：一条 user 消息里塞进整段注入上下文
        // （身份文件 + 工作区说明），实测 14 896 字节。
        let injected = String(repeating: "上下文 ", count: 3_000)
        let line =
            #"{"id":"a1","timestamp":1,"type":"message","role":"user","content":[{"type":"input_text","text":"\#(injected)"}],"sessionId":"s1","cwd":"/Users/tester/work/demo"}"#
        #expect(line.utf8.count > TranscriptFileReader.headerPrefixBytes, "夹具首行必须超过一次读取量")
        let file = directory.appendingPathComponent("s1.jsonl")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(try cwd(in: file) == "/Users/tester/work/demo")
    }

    @Test("首行里被切碎的多字节字符不会让整段解析失败")
    func splitMultibyteCharacterInFirstLineIsSurvivable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 让首行的字节数刚好落在「切点踩中中文字符中间」的区间上：整段前缀按 UTF-8 解码会
        // 失败（老实现因此连后面的行都看不到）。这里造多个候选长度，逐个都必须过。
        let file = directory.appendingPathComponent("s2.jsonl")
        for padding in 0..<8 {
            let injected = String(repeating: "中", count: 2_800 + padding * 700)
            let line =
                #"{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(injected)"}],"sessionId":"s2","cwd":"/Users/tester/work/demo"}"#
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            #expect(
                try cwd(in: file) == "/Users/tester/work/demo", "首行 \(line.utf8.count) 字节时取不到 cwd")
        }
    }

    @Test("超长首行不妨碍读它后面的行")
    func linesAfterAVeryLongLineAreStillRead() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 首行 200 KB 且 predicate 不认：必须在它之后继续往后读、找到第二条记录
        // （老实现只读前 8 KB，第二行根本进不了视野）。
        let unrecognized =
            "{\"type\":\"blob\",\"note\":\"" + String(repeating: "x", count: 200_000) + "\"}"
        let wanted =
            #"{"type":"message","role":"user","sessionId":"s3","cwd":"/Users/tester/work/after"}"#
        let file = directory.appendingPathComponent("s3.jsonl")
        try (unrecognized + "\n" + wanted + "\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(
            try cwd(in: file, predicate: { $0["type"] as? String == "message" })
                == "/Users/tester/work/after")
    }

    @Test("文件尾没有换行的那一行也按一行处理")
    func trailingLineWithoutNewlineIsStillRead() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("s4.jsonl")
        try #"{"type":"message","sessionId":"s4","cwd":"/Users/tester/work/tail"}"#
            .write(to: file, atomically: true, encoding: .utf8)

        #expect(try cwd(in: file) == "/Users/tester/work/tail")
    }

    @Test("找不到就返回空：不匹配的记录、超出预算的超长行都不会给假答案")
    func missingOrBudgetExceededReturnsNil() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 没有任何一条记录带 cwd。
        let noMatch = directory.appendingPathComponent("s5.jsonl")
        try (#"{"type":"ai-title","aiTitle":"无 cwd"}"# + "\n").write(
            to: noMatch, atomically: true, encoding: .utf8)
        #expect(try cwd(in: noMatch) == nil)

        // 单行就超过总预算（且没有换行）：必须有界地放弃，而不是一直读下去。
        let tooLong = directory.appendingPathComponent("s6.jsonl")
        let giant =
            "{\"type\":\"message\",\"cwd\":\"/Users/tester/work/giant\",\"pad\":\""
            + String(repeating: "x", count: TranscriptFileReader.headerReadBudgetBytes + 4_096)
            + "\"}"
        try giant.write(to: tooLong, atomically: true, encoding: .utf8)
        #expect(try cwd(in: tooLong) == nil)

        // 空文件同样返回空（不能因为读到 0 字节就崩或死循环）。
        let empty = directory.appendingPathComponent("s7.jsonl")
        try Data().write(to: empty)
        #expect(try cwd(in: empty) == nil)
    }
}
