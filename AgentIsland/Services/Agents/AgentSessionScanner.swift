//
//  AgentSessionScanner.swift
//  AgentIsland
//
//  从磁盘记录目录里找出「最近有活动」的会话。各 Agent 的记录根深浅不一：
//  claude / pi 与 Claude fork 是 `<根>/<分桶>/<文件>.jsonl`（两层），
//  gemini / cursor / grok 是三层，codex 是 `sessions/YYYY/MM/DD/`（四层），
//  copilot 与 kimi 是一个会话多个文件。因此扫描泛化成「按 Provider 给的根 +
//  受限深度遍历 + 条目上限」；结构化存储（OpenCode）与索引式记录（Cline /
//  kimi-code）由各自的发现实现负责。
//

import Foundation
import os.log

/// 基于目录扫描的会话发现器。
nonisolated enum FileSessionScanner {
  private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Discovery")

  /// 一次扫描最多检查多少个目录条目。
  ///
  /// 记录根可能很久没清理（codex 的历史 rollout、Cline 的任务目录都会积累成千上万条），
  /// 所以遍历必须有硬上限：宁可少发现几个会话，也不要长跑到拖慢每 4 秒一轮的发现循环。
  private static let defaultEntryBudget = 4000

  /// 扫描会话记录目录，返回 `since` 之后有写入的会话（新→旧）。
  ///
  /// `depth` 说明「文件相对每个根目录位于第几层」：claude / pi 是 2，gemini / cursor /
  /// grok 是 3，codex 是 4。`provider` 负责判断文件是否属于它、把文件名解析成会话 id、
  /// 并读取文件里的 cwd；根目录不存在或深度不匹配时静默跳过（返回空）。
  static func recentSessions(
    roots: [URL],
    provider: any AgentProvider,
    since: Date,
    limit: Int,
    depth: ClosedRange<Int>,
    entryBudget: Int = FileSessionScanner.defaultEntryBudget
  ) -> [DiscoveredAgentSession] {
    let fm = FileManager.default
    var found: [DiscoveredAgentSession] = []
    var visited = 0

    func visit(_ directory: URL, level: Int) {
      guard level <= depth.upperBound, visited < entryBudget else { return }
      guard
        let entries = try? fm.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: .skipsHiddenFiles
        )
      else { return }

      for entry in entries {
        guard visited < entryBudget else { return }
        visited += 1
        if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          visit(entry, level: level + 1)
          continue
        }
        guard depth.contains(level),
          provider.isTranscriptFile(entry.path),
          let updatedAt = TranscriptFileReader.modificationDate(of: entry),
          updatedAt >= since,
          let sessionId = provider.sessionId(fromTranscriptFile: entry.path)
        else { continue }

        let cwd = (try? provider.cwd(fromTranscriptFile: entry.path)) ?? nil
        guard let cwd, !cwd.isEmpty else { continue }

        found.append(
          DiscoveredAgentSession(
            agent: provider.kind,
            sessionId: sessionId,
            cwd: cwd,
            title: nil,
            transcriptPath: entry.path,
            updatedAt: updatedAt
          ))
      }
    }

    for root in roots where visited < entryBudget {
      visit(root, level: 1)
    }

    // 一个会话可能有多个记录文件（copilot 的分区记录 `partition-<n>.jsonl`）：排序后
    // 按会话去重，保留最新的一条。
    var seen = Set<SessionKey>()
    return Array(
      found.sorted { $0.updatedAt > $1.updatedAt }
        .filter { seen.insert(SessionKey(agent: $0.agent, sessionId: $0.sessionId)).inserted }
        .prefix(limit)
    )
  }
}

// MARK: - Claude Code

extension ClaudeAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    FileSessionScanner.recentSessions(
      roots: [ClaudePaths.projectsDir],
      provider: self,
      since: since,
      limit: limit,
      depth: 2...2
    )
  }
}

// MARK: - pi 系

extension PiFamilyAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    guard let sessionsDir = paths()?.sessionsDir else { return [] }
    return FileSessionScanner.recentSessions(
      roots: [sessionsDir],
      provider: self,
      since: since,
      limit: limit,
      depth: 2...2
    )
  }
}

// MARK: - Claude fork（Qoder / Factory / CodeBuddy）

extension ClaudeFamilyAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    guard let sessionsDir = paths()?.sessionsDir else { return [] }
    return FileSessionScanner.recentSessions(
      roots: [sessionsDir],
      provider: self,
      since: since,
      limit: limit,
      depth: 2...2
    )
  }
}

// MARK: - Codex

extension CodexAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // 记录在 `sessions/YYYY/MM/DD/rollout-*.jsonl`：相对会话根是第四层。
    FileSessionScanner.recentSessions(
      roots: [sessionsRoot],
      provider: self,
      since: since,
      limit: limit,
      depth: 4...4
    )
  }
}

// MARK: - Gemini

extension GeminiAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // 记录在 `tmp/<项目目录>/chats/session-*.jsonl`：相对记录根是第三层。
    FileSessionScanner.recentSessions(
      roots: [recordsRoot],
      provider: self,
      since: since,
      limit: limit,
      depth: 3...3
    )
  }
}

// MARK: - Cursor

