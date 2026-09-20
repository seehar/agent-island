//
//  AgentProcessScanner.swift
//  AgentIsland
//
//  扫描正在运行的 Agent CLI 进程，用于把「由记录发现的会话」关联到 pid/tty，
//  并在 CLI 退出后回收这些会话。
//

import Foundation
import os.log

/// 一个正在运行的 Agent CLI 进程。
nonisolated struct AgentProcess: Sendable, Equatable {
  let agent: AgentKind
  let pid: Int32
  /// 去掉 `/dev/` 前缀的短 tty 名，与 `SessionState.tty` 保持一致。
  let tty: String?
}

/// 通过 `ps` 查找运行中的 Agent CLI。结果短期缓存，使每次发现扫描只产生
/// 一个子进程，而不是每个会话一个。
final class AgentProcessScanner: @unchecked Sendable {
  static let shared = AgentProcessScanner()

  private let lock = NSLock()
  private var cached: [AgentProcess] = []
  private var cachedAt: Date = .distantPast
  private let ttl: TimeInterval = 2

  private init() {}

  /// 所有已知 Agent 的进程列表，最多每 TTL 秒刷新一次。
  func processes() -> [AgentProcess] {
    lock.lock()
    let fresh = Date().timeIntervalSince(cachedAt) < ttl
    let cachedProcesses = cached
    lock.unlock()
    if fresh {
      return cachedProcesses
    }

    let scanned = scan()
    lock.lock()
    cached = scanned
    cachedAt = Date()
    lock.unlock()
    return scanned
  }

  /// 单个 Agent 的进程列表。
  func processes(for agent: AgentKind) -> [AgentProcess] {
    processes().filter { $0.agent == agent }
  }

  // MARK: - 扫描实现

  private func scan() -> [AgentProcess] {
    let result = ProcessExecutor.shared.runSync(
      "/bin/ps",
      arguments: ["-Ao", "pid=,tty=,comm="]
    )
    guard case .success(let output) = result else { return [] }
    return parsePS(output)
  }

  /// 解析 `ps` 输出的 `pid tty comm` 行。
  private func parsePS(_ output: String) -> [AgentProcess] {
    var found: [AgentProcess] = []
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 3,
        let pid = Int32(fields[0])
      else { continue }

      let ttyField = String(fields[1])
      let tty = (ttyField == "?" || ttyField == "-" || ttyField.isEmpty) ? nil : ttyField
      // `comm` 理论上可能含空格，这里把剩余字段重新拼起来。
      let comm = fields[2...].joined(separator: " ")
      let executable = (comm as NSString).lastPathComponent

      guard
        let agent = AgentKind.allCases.first(where: {
          matches($0, executable: executable, command: comm)
        })
      else {
        continue
      }
      found.append(AgentProcess(agent: agent, pid: pid, tty: tty))
    }
    return found
  }

  /// 进程名经常被截断或改写（pi 实际以 node 运行），因此同时匹配可执行名
  /// 和磁盘上的启动路径。
  private func matches(_ agent: AgentKind, executable: String, command: String) -> Bool {
    if executable == agent.binaryName { return true }
    switch agent {
    case .claudeCode:
      return command.contains("/claude") && !command.contains("agent-island")
    case .ohMyPi:
      return executable == "bun" || command.contains("/.omp/") || command.contains("/bin/omp")
    case .pi:
      return command.contains("/bin/pi") || command.contains("pi-coding-agent")
        || command.contains("/@earendil-works/")
    case .opencode:
      return command.contains("/opencode/") || command.contains("/bin/opencode")
    }
  }
}
