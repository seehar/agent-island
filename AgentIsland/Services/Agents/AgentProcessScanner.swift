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
          Self.matches($0, executable: executable, command: comm)
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
  ///
  /// 判据不依赖实例状态，故做成 `nonisolated static` 的静态入口，供用例直调
  /// （用例只钉判据本身，不用造真进程）。
  nonisolated static func matches(_ agent: AgentKind, executable: String, command: String) -> Bool {
    // 没有 CLI 的 Agent（Cline）`binaryName` 是空串：不加这个守卫，空的 `comm`
    // 会被判成它。
    if !agent.binaryName.isEmpty, executable == agent.binaryName { return true }
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
    case .cline:
      // Cline 是 VSCode 扩展：没有独立 CLI 进程，永不匹配（也不认 VSCode 主进程）。
      return false
    case .cursor:
      // CLI 是 `cursor-agent`；IDE 本体的主二进制是 `Cursor`（只认 `Contents/MacOS/`
      // 下的主二进制，理由同 `.trae`）。判据取自 CodeIsland 的 findCursorPids
      //   （Sources/CodeIsland/AppState.swift:4432-4442）。
      return command.contains("cursor-agent")
        || command.lowercased().contains("/cursor.app/contents/macos/cursor")
    case .trae:
      // Trae 是 IDE：CLI 的可执行名是 `coco`（`binaryName`），而 IDE 本体的可执行
      // 文件叫 `Trae`。只认 `coco` 的话 IDE 会话拿不到 pid，永远不会因「进程退出」被
      // 回收（只能等空闲超时）。应用包路径判据取自 CodeIsland 的 findTraePids /
      // findTraeCNPids（Sources/CodeIsland/AppState.swift:4563-4593，那边同样先
      // lowercased 再比较）：国际版 `<bundle>/Contents/MacOS/Trae`（:4566），国内版
      // `traecn.app` / `trae-cn.app` 的 `Contents/MacOS/Trae`（:4581-4582），再补上
      // 国内版真实的包名 `Trae CN.app`。
      // 只认 `Contents/MacOS/` 下的主二进制，不认 `Contents/Frameworks/* Helper`：
      // 辅助进程随窗口结束就退出，且发现器要求「该 Agent 只有一个进程」才关联
      // pid（AgentSessionDiscovery.tick 的 soleProcess）——多认一个辅助进程反而会
      // 让关联整个失效。
      let lowered = command.lowercased()
      return command.contains("coco")
        || lowered.contains("/trae.app/contents/macos/trae")
        || lowered.contains("/trae cn.app/contents/macos/")
        || lowered.contains("/trae-cn.app/contents/macos/trae")
        || lowered.contains("/traecn.app/contents/macos/trae")
    case .qoder:
      // CLI 是 `qodercli`；IDE 本体的主二进制按包名分两代：Qoder IDE 1.25.1 把 bundle
      // `Qoder.app` → `Qoder IDE.app`、可执行文件 `Electron` → `Qoder`（见 CodeIsland
      // 引入该判据的提交 3e2b467）。上游 findQoderPids 用的是包目录前缀
      // `/qoder.app/contents/`、`/qoder ide.app/contents/`（AppState.swift:4460-4466，
      // 前缀表在 :630-633）——那会把 `Contents/Frameworks/` 里的 Qoder Helper 一起认进来，
      // 这里按主二进制收窄到 `contents/macos/<主二进制名>`（理由同 `.trae`）。
      let lowered = command.lowercased()
      return command.contains("qodercli")
        || lowered.contains("/qoder.app/contents/macos/electron")
        || lowered.contains("/qoder ide.app/contents/macos/qoder")
    case .kimi:
      return command.contains("/kimi") || command.contains("kimi-cli")
        || command.contains("kimi_cli")
    case .factory:
      // CLI 是 `droid`（`binaryName`）；IDE 本体的主二进制是 Electron 默认名，判据取自
      // CodeIsland 的 findFactoryPids（Sources/CodeIsland/AppState.swift:4506-4513）的
      // `/factory.app/contents/macos/electron`（同样只认主二进制，理由同 `.trae`）。
      return command.contains("/droid")
        || command.lowercased().contains("/factory.app/contents/macos/electron")
    case .codex, .gemini, .copilot, .codeBuddy, .grok, .traeCli, .deepSeekHarness:
      // 这几个 CLI 以真实可执行文件运行，`ps` 的 `comm` 就是它的启动路径：
      // 名字完整时上面的快路径已命中，这里再认「路径里含 /<二进制名>」。
      return command.contains("/\(agent.binaryName)")
    case .hermes:
      // **不能**套上面那条通用判据（`command.contains("/hermes")`）：Hermes 的
      // `hermes` 是 bash 启动器（`~/.local/bin/hermes`，内容只有 `exec
      // <hermesHome>/hermes-agent/venv/bin/hermes "$@"`），真正长命的进程是它 exec 到的
      // **Python 控制台脚本**；而它的常驻 gateway
      // （`…/venv/bin/python -m hermes_cli.main gateway run --replace`）与
      // `tools/mcp_stdio_watchdog.py` 子进程的路径里同样含 `/hermes` —— 本机实测同一
      // 时刻有 4 个这样的常驻进程命中。多命中会让发现器的「该 Agent 只有一个进程」条件
      // 恒不成立（会话拿不到 pid，永不因进程退出回收），更糟的是可能把常驻 pid 当成会话
      // pid。因此只认「argv 的第二个 token 是 `…/bin/hermes` 控制台脚本」这一形态：
      // 实测真实进程为 `…/venv/bin/python3 …/venv/bin/hermes --version`（tokens[1] 即脚本
      // 路径），而 gateway 的 tokens[1] 是 `-m`、看门狗的 tokens[1] 是 `.py` 路径。
      let tokens = command.split(separator: " ")
      return tokens.count >= 2 && tokens[1].hasSuffix("/bin/hermes")
    }
  }
}
