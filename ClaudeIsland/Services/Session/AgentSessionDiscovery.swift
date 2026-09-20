//
//  AgentSessionDiscovery.swift
//  ClaudeIsland
//
//  让 notch 认得「没有实时集成也在跑的会话」：定期扫描各 Agent 的记录目录
//  （或数据库），把最近有活动的会话登记进 SessionStore，并触发增量读取。
//
//  与实时集成的关系：
//    - 已安装集成（Claude hooks / pi 扩展 / opencode 插件）→ 事件由集成上报，
//      这里只负责把应用启动前就已存在的会话补进来，并驱动记录同步。
//    - 未安装集成 → 会话状态由记录内容推断（见 SessionStore.applyTranscriptActivity）。
//

import Foundation
import os.log

@MainActor
final class AgentSessionDiscovery {
    static let shared = AgentSessionDiscovery()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "Discovery")

    private var task: Task<Void, Never>?
    /// 已经登记过的会话，避免重复发送 SessionStart。
    private var knownKeys: Set<SessionKey> = []

    /// 轮询间隔（秒）。
    private let tickInterval: UInt64 = 4
    /// 记录在这么久内被写过，就认为会话还活着。
    private let liveWindow: TimeInterval = 120
    /// 只回看这么久内有过活动的会话。
    private let lookbackWindow: TimeInterval = 15 * 60
    /// 每个 Agent 每轮最多补登的会话数。
    private let perAgentLimit = 6
    /// 无实时集成的会话：记录超过这么久没有写入就回收（分钟级由日志体现）。
    private let discoveredSessionIdleTimeout: TimeInterval = 60 * 60

    // MARK: - 生命周期

    func start() {
        guard task == nil else { return }
        let interval = tickInterval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
        Self.logger.info("Started agent session discovery")
    }

    func stop() {
        task?.cancel()
        task = nil
        knownKeys.removeAll()
        Self.logger.info("Stopped agent session discovery")
    }

    // MARK: - 单轮扫描

    private func tick() async {
        let now = Date()
        // 只取进程名与 tty（不跑 lsof：每轮给每个进程解析 cwd 太贵，
        // 会话与进程的对应关系用「该 Agent 是否只有一个进程」来近似）。
        let processes = AgentProcessScanner.shared.processes()

        for kind in AgentRegistry.enabledAndInstalled {
            guard let source = AgentDiscoverySources.source(for: kind) else { continue }
            let agentProcesses = processes.filter { $0.agent == kind }
            let candidates = source.recentSessions(
                since: now.addingTimeInterval(-lookbackWindow),
                limit: perAgentLimit
            )

            for candidate in candidates {
                let recentlyWritten = candidate.updatedAt > now.addingTimeInterval(-liveWindow)
                // 该 Agent 只有一个进程时，把它当成这个会话的进程（用于 pid/tty 与终止回收）
                let soleProcess = agentProcesses.count == 1 ? agentProcesses[0] : nil
                let soleProcessMatch =
                    soleProcess != nil
                    && candidate.updatedAt > now.addingTimeInterval(-lookbackWindow)
                guard recentlyWritten || soleProcessMatch else { continue }

                let key = SessionKey(agent: kind, sessionId: candidate.sessionId)
                if !knownKeys.contains(key) {
                    knownKeys.insert(key)
                    Self.logger.info(
                        "Discovered \(kind.rawValue, privacy: .public) session in \(candidate.cwd, privacy: .public)"
                    )
                    await SessionStore.shared.process(
                        .hookReceived(Self.startEvent(candidate, process: soleProcess)))
                }
                await SessionStore.shared.pollSession(key: key, cwd: candidate.cwd)
            }

            await pruneSessions(agent: kind, hasProcesses: !agentProcesses.isEmpty, now: now)
        }
    }

    /// 回收已经从列表里消失或已经结束的会话。
    private func pruneSessions(agent: AgentKind, hasProcesses: Bool, now: Date) async {
        for key in Array(knownKeys) where key.agent == agent {
            guard let session = await SessionStore.shared.session(for: key) else {
                knownKeys.remove(key)
                continue
            }
            // 带 pid 的会话由 SessionStore 的周期检查按进程存活回收
            if session.pid != nil { continue }

            if !hasProcesses, session.lastActivity < now.addingTimeInterval(-liveWindow) {
                knownKeys.remove(key)
                await SessionStore.shared.process(.sessionEnded(key: key))
                continue
            }

            // 没有实时集成的会话拿不到进程存活信号：记录长时间没有新写入就视为结束，
            // 否则「CLI 一直开着、会话早已闲置」会让列表无限累积。
            // 用户下次继续该会话时记录会再次增长，会话会被重新发现。
            let lastWrite =
                session.transcriptPath
                .flatMap { TranscriptFileReader.modificationDate(of: URL(fileURLWithPath: $0)) }
                ?? session.lastActivity
            let idleMinutes = Int(discoveredSessionIdleTimeout / 60)
            if lastWrite < now.addingTimeInterval(-discoveredSessionIdleTimeout) {
                Self.logger.info(
                    "Session \(key.rawValue, privacy: .public) has no writes for \(idleMinutes)m, ending"
                )
                knownKeys.remove(key)
                await SessionStore.shared.process(.sessionEnded(key: key))
            }
        }
    }

    /// 构造补登会话用的启动事件。
    private static func startEvent(
        _ candidate: DiscoveredAgentSession,
        process: AgentProcess?
    ) -> HookEvent {
        HookEvent(
            sessionId: candidate.sessionId,
            cwd: candidate.cwd,
            event: "SessionStart",
            status: "idle",
            pid: process.map { Int($0.pid) },
            tty: process?.tty,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            agent: candidate.agent.rawValue,
            sessionFile: candidate.transcriptPath
        )
    }
}
