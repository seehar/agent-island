//
//  OpenCodeDatabaseTests.swift
//  AgentIslandTests
//
//  OpenCode 的库是 WAL 模式，而**纯只读连接**在 `-shm`（wal-index）不存在时会连 prepare
//  都失败（实测 `SQLITE_CANTOPEN`：unable to open database file）——本机 OpenCode 没在跑
//  时就是这个状态，统计页的 OpenCode 部分与会话列表一起静默失效。这里钉住打开契约两条：
//    · 没有 -shm 的 WAL 库照样能打开并读到数据；
//    · 打开后的连接写不进去（`query_only`），别人的库绝不会被我们改。
//

import Foundation
import SQLite3
import Testing

@testable import AgentIsland

@Suite("OpenCode 库的打开方式")
struct OpenCodeDatabaseTests {
  // MARK: - 夹具

  /// 造一个 WAL 模式的库（表取统计用到的 `message` 的最小形状），并删掉 `-shm`/`-wal`：
  /// 只有「没有 wal-index」才是 OpenCode 没在运行时的真实现场。
  private func makeWALDatabase() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("opencode-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("opencode.db")

    try seed(url: url)
    for suffix in ["-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
    return url
  }

  private func seed(url: URL) throws {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK,
      let handle
    else {
      throw OpenCodeDatabaseError.openFailed("夹具库打不开")
    }
    defer { sqlite3_close(handle) }

    for sql in [
      "PRAGMA journal_mode = WAL;",
      "CREATE TABLE message(id TEXT PRIMARY KEY);",
      "INSERT INTO message(id) VALUES ('m1'), ('m2'), ('m3');",
    ] {
      guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw OpenCodeDatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
      }
    }
  }

  private func messageCount(_ handle: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM message;", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw OpenCodeDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw OpenCodeDatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  // MARK: - 用例

  @Test("没有 -shm 的 WAL 库也能打开并读到数据")
  func opensWALDatabaseWithoutSharedMemory() throws {
    let url = try makeWALDatabase()
    #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))

    let handle = try OpenCodeDatabase.openReadOnly(url: url, busyTimeoutMilliseconds: 500)
    defer { sqlite3_close(handle) }

    #expect(try messageCount(handle) == 3)
  }

  @Test("打开后的连接写不进去：不会改到 OpenCode 的数据")
  func openedConnectionRefusesWrites() throws {
    let url = try makeWALDatabase()
    let handle = try OpenCodeDatabase.openReadOnly(url: url, busyTimeoutMilliseconds: 500)
    defer { sqlite3_close(handle) }

    #expect(sqlite3_exec(handle, "INSERT INTO message(id) VALUES ('x');", nil, nil, nil) != SQLITE_OK)
    #expect(try messageCount(handle) == 3)
  }
}
