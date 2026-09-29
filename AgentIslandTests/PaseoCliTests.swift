//
//  PaseoCliTests.swift
//  AgentIslandTests
//
//  Paseo 写入通道（`paseo terminal send-keys`）的两条可判定契约：
//
//  1. `PaseoCliInvocation` 的 argv 形状——它是与 `paseo` CLI 的唯一耦合面，参数错位或少了
//     尾部 `\r` 的表现都是「消息没发出去」（不是崩溃，所以只能靠断言钉住）。
//  2. `PaseoCliLocator` 的定位与搜索目录——GUI 进程的 PATH 里没有 node，定位失败＝发不出去；
//     而失败必须是 `nil`（界面据此报错），不能猜一个路径。
//
//  真实投递（daemon + pty）不在这里跑：那需要一个运行中的 Paseo daemon，
//  不适合作为常驻用例的依赖。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("Paseo CLI 调用形状")
struct PaseoCliInvocationTests {
    @Test("发送消息：字面写入 + 尾部 CR（＝键入 + 回车，一次调用）")
    func sendMessageArguments() {
        let arguments = PaseoCliInvocation.sendMessage(terminalId: "t-1", text: "hello")

        #expect(arguments == ["terminal", "send-keys", "--literal", "t-1", "--", "hello\r"])
        // 尾部 CR 就是「提交」本身（Paseo 的 `Enter` 令牌与 `write` 是同一个字节）：
        // 少了它，文本只会停在输入框里、没有任何报错。
        #expect(arguments.last == "hello\r")
    }

    @Test("以短横线开头的文本不被 CLI 当成选项")
    func sendMessageKeepsLeadingDashLiteral() {
        let arguments = PaseoCliInvocation.sendMessage(
            terminalId: "t-1", text: "-please-do-not-parse")

        // `--` 是唯一的分隔手段：没有它，commander 会把 `-please…` 当未知选项直接失败。
        #expect(arguments.contains("--"))
        #expect(arguments.last == "-please-do-not-parse\r")
    }

    @Test("中断走令牌解析（不加 --literal），下发 Ctrl-C 字节")
    func sendInterruptArguments() {
        let arguments = PaseoCliInvocation.sendInterrupt(terminalId: "t-1")

        #expect(arguments == ["terminal", "send-keys", "t-1", "C-c"])
        #expect(!arguments.contains("--literal"))
    }
}

@Suite("Paseo CLI 定位")
struct PaseoCliLocatorTests {
    /// 建一个「可执行的 paseo」。内容不重要（不执行它），但权限位必须可执行。
    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paseo-locator-\(UUID().uuidString)")
    }

    @Test("会话上报的路径优先（那是 Paseo 自己解析出的那一个）")
    func prefersReportedPath() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let reported = root.appendingPathComponent("pkg/bin/paseo")
        try makeExecutable(reported)
        let searched = root.appendingPathComponent("other")
        try makeExecutable(searched.appendingPathComponent("paseo"))

        #expect(
            PaseoCliLocator.executablePath(preferred: reported.path, searchPaths: [searched.path])
                == reported.path)
    }

    @Test("上报路径缺失或不可执行时退回搜索目录")
    func fallsBackToSearchPaths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appendingPathComponent("nvm/bin")
        let candidate = directory.appendingPathComponent("paseo")
        try makeExecutable(candidate)

        #expect(
            PaseoCliLocator.executablePath(preferred: nil, searchPaths: [directory.path])
                == candidate.path)
        #expect(
            PaseoCliLocator.executablePath(
                preferred: root.appendingPathComponent("gone/paseo").path,
                searchPaths: [directory.path])
                == candidate.path)
    }

    @Test("找不到就是 nil——界面据此报「发不出去」，不能瞎猜路径")
    func missingIsNil() {
        #expect(
            PaseoCliLocator.executablePath(
                preferred: nil, searchPaths: ["/nonexistent-dir-for-paseo-test"]) == nil)
        #expect(
            PaseoCliLocator.executablePath(
                preferred: "/nonexistent-dir-for-paseo-test/paseo", searchPaths: []) == nil)
    }

    @Test("搜索目录含 CLI 自身目录、用户 PATH、各 nvm 版本与常见安装位置，且去重")
    func searchDirectoriesComposition() throws {
        let home = temporaryRoot().appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

        for version in ["v9.11.2", "v22.21.1", "v18.0.0"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"),
                withIntermediateDirectories: true)
        }

        let directories = PaseoCliLocator.searchDirectories(
            cliPath: "/opt/tools/bin/paseo", home: home.path, envPath: "/usr/bin:/bin:/usr/bin")

        #expect(directories.first == "/opt/tools/bin")
        #expect(directories.contains("/usr/bin"))
        #expect(directories.contains("/opt/homebrew/bin"))
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)

        // 数值降序：字典序会把 v9 排到 v22 前面，导致 shebang 用更老的 node 跑 CLI。
        let nvmOrder = directories.compactMap { directory -> String? in
            guard let range = directory.range(of: ".nvm/versions/node/") else { return nil }
            return String(directory[range.upperBound...].prefix(while: { $0 != "/" }))
        }
        #expect(nvmOrder == ["v22.21.1", "v18.0.0", "v9.11.2"])
    }
}
