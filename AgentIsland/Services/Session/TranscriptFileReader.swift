//
//  TranscriptFileReader.swift
//  AgentIsland
//
//  各 Agent Provider 共用的廉价读取：只从记录文件开头取一条记录里的某个
//  字段，不加载整个文件。
//

import Foundation

nonisolated enum TranscriptFileReader {
  /// 每次读取的块长。会话头部总是最先写入（`omp` 会先占一个 256 字节的 title 槽），
  /// 因此绝大多数文件一次就读完了。
  static let headerPrefixBytes = 8 * 1024

  /// 头部查找的总预算：读到这么多字节还没命中就放弃。
  ///
  /// 有预算才敢一直往后读：首行可能远超一次读取量（实测 WorkBuddy / CodeBuddy 会把整段
  /// 注入上下文写成第一条 user 消息，首行 14 KB），而按固定前缀截断再解析会得到一个
  /// **半个 JSON 的假行**——`cwd` 永远取不到，整个会话在发现器里被静默跳过。
  static let headerReadBudgetBytes = 1024 * 1024

  /// 读取 JSONL 记录文件开头，返回第一条满足 `predicate` 的记录经 `value`
  /// 取出的值。
  ///
  /// 只对**完整行**（以换行结束）做判断：长行因此能被整行读进来解析，而不是被前缀切碎；
  /// 行长度本身不设上限，总读取量由 `headerReadBudgetBytes` 封顶。文件尾没有换行的那
  /// 一行也照旧按一行处理。
  static func firstRecordField(
    in path: String,
    predicate: ([String: Any]) -> Bool,
    value: ([String: Any]) -> String?
  ) throws -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    var buffer = Data()
    var consumed = 0
    while consumed < headerReadBudgetBytes {
      let want = min(headerPrefixBytes, headerReadBudgetBytes - consumed)
      guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
      consumed += chunk.count
      buffer.append(chunk)

      while let newline = buffer.firstIndex(of: 0x0A) {
        // 按换行字节切分即可：切点一定落在 UTF-8 字符边界上（0x0A 不会出现在多字节
        // 序列的续字节里），`JSONSerialization` 也确实按字节解析。
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        if let extracted = recordValue(in: line, predicate: predicate, value: value) {
          return extracted
        }
      }
    }

    if !buffer.isEmpty, let extracted = recordValue(in: buffer, predicate: predicate, value: value) {
      return extracted
    }
    return nil
  }

  /// 单行记录取字段：解析不出 JSON、或 `predicate` 不认，都返回空（不抛错）。
  private static func recordValue(
    in line: Data,
    predicate: ([String: Any]) -> Bool,
    value: ([String: Any]) -> String?
  ) -> String? {
    guard !line.isEmpty,
      let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      predicate(json)
    else { return nil }
    return value(json)
  }

  /// 文件最后修改时间；文件不存在时返回 nil。
  static func modificationDate(of url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }
}
