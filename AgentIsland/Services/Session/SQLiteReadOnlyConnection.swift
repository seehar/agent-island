//
//  SQLiteReadOnlyConnection.swift
//  AgentIsland
//
//  「怎么打开别人家的 SQLite 库」的共用方式：OpenCode（`opencode.db`）与
//  Hermes（`state.db`）都要读各自工具的库，而两者的打开顺序（读写打开 + `PRAGMA
//  query_only`，失败退纯只读）是同一件事，因此只能有一份。原先这份实现长在
//  `OpenCodeDatabase` 里，搬到此处后由它一行委托。
//

import Foundation
import SQLite3

/// 以**只读用途**打开一个外部 SQLite 库。
///
/// 主路径是**先按读写打开、再用 `PRAGMA query_only = 1` 把这条连接钉成只读**——顺序
/// 反直觉，原因是这些库都是 WAL 模式：wal-index（`-shm`）不存在时，**纯只读连接**
/// `sqlite3_open_v2` 是成功的（`SQLITE_OK`），但它的第一条语句在 prepare 阶段就失败
/// （实测 `SQLITE_CANTOPEN`：unable to open database file）——只读连接没有权限创建那个
/// 文件，而读写连接有。工具没在跑时正是这个状态：会话列表与统计会一起静默失效，
/// 只留一条日志。`query_only` 保证我们仍然只读：任何写入都会被拒（测试钉住了这条）。
/// 代价是 SQLite 会在那个工具的目录里留下 `-shm` 与空的 `-wal`——与工具自己运行时
/// 留下的相同。
///
/// 读写打开失败（文件或目录不可写、只读挂载）时退回纯只读：`-shm` 已存在（工具正在
/// 运行，或别的连接建过）就照常可用，否则调用方会在第一条语句上拿到错误并各自降级。
nonisolated enum SQLiteReadOnlyConnection {
  /// 打开库文件并设置忙等超时。
  ///
  /// - Parameters:
  ///   - url: 库文件位置。
  ///   - busyTimeoutMilliseconds: 忙等超时（工具正在写时不要立刻失败）。
  static func open(url: URL, busyTimeoutMilliseconds: Int32) throws -> OpaquePointer {
    do {
      let handle = try open(url: url, flags: SQLITE_OPEN_READWRITE)
      // 钉成只读：这条连接只用来读别人的库，任何写入都必须失败（测试钉住了这条）。
      guard sqlite3_exec(handle, "PRAGMA query_only = 1;", nil, nil, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(handle))
        sqlite3_close(handle)
        throw SQLiteReadOnlyConnectionError.openFailed("query_only 设置失败：\(message)")
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
        throw SQLiteReadOnlyConnectionError.openFailed(
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
      throw SQLiteReadOnlyConnectionError.openFailed(message)
    }
    return handle
  }
}

/// 打开外部 SQLite 库的失败原因（错误文本来自 SQLite，原样附上）。
nonisolated enum SQLiteReadOnlyConnectionError: Error, CustomStringConvertible {
  case openFailed(String)

  var description: String {
    switch self {
    case .openFailed(let message): return "打开只读库失败：\(message)"
    }
  }
}