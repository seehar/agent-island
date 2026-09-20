//
//  TranscriptFileReader.swift
//  ClaudeIsland
//
//  各 Agent Provider 共用的廉价读取：只从记录文件开头取一条记录里的某个
//  字段，不加载整个文件。
//

import Foundation

nonisolated enum TranscriptFileReader {
  /// 查找头部记录时读取的前缀长度。会话头部总是最先写入（`omp` 会先占一个
  /// 256 字节的 title 槽），几 KB 足够。
  static let headerPrefixBytes = 8 * 1024

  /// 读取 JSONL 记录文件开头，返回第一条满足 `predicate` 的记录经 `value`
  /// 取出的值。
  static func firstRecordField(
    in path: String,
    predicate: ([String: Any]) -> Bool,
    value: ([String: Any]) -> String?
  ) throws -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    let data = handle.readData(ofLength: headerPrefixBytes)
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    for line in text.split(separator: "\n") {
      guard let lineData = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
        predicate(json)
      else { continue }
      if let extracted = value(json) {
        return extracted
      }
    }
    return nil
  }

  /// 文件最后修改时间；文件不存在时返回 nil。
  static func modificationDate(of url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }
}
