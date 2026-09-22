//
//  UsageStatsIndexer.swift
//  AgentIsland
//
//  用量统计的索引器：把磁盘上的历史记录（四种 Agent）增量汇总进统计库，并向
//  UI 发布「索引已更新」的通知。
//
//  设计要点：
//    · 首轮要读全部历史的尾部（本机 JSONL 约 5 GB），因此整个扫描跑在**独立于
//      actor 的 utility 任务**里，分批进行、批间让出，不阻塞 UI 的查询；
//    · 统计库用两条连接：扫描侧写、UI 侧读（WAL 允许读写并发）；
//    · 每 60 秒一轮增量扫描；打开统计页可请求立即扫描（30 秒节流）；
//    · 统计页的「重新统计」按钮可手动触发一次全量重算（`rebuildNow()`）。
//
//  一轮增量的成本（本机 3 万个源、5 GB 记录实测）：枚举 + `stat` ≈ 0.3 s、读一次进度表
//  ≈ 0.02 s、OpenCode 三条查询 ≈ 0.1 s，没变化就不写库、也不在批间让出——空轮合计
//  约 0.4 s。真正的重活是首次回填与手动重算（全量读记录 + 重放）。
//
//  进度表按轮读一次后逐块复用（`ingest(sources:progress:rebuilding:)`）：快照必须显式
//  传进来，别在 pass 里缓存——同一个 pass 被调用多次时缓存会陈旧。
//
//  OpenCode 那一半先看指纹（库 + `-wal` 的 size/mtime）再决定扫不扫：它的两条增量查询
//  是全表扫描，冷缓存约 2 秒（采样实测），而库没被写过时注定查不出新数据。
//

import Combine
import Foundation
import os.log

/// 待扫描的记录根目录（测试可注入临时目录）。
nonisolated struct UsageScanRoots: Sendable {
  var jsonlRoots: [AgentKind: [URL]]
  var openCodeDatabase: URL?

  /// 当前机器上实际启用的 Agent 的记录位置。
  static var live: UsageScanRoots {
    var roots: [AgentKind: [URL]] = [:]
    for kind in AgentRegistry.enabled {
      guard let sessionsDir = AgentRegistry.provider(for: kind).paths()?.sessionsDir else {
        continue
      }
      roots[kind] = [sessionsDir]
    }

    let database = AgentRegistry.provider(for: .opencode).paths()?.dataDir?
      .appendingPathComponent("opencode.db")
    let databaseExists = database.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    return UsageScanRoots(
      jsonlRoots: roots, openCodeDatabase: databaseExists ? database : nil)
  }
}

/// 一轮 OpenCode 扫描后的结果。
nonisolated struct OpenCodeSweepOutcome: Equatable {
  /// 重放过的消息数。
  var messages = 0
  /// 还有没读完的页（单轮页数有上限）：下一轮不能拿「库没变化」当借口跳过。
  var morePagesRemain = false
}

/// 一批源索引后的结果。
nonisolated struct UsageIngestOutcome: Equatable {
  /// 跳过（读失败/写失败）的源数。
  var failures = 0
  /// 真正读或写过的源数：为 0 说明这一批只是 `stat` 了一圈，批间不必让出。
  var changed = 0
}

