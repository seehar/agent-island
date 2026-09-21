//
//  SessionStoreReplayTests.swift
//  AgentIslandTests
//
//  用一串事件驱动真实的 SessionStore actor（所有状态变更的唯一入口），断言会话可被
//  观测到的状态：相位、实例信息、工具行状态与历史条数。
//  Services/State/SessionStore.swift 属并行会话的未提交改动，本文件只读该文件，
//  只钉稳定行为（相位转移、工具占位与收尾、审批链路、会话结束、历史落条）。
//

import Foundation
import Testing

//  说明：审批相关用例（approvalFlow / denialMarksToolError）暂时没有收录——
//  审批语义正被另一条并行改动线重做（待决许可的持有者从 SessionStore 移到 socket 层，
//  事件与键的形状都在变）。等那轮落定后按新语义补回来，好过现在把一套会过期的期望钉住。

@testable import AgentIsland

//  注意：`endedSessionHonoursRetentionWindow` 必须动 standard 偏好域（SessionStore 只读它），
//  因此本套件串行执行，避免与同套件里断言「结束即移除」的用例互相干扰。
@Suite("会话状态机回放", .serialized)
struct SessionStoreReplayTests {
    // MARK: - 夹具

    /// 每个用例用独立的会话 id 与目录，避免共享单例里的用例互相污染。
    private func makeSessionId(_ label: String) -> String { "test-\(label)-\(UUID().uuidString)" }

    private func makeCwd(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("island-store-\(label)-\(UUID().uuidString)").path
    }

