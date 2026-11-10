//
//  SQLiteQueryRunner.swift
//  AgentIsland
//
//  读别人家的 SQLite 库时的共用查询入口：打开只读短连接 → 绑定参数 → 准备语句 →
//  逐行取。OpenCode（`opencode.db`）与 Hermes（`state.db`）的会话读取做的是同一套
//  动作，原先两边各写了一份，现在只留这一份。
//

import Foundation
import SQLite3
import os.log

/// 以独立只读短连接执行查询的共用实现。
///
/// 库的打不开、语句准备失败、逐行读取中途出错都返回 nil，由调用方降级到各自的后备
/// 来源（OpenCode 退旧版 JSON 目录，Hermes 当成「没有会话」）。绑定值用
/// `SQLiteValue`（与统计库共用一个枚举，见 `UsageStatsStore.swift`）。
nonisolated enum SQLiteQueryRunner {
    /// 数据库拿不到锁时的等待上限；宁可返回空结果也不长时间阻塞调用方。
    private static let busyTimeoutMilliseconds: Int32 = 500

    /// 告诉 SQLite 复制绑定的字符串，调用返回后即可释放。
    private static let transientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    /// 一次查询的日志口径。
    ///
    /// 各 store 的 Logger、库归属（`opencode` / `hermes`）与「库打不开时会怎样」都不同，
    /// 但日志文案要按各自的原有口径写，所以由调用方带进来。
    nonisolated struct Log {
        /// 调用方的日志通道（决定日志的 category）。
        let logger: Logger
        /// 库归属，拼在消息前缀（`opencode 数据库打不开…`）。
        let label: String
        /// 打不开时调用方的后果说明（`降级到旧版 JSON 目录` 之类）。
        let unavailableNotice: String
    }

    /// 用独立的只读短连接执行一条语句；数据库不可用时返回 nil。
    ///
    /// `body` 返回 nil 表示本次查询失败（例如中途拿到 `SQLITE_BUSY`），调用方据此降级。
    ///
    /// - Parameters:
    ///   - sql: 语句文本（只允许本仓代码里的字面量拼装，外部数据一律走 `values`）。
    ///   - values: 绑定值，按出现顺序对应语句里的占位符。
    ///   - databaseURL: 库文件位置；为 nil 时直接返回 nil（调用方降级）。
    ///   - log: 失败时用的日志口径。
    ///   - body: 语句准备好之后执行的部分。
    static func withStatement<T>(
        _ sql: String,
        values: [SQLiteValue],
        databaseURL: URL?,
        log: Log,
        body: (OpaquePointer) -> T?
    ) -> T? {
        guard let databaseURL else { return nil }

        // 打开方式与失败原因见 `SQLiteReadOnlyConnection`：WAL 库没有 -shm 时纯只读连接会失败。
        let database: OpaquePointer
        do {
            database = try SQLiteReadOnlyConnection.open(
                url: databaseURL, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        } catch {
            // 标签与后果说明标 `.public`：它们原本是字面量前缀，不该被日志打成 <private>。
            log.logger.debug(
                "\(log.label, privacy: .public) 数据库打不开，\(log.unavailableNotice, privacy: .public)：\(String(describing: error), privacy: .public)"
            )
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            log.logger.debug(
                "\(log.label, privacy: .public) 查询准备失败：\(String(cString: sqlite3_errmsg(database)))"
            )
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            bind(value, to: statement, at: Int32(offset + 1))
        }
        return body(statement)
    }

    /// 绑定第 `index` 个（从 1 开始）占位符。
    private static func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) {
        switch value {
        case .text(let text):
            sqlite3_bind_text(statement, index, text, -1, transientDestructor)
        case .integer(let number):
            sqlite3_bind_int64(statement, index, number)
        case .double(let number):
            sqlite3_bind_double(statement, index, number)
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }

    /// 逐行执行查询；中途出错返回 nil（调用方降级）。
    static func rows<T>(_ statement: OpaquePointer, _ row: () -> T?) -> [T]? {
        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { return nil }
            guard let value = row() else { return nil }
            values.append(value)
        }
    }

    /// 读取某一列的文本值；NULL 返回 nil，空串原样返回。
    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    /// 读取某一列的文本值；NULL 与空串都当作「没有值」。
    static func nonEmptyText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = text(statement, index), !value.isEmpty else { return nil }
        return value
    }

    /// 读取某一列的整数；NULL 按 0 处理（与 `sqlite3_column_int64` 一致）。
    static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    /// 读取某一列的实数；NULL 按 0 处理（与 `sqlite3_column_double` 一致）。
    static func double(_ statement: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }
}
