//
//  AgentSessionScanner.swift
//  ClaudeIsland
//
//  从磁盘记录目录里找出「最近有活动」的会话。Claude Code 与 pi 系都把会话
//  写成 `<会话根>/<按项目分桶>/<会话文件>.jsonl`，因此共用同一套扫描逻辑；
//  OpenCode 的结构化存储由它自己的发现实现负责。
//

import Foundation
import os.log

/// 基于目录扫描的会话发现器。
nonisolated enum FileSessionScanner {
  private static let logger = Logger(subsystem: "com.claudeisland", category: "Discovery")

  /// 扫描会话根目录，返回 `since` 之后有写入的会话（新→旧）。
  ///
  /// 目录结构固定为两层：`<root>/<分桶>/<文件>`。`provider` 负责把文件名
  /// 解析成会话 id、并读取文件里的 cwd。
  static func recentSessions(
    roots: [URL],
    provider: any AgentProvider,
    since: Date,
    limit: Int
  ) -> [DiscoveredAgentSession] {
    let fm = FileManager.default
    var found: [DiscoveredAgentSession] = []

    for root in roots {
      guard
        let buckets = try? fm.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: .skipsHiddenFiles
        )
      else { continue }

      for bucket in buckets {
        guard (try? bucket.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
          continue
        }
        guard
          let files = try? fm.contentsOfDirectory(
            at: bucket,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
          )
        else { continue }

        for file in files {
          guard provider.isTranscriptFile(file.path),
            let updatedAt = TranscriptFileReader.modificationDate(of: file),
            updatedAt >= since,
            let sessionId = provider.sessionId(fromTranscriptFile: file.path)
          else {
            continue
          }

          let cwd = (try? provider.cwd(fromTranscriptFile: file.path)) ?? nil
          guard let cwd, !cwd.isEmpty else { continue }

          found.append(
            DiscoveredAgentSession(
              agent: provider.kind,
              sessionId: sessionId,
              cwd: cwd,
              title: nil,
              transcriptPath: file.path,
              updatedAt: updatedAt
            ))
        }
      }
    }

    return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
  }
}

// MARK: - Claude Code

extension ClaudeAgentProvider: AgentSessionDiscoverySource {
  func recentSessions(since: Date, limit: Int) -> [DiscoveredAgentSession] {
    FileSessionScanner.recentSessions(
      roots: [ClaudePaths.projectsDir],
      provider: self,
      since: since,
      limit: limit
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
      limit: limit
    )
  }
}

// MARK: - 发现源查找

/// Agent → 会话发现实现的映射。
enum AgentDiscoverySources {
  /// 某个 Agent 的发现实现；不支持时为 nil。
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
    }
  }
}