    private func hook(
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil,
        pid: Int? = nil,
        tty: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId, cwd: cwd, event: event, status: status, pid: pid, tty: tty,
            tool: tool, toolInput: nil, toolUseId: toolUseId, notificationType: nil, message: nil,
            agent: "claude", sessionFile: nil)
    }

    // MARK: - 读状态的辅助（把可选项折成简单值，避免断言里出现可选比较）

    private func phaseEquals(_ session: SessionState?, _ expected: SessionPhase) -> Bool {
        guard let phase = session?.phase else { return false }
        return phase == expected
    }

    private func chatItemCount(_ session: SessionState?) -> Int { session?.chatItems.count ?? -1 }

    private func toolStatus(_ session: SessionState?, id: String) -> ToolStatus? {
        guard let session else { return nil }
        for item in session.chatItems where item.id == id {
            if case .toolCall(let tool) = item.type { return tool.status }
        }
        return nil
    }

    private func toolItem(_ session: SessionState?, id: String) -> ToolCallItem? {
        guard let session else { return nil }
        for item in session.chatItems where item.id == id {
            if case .toolCall(let tool) = item.type { return tool }
        }
        return nil
    }

    private func firstText(_ session: SessionState?) -> String? {
        guard let item = session?.chatItems.first else { return nil }
        if case .user(let text) = item.type { return text }
        return nil
    }

    // MARK: - 用例

    @Test("启动事件建立会话并进入处理中")
    func startEventCreatesProcessingSession() async {
        let sessionId = makeSessionId("start")
        let cwd = makeCwd("start")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))

        let session = await SessionStore.shared.session(for: key)
        #expect(session != nil)
        #expect(phaseEquals(session, .processing))
        #expect(session?.projectName == URL(fileURLWithPath: cwd).lastPathComponent)
        #expect(session?.sessionId == sessionId)
        #expect(session?.agent == AgentKind.claudeCode)

        await SessionStore.shared.process(.sessionEnded(key: key))
        let afterEnd = await SessionStore.shared.session(for: key)
        #expect(afterEnd == nil)
    }

    @Test("ttys 路径去掉 /dev/ 前缀，pid 被记录且非 tmux 进程不被误判")
    func instanceMetadataIsNormalized() async {
        let sessionId = makeSessionId("meta")
        let cwd = makeCwd("meta")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(
                hook(
                    sessionId: sessionId, cwd: cwd, event: "UserPromptSubmit", status: "processing",
                    pid: 1, tty: "/dev/ttys004")))

        let session = await SessionStore.shared.session(for: key)
        #expect(session?.tty == "ttys004")
        #expect(session?.pid == 1)
        #expect(session?.isInTmux == false)

        await SessionStore.shared.process(.sessionEnded(key: key))
    }

    @Test("PreToolUse 建工具占位行，PostToolUse 置为成功且不新增行")
    func toolPlaceholderLifecycle() async {
        let sessionId = makeSessionId("tool")
        let cwd = makeCwd("tool")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        await SessionStore.shared.process(
            .hookReceived(
                hook(
                    sessionId: sessionId, cwd: cwd, event: "PreToolUse", status: "running_tool",
                    tool: "Bash", toolUseId: "tool-1")))

        var session = await SessionStore.shared.session(for: key)
        #expect(chatItemCount(session) == 1)
        #expect(toolStatus(session, id: "tool-1") == ToolStatus.running)
        #expect(toolItem(session, id: "tool-1")?.name == "Bash")

        await SessionStore.shared.process(
            .hookReceived(
                hook(
                    sessionId: sessionId, cwd: cwd, event: "PostToolUse", status: "waiting_for_input",
                    tool: "Bash", toolUseId: "tool-1")))

        session = await SessionStore.shared.session(for: key)
        #expect(chatItemCount(session) == 1)
        #expect(toolStatus(session, id: "tool-1") == ToolStatus.success)
        #expect(phaseEquals(session, .waitingForInput))

        await SessionStore.shared.process(.sessionEnded(key: key))
    }



    @Test("Stop 事件把会话置为等待输入")
    func stopEventMarksWaitingForInput() async {
        let sessionId = makeSessionId("stop")
        let cwd = makeCwd("stop")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "Stop", status: "waiting_for_input")))

        let session = await SessionStore.shared.session(for: key)
        #expect(phaseEquals(session, .waitingForInput))
        let hasActivePermission = await SessionStore.shared.hasActivePermission(key: key)
        #expect(hasActivePermission == false)

        await SessionStore.shared.process(.sessionEnded(key: key))
    }

    @Test("非法相位转移被忽略：新建会话不会被等待输入事件直接拉走")
    func illegalTransitionIsIgnored() async {
        let sessionId = makeSessionId("illegal")
        let cwd = makeCwd("illegal")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        // 会话刚建出来是空闲态，空闲 -> 等待输入不在合法转移表里，因此相位保持空闲
        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "Stop", status: "waiting_for_input")))

        let session = await SessionStore.shared.session(for: key)
        #expect(session != nil)
        #expect(phaseEquals(session, .idle))

        await SessionStore.shared.process(.sessionEnded(key: key))
    }

    @Test("立即档（默认）：status=ended 的 hook 事件直接移除会话")
    func endedStatusRemovesSession() async {
        let sessionId = makeSessionId("ended")
        let cwd = makeCwd("ended")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        let afterStart = await SessionStore.shared.session(for: key)
        #expect(afterStart != nil)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionEnd", status: "ended")))

        let session = await SessionStore.shared.session(for: key)
        #expect(session == nil)
    }

    @Test("保留档：结束的会话标成已结束留在列表里，切回立即档才移除")
    func endedSessionHonoursRetentionWindow() async {
        let sessionId = makeSessionId("retention")
        let cwd = makeCwd("retention")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        // SessionStore 从 standard 偏好域读档位，这里必须动真实域，跑完立刻还原。
        let original = PreferenceStore.read(SessionRetention.self)
        PreferenceStore.write(SessionRetention.tenMinutes, defaults: .standard)
        defer { PreferenceStore.write(original, defaults: .standard) }

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionEnd", status: "ended")))

        let ended = await SessionStore.shared.session(for: key)
        #expect(ended != nil)
        #expect(phaseEquals(ended, .ended))

        // 紧随其后的内部结束事件不该把已结束的会话又删掉或改回别的相位
        await SessionStore.shared.process(.sessionEnded(key: key))
        let afterEvent = await SessionStore.shared.session(for: key)
        #expect(phaseEquals(afterEvent, .ended))

        // 立即档：结束就是移除（默认档，也是改造前的行为）
        PreferenceStore.write(SessionRetention.immediate, defaults: .standard)
        await SessionStore.shared.process(.sessionEnded(key: key))
        let afterImmediate = await SessionStore.shared.session(for: key)
        #expect(afterImmediate == nil)
    }

    @Test("已结束的会话被新一轮活动复活（--resume 用同一个会话 id）")
    func endedSessionRevivesOnNewActivity() async {
        let sessionId = makeSessionId("revive")
        let cwd = makeCwd("revive")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        let original = PreferenceStore.read(SessionRetention.self)
        PreferenceStore.write(SessionRetention.tenMinutes, defaults: .standard)
        defer { PreferenceStore.write(original, defaults: .standard) }

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionEnd", status: "ended")))
        #expect(phaseEquals(await SessionStore.shared.session(for: key), .ended))

        // 同一会话 id 又有活动：不能被终态卡住，要回到处理中
        await SessionStore.shared.process(
            .hookReceived(
                hook(sessionId: sessionId, cwd: cwd, event: "UserPromptSubmit", status: "processing")))
        let revived = await SessionStore.shared.session(for: key)
        #expect(revived != nil)
        #expect(phaseEquals(revived, .processing))

        await SessionStore.shared.process(.sessionEnded(key: key))
    }

    @Test("已结束会话按保留窗口收割：窗口内留下、超窗移除、非结束相位不看窗口")
    func endedSessionsAreCollectedByWindow() {
        let now = Date()
        let justEnded = now
        let longAgo = now.addingTimeInterval(-11 * 60)

        #expect(
            SessionStore.shouldDropEndedSession(
                phase: .ended, lastActivity: justEnded, retention: .tenMinutes, now: now) == false)
        #expect(
            SessionStore.shouldDropEndedSession(
                phase: .ended, lastActivity: longAgo, retention: .tenMinutes, now: now))
        #expect(
            SessionStore.shouldDropEndedSession(
                phase: .ended, lastActivity: longAgo, retention: .immediate, now: now))
        #expect(
            SessionStore.shouldDropEndedSession(
                phase: .processing, lastActivity: longAgo, retention: .tenMinutes, now: now) == false)
    }

    @Test("记录新增的消息进入会话历史")
    func fileUpdateAppendsMessages() async {
        let sessionId = makeSessionId("file")
        let cwd = makeCwd("file")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        #expect(chatItemCount(await SessionStore.shared.session(for: key)) == 0)

        let message = ChatMessage(id: "m1", role: .user, timestamp: Date(), content: [.text("你好")])
        let payload = FileUpdatePayload(
            key: key, cwd: cwd, messages: [message], isIncremental: true, completedToolIds: [],
            toolResults: [:], structuredResults: [:])
        await SessionStore.shared.process(.fileUpdated(payload))

        let session = await SessionStore.shared.session(for: key)
        #expect(chatItemCount(session) == 1)
        #expect(firstText(session) == "你好")

        await SessionStore.shared.process(.sessionEnded(key: key))
    }

    @Test("工具完成事件写入结果，重复上报不会覆盖首次结果")
    func toolCompletionIsWrittenOnce() async {
        let sessionId = makeSessionId("complete")
        let cwd = makeCwd("complete")
        let key = SessionKey(agent: .claudeCode, sessionId: sessionId)

        await SessionStore.shared.process(
            .hookReceived(hook(sessionId: sessionId, cwd: cwd, event: "SessionStart", status: "starting")))
        await SessionStore.shared.process(
            .hookReceived(
                hook(
                    sessionId: sessionId, cwd: cwd, event: "PreToolUse", status: "running_tool",
                    tool: "Bash", toolUseId: "tool-1")))

        await SessionStore.shared.process(
            .toolCompleted(
                key: key, toolUseId: "tool-1",
                result: ToolCompletionResult(status: .error, result: "boom", structuredResult: nil)))

        var session = await SessionStore.shared.session(for: key)
        #expect(toolStatus(session, id: "tool-1") == ToolStatus.error)
        #expect(toolItem(session, id: "tool-1")?.result == "boom")

        // 重复上报（这次是成功）不该覆盖已经落定的结果
        await SessionStore.shared.process(
            .toolCompleted(
                key: key, toolUseId: "tool-1",
                result: ToolCompletionResult(status: .success, result: "ok", structuredResult: nil)))

        session = await SessionStore.shared.session(for: key)
        #expect(toolStatus(session, id: "tool-1") == ToolStatus.error)
        #expect(toolItem(session, id: "tool-1")?.result == "boom")
        #expect(chatItemCount(session) == 1)

        await SessionStore.shared.process(.sessionEnded(key: key))
    }
}