/// 一轮索引的具体执行体。同步接口，由索引器在后台任务里驱动，测试可直接调用。
nonisolated final class UsageStatsPass {
  private static let logger = Logger(
    subsystem: "com.celestial.AgentIsland", category: "UsageStats")

  private let store: UsageStatsStore
  private let calendar: Calendar
  private var openCodeReader: OpenCodeUsageReader?

  /// OpenCode 每页最多处理的消息数（首轮即是全量，之后每页只处理有更新的）。
  private let openCodeBatchLimit: Int

  init(store: UsageStatsStore, calendar: Calendar = .current, openCodeBatchLimit: Int = 4_000) {
    self.store = store
    self.calendar = calendar
    self.openCodeBatchLimit = openCodeBatchLimit
  }

  /// 索引一批 JSONL 记录，返回失败的源数量。
  ///
  /// 单源失败（库忙、磁盘满、文件读到一半消失）只跳过它自己：否则一次失败会中断整轮，
  /// 它后面的所有文件永远排不上队——页面会长期显示一份看起来正常、实则不全、且此后不再
  /// 长大的数字。
  ///
  /// - Parameter rebuilding: 手动「重新统计」：不认库里的读取进度，每个源都从头
  ///   重读一遍并整源重放。增量路径只读文件的尾巴，所以它是**唯一**能改掉已经
  ///   统计过的数字的路径（桶丢了、数字对不上时用）。
  ///
  /// - Parameter progress: 本轮开始时的读取进度快照（索引器每轮读一次并逐块复用：
  ///   本机 3 万个源逐个查是 0.31 s，一次读完约 0.02 s）。传 `nil` 表示「你自己现读
  ///   一份」——单次调用（测试、临时脚本）走这条，语义永远是新鲜的。
  @discardableResult
  func ingest(
    sources: [UsageSourceFile], progress: [String: UsageSourceRecord]? = nil,
    rebuilding: Bool = false
  ) -> UsageIngestOutcome {
    let previousBySource: [String: UsageSourceRecord]
    do {
      previousBySource = try progress ?? store.sourceRecords()
    } catch {
      Self.logger.error(
        "用量统计读进度表失败：\(String(describing: error), privacy: .public)")
      return UsageIngestOutcome(failures: sources.count)
    }

    var outcome = UsageIngestOutcome()
    for source in sources {
      do {
        let previous = rebuilding ? nil : previousBySource[source.path]
        let result = TranscriptUsageScanner.read(
          source: source, previous: previous?.state, calendar: calendar)

        // 重放：重算时无条件走这条（进度被丢弃，读到的就是全量）；增量时只在
        // 文件被截断 / 整体重写时走。
        if rebuilding || result.needsReplace {
          try store.replace(
            result.deltas, sourceId: source.path, agent: source.agent, state: result.state)
          outcome.changed += 1
          continue
        }

        // 没有任何变化就不写：避免每轮扫描都产生一次事务。这一支也是「空轮」的全部
        // 成本——一次 stat，连文件都不打开（见 `TranscriptUsageScanner.read`）。
        let unchanged =
          result.deltas.isEmpty
          && previous?.state.readOffset == result.state.readOffset
          && previous?.state.mtime == result.state.mtime
        if unchanged { continue }

        try store.append(
          result.deltas, sourceId: source.path, agent: source.agent, state: result.state)
        outcome.changed += 1
      } catch {
        outcome.failures += 1
        Self.logger.error(
          "用量统计：跳过 \(source.path, privacy: .public)（\(String(describing: error), privacy: .public)）"
        )
      }
    }
    return outcome
  }

  /// 索引 OpenCode 的历史（按消息增量）。
  ///
  /// 每轮最多读 `openCodeBatchIterations` 页；首次回填就是靠这一批批读完的
  /// （每页 4000 条），期间不会长时间占住 I/O。游标按页推进，**只认已处理过的
  /// 位置**，所以中途退出也不会丢消息。
  ///
  /// - Parameter rebuilding: 手动「重新统计」：游标归零、全库重走一遍。每条消息
  ///   在统计库里是独立数据源、按整源重放写库，因此重走是幂等的。
  @discardableResult
  func ingestOpenCode(
    databaseURL: URL, rebuilding: Bool = false
  ) throws -> OpenCodeSweepOutcome {
    var outcome = OpenCodeSweepOutcome()
    let reader: OpenCodeUsageReader
    if let openCodeReader {
      reader = openCodeReader
    } else {
      let created = try OpenCodeUsageReader(url: databaseURL)
      openCodeReader = created
      reader = created
    }

    let sweepId = Self.openCodeSweepId
    // 重算时丢掉游标（`parseCursors(nil)` 即全零）：从最早的消息重新走一遍。
    let storedCursor =
      rebuilding ? nil : try store.state(ofSource: sweepId)?.state.cursor
    var cursors = Self.parseCursors(storedCursor)
    let subagentSessions = try reader.subagentSessionIds()
    let now = Date().timeIntervalSince1970

    if rebuilding {
      // 归零的游标先落库：这一轮只跑了一半就退出时，下一轮仍从零继续，而不是
      // 从半途的游标往后走——那样游标之前的消息就再也回不到重算路径上了。
      try store.replace(
        [], sourceId: sweepId, agent: .opencode,
        state: UsageSourceState(cursor: Self.serializeCursors(cursors), updatedAt: now))
    }

    for _ in 0..<Self.openCodeBatchIterations {
      let page = try reader.dirtyMessages(
        messageCursor: cursors.message, partCursor: cursors.part,
        limit: openCodeBatchLimit)
      let advanced = page.messageCursor.isAfter(cursors.message)
        || page.partCursor.isAfter(cursors.part)

      var writes: [UsageSourceWrite] = []
      for messageId in page.messageIds {
        let deltas = try reader.contributions(
          messageId: messageId, subagentSessions: subagentSessions, calendar: calendar)
        // 没有 token 也没有工具调用的消息（用户消息）不入库。
        guard !deltas.isEmpty else { continue }
        writes.append(
          UsageSourceWrite(
            sourceId: Self.openCodeSourcePrefix + messageId, agent: .opencode, deltas: deltas,
            state: UsageSourceState(updatedAt: now)))
      }

      cursors = (page.messageCursor, page.partCursor)
      guard advanced || !page.messageIds.isEmpty else {
        // 这一页什么都没读到：追平了。收紧「还没读完」，否则指纹门会白扫一轮。
        outcome.morePagesRemain = false
        break
      }
      // 整页一个事务：这一页的消息重放与游标推进同生共死（崩在页面中间也不会留下
      // 「游标已过、消息没入库」的洞），实测比每条消息一个事务快一个量级。
      writes.append(
        UsageSourceWrite(
          sourceId: sweepId, agent: .opencode, deltas: [],
          state: UsageSourceState(cursor: Self.serializeCursors(cursors), updatedAt: now)))
      try store.replaceBatch(writes)
      outcome.messages += writes.count - 1  // 去掉这一页末尾的游标行
      // 页读满说明后面还有：记下来，别让下一轮的「库没变化」把它当成已经追平。
      outcome.morePagesRemain = page.isMessagePageFull || page.isPartPageFull

      if !page.isMessagePageFull && !page.isPartPageFull { break }
    }
    return outcome
  }

  private static let openCodeSweepId = "opencode:sweep"
  private static let openCodeSourcePrefix = "opencode:"
  /// 单轮扫描最多读多少页（首次回填因此分多轮完成）。
  private static let openCodeBatchIterations = 20

  private static func serializeCursors(
    _ cursors: (message: OpenCodeUsageCursor, part: OpenCodeUsageCursor)
  ) -> String {
    "m:\(cursors.message.timeUpdated):\(cursors.message.id)"
      + ";p:\(cursors.part.timeUpdated):\(cursors.part.id)"
  }

  private static func parseCursors(
    _ cursor: String?
  ) -> (message: OpenCodeUsageCursor, part: OpenCodeUsageCursor) {
    guard let cursor else { return (.empty, .empty) }
    var message = OpenCodeUsageCursor.empty
    var part = OpenCodeUsageCursor.empty
    for field in cursor.split(separator: ";") {
      let pieces = field.split(separator: ":", maxSplits: 2).map(String.init)
      guard pieces.count == 3, let timeUpdated = Int64(pieces[1]) else { continue }
      let value = OpenCodeUsageCursor(timeUpdated: timeUpdated, id: pieces[2])
      if pieces[0] == "m" { message = value }
      if pieces[0] == "p" { part = value }
    }
    return (message, part)
  }
}

