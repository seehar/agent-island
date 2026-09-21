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
  @discardableResult
  func ingest(sources: [UsageSourceFile], rebuilding: Bool = false) -> Int {
    var failures = 0
    for source in sources {
      do {
        let previous = rebuilding ? nil : try store.state(ofSource: source.path)
        let result = TranscriptUsageScanner.read(
          source: source, previous: previous?.state, calendar: calendar)

        // 重放：重算时无条件走这条（进度被丢弃，读到的就是全量）；增量时只在
        // 文件被截断 / 整体重写时走。
        if rebuilding || result.needsReplace {
          try store.replace(
            result.deltas, sourceId: source.path, agent: source.agent, state: result.state)
          continue
        }

        // 没有任何变化就不写：避免每轮扫描都产生一次事务。
        let unchanged =
          result.deltas.isEmpty
          && previous?.state.readOffset == result.state.readOffset
          && previous?.state.mtime == result.state.mtime
        if unchanged { continue }

        try store.append(
          result.deltas, sourceId: source.path, agent: source.agent, state: result.state)
      } catch {
        failures += 1
        Self.logger.error(
          "用量统计：跳过 \(source.path, privacy: .public)（\(String(describing: error), privacy: .public)）"
        )
      }
    }
    return failures
  }

  /// 索引 OpenCode 的历史（按消息增量）。
  ///
  /// 每轮最多读 `openCodeBatchIterations` 页；首次回填就是靠这一批批读完的
  /// （每页 4000 条），期间不会长时间占住 I/O。游标按页推进，**只认已处理过的
  /// 位置**，所以中途退出也不会丢消息。
  ///
  /// - Parameter rebuilding: 手动「重新统计」：游标归零、全库重走一遍。每条消息
  ///   在统计库里是独立数据源、按整源重放写库，因此重走是幂等的。
  func ingestOpenCode(databaseURL: URL, rebuilding: Bool = false) throws {
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

      for messageId in page.messageIds {
        let deltas = try reader.contributions(
          messageId: messageId, subagentSessions: subagentSessions, calendar: calendar)
        // 没有 token 也没有工具调用的消息（用户消息）不入库。
        guard !deltas.isEmpty else { continue }
        try store.replace(
          deltas, sourceId: Self.openCodeSourcePrefix + messageId, agent: .opencode,
          state: UsageSourceState(updatedAt: now))
      }

      cursors = (page.messageCursor, page.partCursor)
      guard advanced || !page.messageIds.isEmpty else { break }
      try store.append(
        [], sourceId: sweepId, agent: .opencode,
        state: UsageSourceState(
          cursor: Self.serializeCursors(cursors), updatedAt: now))

      if !page.isMessagePageFull && !page.isPartPageFull { break }
    }
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
  func snapshot(for range: StatsRange) async -> UsageStatsSnapshot {
    do {
      let store = try reader()
      return try store.snapshot(
        range: range, calendar: .current, now: Date(), isIndexing: isIndexing,
        indexedAt: lastPassFinishedAt)
    } catch {
      Self.logger.error("读取用量统计失败：\(String(describing: error), privacy: .public)")
      return UsageStatsSnapshot(range: range)
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

    passTask = Task.detached(priority: .utility) { [weak self] in
      do {
        let store = try UsageStatsStore(url: databaseURL)
        let pass = UsageStatsPass(store: store, calendar: calendar)

        var sources: [UsageSourceFile] = []
        for (kind, kindRoots) in roots.jsonlRoots {
          sources.append(contentsOf: TranscriptUsageScanner.sources(for: kind, roots: kindRoots))
        }

        var failures = 0
        var scanned = 0
        while scanned < sources.count {
          if Task.isCancelled { break }
          let end = min(scanned + chunkLimit, sources.count)
          failures += pass.ingest(
            sources: Array(sources[scanned..<end]), rebuilding: rebuilding)
          scanned = end
          await self?.notifyProgress()
          try? await Task.sleep(nanoseconds: chunkPause)
        }

        // 已经不存在于磁盘上的记录：清掉进度行（历史用量保留）。
        do {
          for sourceId in try Self.missingSourceIds(store: store, sources: sources) {
            try store.forgetCursor(sourceId: sourceId)
          }
        } catch {
          failures += 1
          Self.logger.error("清理用量统计进度失败：\(String(describing: error), privacy: .public)")
        }

        if let database = roots.openCodeDatabase {
          do {
            try pass.ingestOpenCode(databaseURL: database, rebuilding: rebuilding)
          } catch {
            failures += 1
            Self.logger.error(
              "OpenCode 用量索引失败：\(String(describing: error), privacy: .public)")
          }
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

  /// 找出库里登记、但磁盘上已经不存在的记录文件。
  private static func missingSourceIds(
    store: UsageStatsStore, sources: [UsageSourceFile]
  ) throws -> Set<String> {
    let discovered = Set(sources.map { $0.path })
    var dead: Set<String> = []
    for kind in AgentKind.allCases {
      guard let known = try? store.sourceIds(agent: kind) else { continue }
      // OpenCode 的数据源是「消息 id」而不是文件路径，不参与文件消失清理。
      dead.formUnion(known.filter { !$0.hasPrefix("opencode:") }.subtracting(discovered))
    }
    return dead
  }

  /// 通知 UI「索引有更新」：页面收到后重新取快照（回填期间数字会长出来）。
  fileprivate func notifyProgress() {
    updatesSubject.send(())
  }

  fileprivate func finishPass() {
    passTask = nil
    isIndexing = false
    lastPassFinishedAt = Date()
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