extension CursorAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // 记录在 `projects/<项目目录>/agent-transcripts/<会话目录>/<文件>.jsonl`：相对记录根
    // 是**第四层**（根下的项目目录是第 1 层）。更深一层的
    // `subagents/<子会话>.jsonl`（第 5 层）是父会话的派生记录，不作为独立会话发现。
    FileSessionScanner.recentSessions(
      roots: [recordsRoot],
      provider: self,
      since: since,
      limit: limit,
      depth: 4...4
    )
  }
}

// MARK: - Copilot

extension CopilotAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // 两代布局都是 `<会话根>/<会话 id>/<文件>`：当前版本是 `jb/`，旧版是
    // `session-state/`。同一会话的分区文件由扫描器按会话 id 去重。
    FileSessionScanner.recentSessions(
      roots: recordsRoots,
      provider: self,
      since: since,
      limit: limit,
      depth: 2...2
    )
  }
}

// MARK: - Kimi

extension KimiAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // kimi-code 的索引直接给出（会话 → 工作目录）映射，按它发现最准也最便宜。
    // 旧版 kimi-cli 的目录名是 `md5(cwd)`、无法反推工作目录，因此不参与磁盘发现
    // （那批会话只能由实时事件带来 cwd 之后建立）。
    let sessions = indexEntries().compactMap { entry -> DiscoveredAgentSession? in
      guard let updatedAt = sessionUpdatedAt(entry: entry), updatedAt >= since else {
        return nil
      }
      return DiscoveredAgentSession(
        agent: kind,
        sessionId: entry.sessionId,
        cwd: entry.workDir,
        title: nil,
        transcriptPath: transcriptFile(sessionId: entry.sessionId, cwd: entry.workDir)?.path,
        updatedAt: updatedAt
      )
    }
    return Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
  }

  /// 会话的活跃时间：正文、状态文件与目录三者取最新（写入顺序不固定）。
  private func sessionUpdatedAt(entry: IndexedSession) -> Date? {
    let candidates = [
      entry.sessionDir.appendingPathComponent("agents/main/wire.jsonl"),
      entry.sessionDir.appendingPathComponent("state.json"),
      entry.sessionDir,
    ]
    return candidates.compactMap(TranscriptFileReader.modificationDate(of:)).max()
  }
}

// MARK: - Cline

extension ClineAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // 任务索引一次给出全部任务的 cwd 与时间，比遍历 `tasks/` 目录更准也更快
    // （Cline 的任务目录会积累到上限，撞上遍历预算就会漏掉最近的会话）。
    let sessions = taskRecords().compactMap { record -> DiscoveredAgentSession? in
      guard !record.cwd.isEmpty else { return nil }
      let updatedAt = transcriptUpdatedAt(sessionId: record.id, cwd: record.cwd) ?? record.updatedAt
      guard let updatedAt, updatedAt >= since else { return nil }
      return DiscoveredAgentSession(
        agent: kind,
        sessionId: record.id,
        cwd: record.cwd,
        title: nil,
        transcriptPath: transcriptFile(sessionId: record.id, cwd: record.cwd)?.path,
        updatedAt: updatedAt
      )
    }
    return Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
  }

  /// 对话文件的 mtime 比索引里的 `ts` 准（CodeIsland 也用它判新鲜度）。
  private func transcriptUpdatedAt(sessionId: String, cwd: String) -> Date? {
    guard let file = transcriptFile(sessionId: sessionId, cwd: cwd) else { return nil }
    return TranscriptFileReader.modificationDate(of: file)
  }
}

// MARK: - Grok

extension GrokAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    // 记录在 `sessions/<编码 cwd>/<会话 id>/chat_history.jsonl`：相对会话根是第三层。
    FileSessionScanner.recentSessions(
      roots: [sessionsRoot],
      provider: self,
      since: since,
      limit: limit,
      depth: 3...3
    )
  }
}

// MARK: - 发现源查找

/// Agent → 会话发现实现的映射。
enum AgentDiscoverySources {
  /// 某个 Agent 的发现实现；只能靠实时事件的 Agent 为 nil。
  static func source(for kind: AgentKind) -> (any AgentSessionDiscoverySource)? {
    switch kind {
    case .claudeCode:
      return ClaudeAgentProvider()
    case .ohMyPi:
      return PiFamilyAgentProvider(kind: .ohMyPi)
    case .pi:
      return PiFamilyAgentProvider(kind: .pi)
    case .opencode:
      return OpenCodeSessionDiscovery()
    case .codex:
      return CodexAgentProvider()
    case .gemini:
      return GeminiAgentProvider()
    case .cursor:
      return CursorAgentProvider()
    case .copilot:
      return CopilotAgentProvider()
    case .qoder:
      return ClaudeFamilyAgentProvider(kind: .qoder)
    case .factory:
      return ClaudeFamilyAgentProvider(kind: .factory)
    case .codeBuddy:
      return ClaudeFamilyAgentProvider(kind: .codeBuddy)
    case .kimi:
      return KimiAgentProvider()
    case .cline:
      return ClineAgentProvider()
    case .grok:
      return GrokAgentProvider()
    case .trae, .traeCli, .deepSeekHarness:
      // 没有可解析的磁盘记录：会话只能由实时事件建立（进程扫描仍然生效）。
      return nil
    }
  }
}