/// 用量统计索引器。
actor UsageStatsIndexer {
  static let shared = UsageStatsIndexer()

  private static let logger = Logger(
    subsystem: "com.celestial.AgentIsland", category: "UsageStats")

  /// 周期增量扫描间隔（秒）。
  private static let sweepIntervalSeconds: UInt64 = 60
  /// 打开统计页触发的立即扫描的节流窗口（秒）。
  private static let refreshThrottleSeconds: TimeInterval = 30
  /// 「索引有更新」通知的最小间隔（秒）：见 `notifyProgress()`。
  private static let progressNotifyInterval: TimeInterval = 0.5
  /// 后台扫描每批处理的文件数，批间暂停以保持低占用。
  private static let passChunkFileLimit = 200
  private static let chunkPauseNanoseconds: UInt64 = 20_000_000

  private let databaseURL: URL
  private var readerStore: UsageStatsStore?
  private var passTask: Task<Void, Never>?
  private var periodicTask: Task<Void, Never>?
  private var pendingRefresh = false
  /// 下一轮扫描是否按「重新统计」的语义跑（见 `rebuildNow()`）。
  private var rebuildRequested = false
  private var lastProgressNotifyAt: Date?
  /// OpenCode 库上次扫描后的指纹（见 `OpenCodeDatabaseFingerprint`）。
  private var openCodeFingerprint: OpenCodeDatabaseFingerprint?
  /// 还没追平：首次扫描、上一轮没读完一页、或上次扫描失败时都要照常扫，不看指纹。
  private var openCodeCatchUpPending = true
  private var lastPassFinishedAt: Date?
  private(set) var isIndexing = false

  private nonisolated let updatesSubject = CurrentValueSubject<Void, Never>(())
  /// 索引更新通知：UI 收到后重新取快照即可。
  nonisolated var updatesPublisher: AnyPublisher<Void, Never> {
    updatesSubject.eraseToAnyPublisher()
  }

  init(databaseURL: URL = UsageStatsStore.defaultDatabaseURL) {
    self.databaseURL = databaseURL
  }

  // MARK: - 生命周期

  /// 启动索引：立即跑一轮，然后每 60 秒一轮增量。重复调用无副作用。
  func start() {
    guard periodicTask == nil else { return }
    runPass()

    let interval = Self.sweepIntervalSeconds
    periodicTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
        guard !Task.isCancelled else { break }
        await self?.runPass()
      }
    }
  }

  func stop() {
    periodicTask?.cancel()
    periodicTask = nil
    passTask?.cancel()
    passTask = nil
    isIndexing = false
    // 停掉时放弃还排着队的那一轮（含「重新统计」的请求）：下次启动不该莫名其妙地
    // 做一次全量重算。
    pendingRefresh = false
    rebuildRequested = false
  }

  /// 请求立即扫描一次（打开统计页时用）；30 秒内的重复请求只发一次通知。
  func refreshNow() {
    if isIndexing {
      pendingRefresh = true
      updatesSubject.send(())
      return
    }
    if let lastPassFinishedAt,
      Date().timeIntervalSince(lastPassFinishedAt) < Self.refreshThrottleSeconds
    {
      updatesSubject.send(())
      return
    }
    runPass()
  }

  /// 手动触发一次「重新统计历史」：让下一轮扫描把每个记录源从头重读一遍并整源
  /// 重放，绕过打开页面时的 30 秒节流（手动按钮的语义就是「现在就重算」）。
  /// 正在跑的那轮扫完接着跑，不会被打断；重复点击合并成一次（重算期间按钮禁用）。
  func rebuildNow() {
    rebuildRequested = true
    updatesSubject.send(())
    runPass()
  }

  // MARK: - 查询

  /// 取某个窗口的快照。
  func snapshot(for window: StatsWindow) async -> UsageStatsSnapshot {
    do {
      let store = try reader()
      return try store.snapshot(
        window: window, calendar: .current, now: Date(), isIndexing: isIndexing,
        indexedAt: lastPassFinishedAt)
    } catch {
      Self.logger.error("读取用量统计失败：\(String(describing: error), privacy: .public)")
      return UsageStatsSnapshot(window: window)
    }
  }

  // MARK: - 扫描

  private func runPass() {
    guard passTask == nil else {
      pendingRefresh = true
      return
    }
    // 重算语义只属于「这一轮」：下一轮恢复增量，否则每 60 秒都要重读一次全量。
    let rebuilding = rebuildRequested
    rebuildRequested = false

    isIndexing = true
    updatesSubject.send(())

    let databaseURL = databaseURL
    let calendar = Calendar.current
    let roots = UsageScanRoots.live
    let chunkLimit = Self.passChunkFileLimit
    let chunkPause = Self.chunkPauseNanoseconds
    // 跨轮状态在 actor 上，后台任务只能读快照、只能通过方法回写（见 finishOpenCodeSweep）。
    let openCodeFingerprintAtStart = openCodeFingerprint
    let openCodeCatchUpPendingAtStart = openCodeCatchUpPending

    passTask = Task.detached(priority: .utility) { [weak self] in
      let startedAt = Date()
      // 各阶段耗时：进摘要行（info，日志里查得到）。排查「一轮为什么这么久」时不必再插桩。
      var phaseSeconds: [String: TimeInterval] = [:]
      var phaseStart = startedAt
      func mark(_ phase: String) {
        let now = Date()
        phaseSeconds[phase, default: 0] += now.timeIntervalSince(phaseStart)
        phaseStart = now
      }
      do {
        let store = try UsageStatsStore(url: databaseURL)
        let pass = UsageStatsPass(store: store, calendar: calendar)
        mark("开库")

        var sources: [UsageSourceFile] = []
        for (kind, kindRoots) in roots.jsonlRoots {
          sources.append(contentsOf: TranscriptUsageScanner.sources(for: kind, roots: kindRoots))
        }
        mark("枚举")

        // 一轮读一次进度表：本机 3 万个源逐个查是 0.31 s，一次读完约 0.02 s。
        // 重建不看进度（`ingest` 里重建一律从零读），这份只为清理死源与逐块复用。
        let progress = (try? store.sourceRecords()) ?? [:]
        mark("读进度")

        var failures = 0
        var changed = 0
        var scanned = 0
        while scanned < sources.count {
          if Task.isCancelled { break }
          let end = min(scanned + chunkLimit, sources.count)
          let outcome = pass.ingest(
            sources: Array(sources[scanned..<end]), progress: rebuilding ? [:] : progress,
            rebuilding: rebuilding)
          failures += outcome.failures
          changed += outcome.changed
          scanned = end
          // 只有这一批真的读/写了才让出：一轮全是「没变化」的 stat 时不白等
          // （本机 25 批 × 20 ms ≈ 0.5 秒纯延迟），也不必让页面白重取快照。
          guard outcome.changed > 0 else { continue }
          await self?.notifyProgress()
          try? await Task.sleep(nanoseconds: chunkPause)
        }

        mark("扫记录")

        // 已经不存在于磁盘上的记录：清掉进度行（历史用量保留）。
        do {
          for sourceId in Self.missingSourceIds(progress: progress, sources: sources)
          {
            try store.forgetCursor(sourceId: sourceId)
          }
        } catch {
          failures += 1
          Self.logger.error("清理用量统计进度失败：\(String(describing: error), privacy: .public)")
        }

        mark("清理")

        var openCodeNote = "OpenCode 未启用"
        if let database = roots.openCodeDatabase {
          let fingerprint = OpenCodeDatabaseFingerprint.read(databaseURL: database)
          // 库与它的 -wal 都没被写过、且上一轮已经追平：跳过整轮 OpenCode 扫描。这两条
          // 查询在 message / part 上是全表扫描（本机 2.29 GB 库、冷缓存约 2 秒读盘），
          // 而 OpenCode 没在跑时它们永远查不出新东西。
          let canSkip =
            fingerprint != nil && fingerprint == openCodeFingerprintAtStart
            && !openCodeCatchUpPendingAtStart && !rebuilding
          if canSkip {
            openCodeNote = "OpenCode 跳过（库没有变化）"
            Self.logger.debug("用量统计：OpenCode 库没有变化，跳过这一轮扫描")
          } else {
            // 扫一轮时把当前指纹记下来：连续两行的差异就是「为什么没跳过」。
            Self.logger.debug(
              "用量统计：OpenCode 需要扫一轮（库有变化 / 还没追平 / 重建）：\(String(describing: fingerprint), privacy: .public)"
            )
            do {
              let sweep = try pass.ingestOpenCode(databaseURL: database, rebuilding: rebuilding)
              changed += sweep.messages
              openCodeNote = "OpenCode 扫 \(sweep.messages) 条"
              await self?.finishOpenCodeSweep(
                fingerprint: OpenCodeDatabaseFingerprint.read(databaseURL: database),
                morePagesRemain: sweep.morePagesRemain)
            } catch {
              // 失败后不靠指纹跳过：下一轮必须重试（库可能正被写、或权限/热点问题）。
              await self?.noteOpenCodeSweepFailed()
              openCodeNote = "OpenCode 失败"
              failures += 1
              Self.logger.error(
                "OpenCode 用量索引失败：\(String(describing: error), privacy: .public)")
            }
          }
        }

        // 索引到底多贵，留一条可查的事实。两档：真干活/失败/重算时进持久日志（`info`），
        // 空轮只进内存日志（`debug`，`log show --debug` 可见）——空轮每分钟一条，别把
        // 持久日志灌满，但排查性能时又得量得到。
        mark("OpenCode")
        let elapsed = Date().timeIntervalSince(startedAt)
        let phase = rebuilding ? "（全量重算）" : ""
        let breakdown = ["开库", "枚举", "读进度", "扫记录", "清理", "OpenCode"]
          .map { "\($0) \(Int((phaseSeconds[$0] ?? 0) * 1000))" }
          .joined(separator: " / ")
        // 两档共用同一句文案，但 `Logger` 只吃字面插值（没法先把摘要拼成 String），所以
        // 这里只能各写一遍。
        if changed > 0 || failures > 0 || rebuilding || elapsed >= 2 {
          Self.logger.info(
            "用量统计本轮：源 \(scanned, privacy: .public)，写 \(changed, privacy: .public)，跳过 \(failures, privacy: .public)，用时 \(Int(elapsed * 1000), privacy: .public) ms\(phase, privacy: .public)，\(openCodeNote, privacy: .public)｜\(breakdown, privacy: .public)"
          )
        } else {
          Self.logger.debug(
            "用量统计本轮：源 \(scanned, privacy: .public)，写 \(changed, privacy: .public)，跳过 \(failures, privacy: .public)，用时 \(Int(elapsed * 1000), privacy: .public) ms\(phase, privacy: .public)，\(openCodeNote, privacy: .public)｜\(breakdown, privacy: .public)"
          )
        }

        if failures > 0 {
          Self.logger.error("用量统计本轮跳过 \(failures) 个数据源（详见上面各条日志）")
        }
      } catch {
        Self.logger.error("用量统计索引失败：\(String(describing: error), privacy: .public)")
      }
      await self?.finishPass()
    }
  }

  /// 找出库里登记、但磁盘上已经不存在的记录文件（用本轮的进度快照，不再逐 Agent 查库）。
  private static func missingSourceIds(
    progress: [String: UsageSourceRecord], sources: [UsageSourceFile]
  ) -> Set<String> {
    let discovered = Set(sources.map { $0.path })
    // OpenCode 的数据源是「消息 id」而不是文件路径，不参与文件消失清理。
    return Set(progress.keys.filter { !$0.hasPrefix("opencode:") }).subtracting(discovered)
  }

  /// 通知 UI「索引有更新」：页面收到后重新取快照（回填期间数字会长出来）。
  ///
  /// 节流：页面每收到一次就要做一遍全库聚合（实测 45~154 ms），回填时按批通知会把
  /// UI 淹掉（本机 25 批 = 25 次聚合）。半秒一次足够「数字在长」的观感。
  fileprivate func notifyProgress() {
    let now = Date()
    if let lastProgressNotifyAt,
      now.timeIntervalSince(lastProgressNotifyAt) < Self.progressNotifyInterval
    {
      return
    }
    lastProgressNotifyAt = now
    updatesSubject.send(())
  }

  /// 一轮 OpenCode 扫描收尾：记下指纹与「是否追平」，下一轮据此决定跳不跳。
  fileprivate func finishOpenCodeSweep(
    fingerprint: OpenCodeDatabaseFingerprint?, morePagesRemain: Bool
  ) {
    openCodeFingerprint = fingerprint
    openCodeCatchUpPending = morePagesRemain
  }

  /// 一轮 OpenCode 扫描失败：下一轮照常重试，不看指纹。
  fileprivate func noteOpenCodeSweepFailed() {
    openCodeCatchUpPending = true
  }

  fileprivate func finishPass() {
    passTask = nil
    isIndexing = false
    lastPassFinishedAt = Date()
    // 复位节流：下一轮的第一批（或页面打开时的刷新）要能立刻通知，别被上一轮的窗口吃掉。
    lastProgressNotifyAt = nil
    updatesSubject.send()

    if pendingRefresh {
      pendingRefresh = false
      runPass()
    }
  }

  private func reader() throws -> UsageStatsStore {
    if let readerStore { return readerStore }
    let store = try UsageStatsStore(url: databaseURL)
    readerStore = store
    return store
  }
}
