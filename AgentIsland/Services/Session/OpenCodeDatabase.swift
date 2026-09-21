//
//  OpenCodeDatabase.swift
//  AgentIsland
//
//  OpenCode 的会话记录在它自己的 SQLite 库里（`~/.local/share/opencode/opencode.db`）：
//  会话列表（`OpenCodeSessionStore`）与用量统计（`OpenCodeUsageReader`）都要读它，
//  所以「怎么打开这个库」收在一处，两边都别各写一遍。
//

import Foundation
import SQLite3

/// OpenCode 库的打开方式。
///
/// 主路径是**先按读写打开、再用 `PRAGMA query_only = 1` 把这条连接钉成只读**——顺序
/// 反直觉，原因是这个库是 WAL 模式：wal-index（`-shm`）不存在时，**纯只读连接**
/// `sqlite3_open_v2` 是成功的（`SQLITE_OK`），但它的第一条语句在 prepare 阶段就失败
/// （实测 `SQLITE_CANTOPEN`：unable to open database file）——只读连接没有权限创建那个
/// 文件，而读写连接有。本机 OpenCode 没在跑时正是这个状态：统计页的 OpenCode 部分与会话
/// 列表一起静默失效，只留一条日志。`query_only` 保证我们仍然只读：任何写入都会被拒
/// （测试钉住了这条）。代价是 SQLite 会在 OpenCode 的目录里留下 `-shm` 与空的 `-wal`
/// ——与 OpenCode 自己运行时留下的相同。
///
/// 读写打开失败（文件或目录不可写、只读挂载）时退回纯只读：`-shm` 已存在（OpenCode
/// 正在运行，或别的连接建过）就照常可用，否则调用方会在第一条语句上拿到错误并各自降级
/// （会话列表退回旧版 JSON 目录、统计跳过这一轮）。
nonisolated enum OpenCodeDatabase {
  /// 以只读用途打开 OpenCode 的库，并设置忙等超时。
  ///
  /// - Parameters:
  ///   - url: 库文件位置。
  ///   - busyTimeoutMilliseconds: 忙等超时（OpenCode 正在写时不要立刻失败）。
  static func openReadOnly(url: URL, busyTimeoutMilliseconds: Int32) throws -> OpaquePointer {
    do {
      let handle = try open(url: url, flags: SQLITE_OPEN_READWRITE)
      // 钉成只读：这条连接只用来读别人的库，任何写入都必须失败（测试钉住了这条）。
      guard sqlite3_exec(handle, "PRAGMA query_only = 1;", nil, nil, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(handle))
        sqlite3_close(handle)
        throw OpenCodeDatabaseError.openFailed("query_only 设置失败：\(message)")
      }
      sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
      return handle
    } catch {
      let readWriteFailure = "\(error)"
      do {
        let handle = try open(url: url, flags: SQLITE_OPEN_READONLY)
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
        return handle
      } catch {
        throw OpenCodeDatabaseError.openFailed(
          "读写打开失败（\(readWriteFailure)）；退回只读也失败（\(error)）")
      }
    }
  }

  /// 按指定标志打开；失败即抛错（附 SQLite 的原文）。
  private static func open(url: URL, flags: Int32) throws -> OpaquePointer {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知原因"
      if let handle { sqlite3_close(handle) }
      throw OpenCodeDatabaseError.openFailed(message)
    }
    return handle
  }
}

/// OpenCode 库「有没有被写过」的指纹：库文件与它的 `-wal` 的 (size, mtime)。
///
/// 用途：判断能不能跳过一轮 OpenCode 扫描。这个库在 `message` / `part` 上没有按时间的
/// 索引，而统计要按 `time_updated > 游标` 取增量——那两条查询是**全表扫描**（本机
/// 2.7 万 + 12.7 万行、库 2.29 GB），冷缓存下实测约 2 秒读盘。库和 `-wal` 都没动过时，
/// 不会有新数据，这两秒纯属白花。
///
/// WAL 模式下新提交先落在 `-wal` 里、主库文件可能一动不动，所以两个都要看；`-shm` 只
/// 是 wal-index（每条连接都会动它），不参与判定。
nonisolated struct OpenCodeDatabaseFingerprint: Equatable {
  var databaseSize: UInt64
  var databaseMtime: Double
  var walSize: UInt64
  var walMtime: Double

  /// 现取一次指纹；库文件不存在时返回 nil（调用方据此照常去扫，别拿它当「没变化」）。
  static func read(databaseURL: URL) -> OpenCodeDatabaseFingerprint? {
    guard let database = attributes(of: databaseURL) else { return nil }
    let wal = attributes(of: URL(fileURLWithPath: databaseURL.path + "-wal"))
    // 空的（0 字节）`-wal` 一律折算成「没有内容」：我们自己的连接（读写 + `query_only`）
    // 开合就会不断创建 / 触碰这个空文件——实测它的 mtime 每分钟都在变，算进指纹等于永远
    // 判定「被写过」，门就永远关不上了。真有人提交时 `-wal` 至少有一个 4 KB 帧，
    // size > 0，指纹照常跟着变。
    let walSize = wal?.size ?? 0
    return OpenCodeDatabaseFingerprint(
      databaseSize: database.size,
      databaseMtime: database.mtime,
      walSize: walSize,
      walMtime: walSize == 0 ? 0 : (wal?.mtime ?? 0)
    )
  }

  private static func attributes(of url: URL) -> (size: UInt64, mtime: Double)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return nil
    }
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return (size: size, mtime: mtime)
  }
}

/// OpenCode 库的失败原因（错误文本来自 SQLite，原样附上）。
nonisolated enum OpenCodeDatabaseError: Error, CustomStringConvertible {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)

  var description: String {
    switch self {
    case .openFailed(let message): return "打开 OpenCode 库失败：\(message)"
    case .prepareFailed(let message): return "OpenCode 库语句准备失败：\(message)"
    case .stepFailed(let message): return "OpenCode 库执行失败：\(message)"
    }
  }
}
