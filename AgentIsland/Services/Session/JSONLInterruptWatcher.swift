//
//  JSONLInterruptWatcher.swift
//  AgentIsland
//
//  Watches JSONL files for interrupt patterns in real-time
//  Uses file system events to detect interrupts faster than hook polling
//

import Foundation
import os.log

/// 中断监听的日志器（与 `SessionStore` 同属会话层，用同一个 category）。
private let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Session")

protocol JSONLInterruptWatcherDelegate: AnyObject {
    func didDetectInterrupt(key: SessionKey)
}

/// Watches a session's JSONL file for interrupt patterns in real-time
/// Uses DispatchSource for immediate detection when new lines are written
class JSONLInterruptWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    /// 读取失败是否已经报告过。监听会在每次文件写入时重试同一处失败，逐次打
    /// 日志会把 debug 流刷满，因此每个记录文件（每个 watcher）最多报一次。
    private var didReportReadFailure = false
    private let key: SessionKey
    private let filePath: String
    private let queue = DispatchQueue(label: "com.celestial.AgentIsland.interruptwatcher", qos: .userInteractive)

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user"
    ]

    /// `transcriptPath` 由调用方（会话状态）提供；缺省时按 Agent 的目录规则推导。
    init(key: SessionKey, cwd: String, transcriptPath: String?) {
        self.key = key
        let resolved = transcriptPath ?? AgentRegistry.provider(for: key.agent)
            .transcriptFile(sessionId: key.sessionId, cwd: cwd)?
            .path
        self.filePath = resolved ?? ""
        if resolved == nil {
            // 记录路径推不出来：监听建立不起来，中断只能靠 hook 上报兜底。
            logger.debug(
                "无法定位会话记录文件，中断监听未建立：\(key.rawValue, privacy: .public)")
        }
    }

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        stopInternal()
        // 换了新句柄，读取失败可以再报一次。
        didReportReadFailure = false

        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            let path = filePath.isEmpty ? "（未解析出记录路径）" : filePath
            logger.warning("无法打开会话记录，中断监听未建立：\(path, privacy: .public)")
            return
        }

        fileHandle = handle

        do {
            lastOffset = try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching: \(self.key.rawValue, privacy: .public)")
    }

    /// 文件系统事件入口。
    ///
    /// 记录被删除（会话记录被清理）时监听再无意义，主动停掉以释放 fd；其余事件
    /// 走中断检查。
    private func handleFileEvent() {
        if source?.data.contains(.delete) == true {
            logger.debug("会话记录已被删除，停止中断监听：\(self.key.rawValue, privacy: .public)")
            stopInternal()
            return
        }
        checkForInterrupt()
    }

    /// 报告一次读取失败；每个 watcher 只报一次，避免每次写入都刷日志。
    private func reportReadFailure(_ reason: String) {
        guard !didReportReadFailure else { return }
        didReportReadFailure = true
        logger.debug(
            "读取会话记录失败（\(reason, privacy: .public)）：\(self.key.rawValue, privacy: .public)")
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            reportReadFailure("定位文件末尾失败：\(error.localizedDescription)")
            return
        }

        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            reportReadFailure("定位读取位置失败：\(error.localizedDescription)")
            return
        }

        guard let newData = try? handle.readToEnd() else {
            reportReadFailure("读取新增内容失败")
            return
        }
        guard let newContent = String(data: newData, encoding: .utf8) else {
            reportReadFailure("新增内容不是 UTF-8")
            return
        }

        lastOffset = currentSize

        let lines = newContent.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            if isInterruptLine(line) {
                logger.info("Detected interrupt in session: \(self.key.rawValue, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.didDetectInterrupt(key: self.key)
                }
                return
            }
        }
    }

    private func isInterruptLine(_ line: String) -> Bool {
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
               line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }

        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            for pattern in Self.interruptContentPatterns {
                if line.contains(pattern) {
                    return true
                }
            }
        }

        if line.contains("\"interrupted\":true") {
            return true
        }

        return false
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        if source != nil {
            logger.debug("Stopped watching: \(self.key.rawValue, privacy: .public)")
        }
        source?.cancel()
        source = nil
        // fileHandle closed by cancel handler
    }

    deinit {
        source?.cancel()
    }
}

// MARK: - Interrupt Watcher Manager

/// Manages interrupt watchers for all active sessions
@MainActor
class InterruptWatcherManager {
    static let shared = InterruptWatcherManager()

    /// 同时监听的会话数上限。
    ///
    /// 依据：每个 watcher 占一个 fd（`DispatchSourceFileSystemObject`）与一条常驻
    /// 串行队列，内存量级只有几 KB，但 fd 是硬资源；同时活跃的会话通常是个位数，
    /// 16 足够覆盖。应用长时间运行时这张表只增不减，因此超出后按「最久没被刷新」
    /// 停掉监听（连 fd 一起释放）。
    private static let maxWatchedSessions = 16

    private var watchers: [SessionKey: JSONLInterruptWatcher] = [:]
    /// 每个会话最后一次被刷新的顺序号，用于淘汰最久未使用者的监听。
    private var lastUsedTick: [SessionKey: UInt64] = [:]
    /// 单调递增的使用顺序号。
    private var useTick: UInt64 = 0
    weak var delegate: JSONLInterruptWatcherDelegate?

    private init() {}

    func startWatching(key: SessionKey, cwd: String, transcriptPath: String?) {
        // 已在该会话上监听：只刷新「最近使用」，不重建（重建会丢掉已有的读取偏移）。
        guard watchers[key] == nil else {
            noteUse(key)
            return
        }

        let watcher = JSONLInterruptWatcher(key: key, cwd: cwd, transcriptPath: transcriptPath)
        watcher.delegate = delegate
        watcher.start()
        watchers[key] = watcher
        noteUse(key)
    }

    /// 记录一次使用，并在监听数超出上限时停掉最久未使用者的监听。
    ///
    /// 会话结束时 Claude 会发 `ended` 事件走 `stopWatching`，但记录被删除、或
    /// 应用长时间运行后不再有事件的会话只能靠这里兜底。
    private func noteUse(_ key: SessionKey) {
        useTick &+= 1
        lastUsedTick[key] = useTick
        while watchers.count > Self.maxWatchedSessions,
            let victim = watchers.keys.min(by: {
                lastUsedTick[$0, default: 0] < lastUsedTick[$1, default: 0]
            })
        {
            // stop() 会取消 DispatchSource，句柄随 cancel handler 关闭，fd 不泄漏。
            logger.debug(
                "中断监听数超过上限，停止最久未使用的会话：\(victim.rawValue, privacy: .public)")
            watchers[victim]?.stop()
            watchers.removeValue(forKey: victim)
            lastUsedTick.removeValue(forKey: victim)
        }
    }

    /// Stop watching a specific session
    func stopWatching(key: SessionKey) {
        watchers[key]?.stop()
        watchers.removeValue(forKey: key)
        lastUsedTick.removeValue(forKey: key)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        lastUsedTick.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(key: SessionKey) -> Bool {
        watchers[key] != nil
    }
}
