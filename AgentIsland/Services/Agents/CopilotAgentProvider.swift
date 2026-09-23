//
//  CopilotAgentProvider.swift
//  AgentIsland
//
//  GitHub Copilot CLI 的布局（两代并存，都在 `~/.copilot` 下）：
//    · 当前版本：`jb/<会话 id>/partition-<n>.jsonl`（本机实测 9 个会话都是这个布局）；
//    · 旧版本（CodeIsland 读的）：`session-state/<会话 id>/events.jsonl`。
//  hook 写在 `~/.copilot/hooks/agent-island.json`。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:5620`（findActiveCopilotSessions：
//  `~/.copilot/session-state/<会话 id>/events.jsonl`）、`:5745`（findRecentCopilotSession）、
//  `:5783`（copilotSessionMatchesCwd：`session.start`.data.context.cwd 或
//  `hook.start`.data.input.cwd）。本机实测的差异：`session-state/<id>/` 里只有
//  `workspace.yaml` / `checkpoints` / `files`（没有 events.jsonl），而它同目录的
//  `workspace.yaml` 里有 `cwd:` 一行 —— 因此工作目录按「事件 → workspace.yaml」两级取。
//

import Foundation

nonisolated struct CopilotAgentProvider: AgentProvider {
    let kind: AgentKind = .copilot

    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    private let partitionsDirName = "jb"
    private let sessionStateDirName = "session-state"
    private let eventsFileName = "events.jsonl"
    private let partitionPrefix = "partition-"

    // MARK: - 布局

    /// 配置根：用户在设置面板里指定的目录优先（`AgentRootOverride`），否则 `~/.copilot`。
    /// 两代记录根（`jb/`、`session-state/`）都在它之下，因此**这个指定目录同时影响安装
    /// 与记录**。
    var configRoot: URL {
        AgentRootOverride.userOverride(for: kind) ?? home.appendingPathComponent(".copilot")
    }

    /// 当前版本的会话根。
    var partitionsRoot: URL {
        configRoot.appendingPathComponent(partitionsDirName)
    }

    /// 旧版本的会话根。
    var sessionStateRoot: URL {
        configRoot.appendingPathComponent(sessionStateDirName)
    }

    /// 记录根列表（当前布局优先）：会话按 `<会话 id>/<分区文件>` 两层存放。
    var recordsRoots: [URL] {
        [partitionsRoot, sessionStateRoot]
    }

    func paths() -> AgentPaths? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configRoot.path) else { return nil }
        let sessions = recordsRoots.first { fm.fileExists(atPath: $0.path) }
        return AgentPaths(
            configDir: configRoot,
            sessionsDir: sessions ?? partitionsRoot,
            pluginsDir: nil,
            dataDir: nil
        )
    }

    // MARK: - 会话记录

    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let partitions = partitionsRoot.appendingPathComponent(sessionId)
        if let newest = newestPartition(in: partitions) { return newest }
        let events = sessionStateRoot.appendingPathComponent(sessionId)
            .appendingPathComponent(eventsFileName)
        if fm.fileExists(atPath: events.path) { return events }
        // 两代布局都不在时返回约定路径（与 claude / pi 一致：记录可能刚被清理，
        // 调用方自己按存在性判断）。
        return partitions.appendingPathComponent("\(partitionPrefix)1.jsonl")
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard let rootName = sessionDirectoryRootName(of: url) else { return false }
        if name == eventsFileName { return rootName == sessionStateDirName }
        return name.hasPrefix(partitionPrefix) && rootName == partitionsDirName
    }

    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        let id = (directory as NSString).lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// 工作目录：先看事件（旧布局的 `session.start` / `hook.start`），再看
    /// `session-state/<会话 id>/workspace.yaml` 的 `cwd:`（本机当前版本的唯一来源）。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard isTranscriptFile(path) else { return nil }
        if let fromEvents = eventCwd(in: path) { return fromEvents }
        if let sessionId = sessionId(fromTranscriptFile: path) {
            return workspaceCwd(sessionId: sessionId)
        }
        return nil
    }

    /// 子 Agent 记录：Copilot 没有可识别的子会话文件布局，因此不认。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 目录解析

    /// 记录文件所在会话根的目录名（`jb` 或 `session-state`），不属于任一布局时 nil。
    private func sessionDirectoryRootName(of url: URL) -> String? {
        let sessionDir = url.deletingLastPathComponent()
        guard sessionDir.lastPathComponent != partitionsDirName,
            sessionDir.lastPathComponent != sessionStateDirName
        else { return nil }
        return sessionDir.deletingLastPathComponent().lastPathComponent
    }

    private func newestPartition(in directory: URL) -> URL? {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        let partitions = entries.filter { $0.lastPathComponent.hasPrefix(partitionPrefix) }
        // 分区序号递增，取序号最大的一份（会话的最新内容）。
        return partitions.max {
            partitionNumber(of: $0) < partitionNumber(of: $1)
        }
    }

    private func partitionNumber(of url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        return Int(stem.dropFirst(partitionPrefix.count)) ?? 0
    }

    private func eventCwd(in path: String) -> String? {
        if let cwd = try? TranscriptFileReader.firstRecordField(
            in: path,
            predicate: { $0["type"] as? String == "session.start" },
            value: {
                (($0["data"] as? [String: Any])?["context"] as? [String: Any])?["cwd"] as? String
            }
        ), !cwd.isEmpty {
            return cwd
        }
        if let cwd = try? TranscriptFileReader.firstRecordField(
            in: path,
            predicate: { $0["type"] as? String == "hook.start" },
            value: {
                (($0["data"] as? [String: Any])?["input"] as? [String: Any])?["cwd"] as? String
            }
        ), !cwd.isEmpty {
            return cwd
        }
        return nil
    }

    /// `workspace.yaml` 是几行 `key: value`，取其中的 `cwd`。
    private func workspaceCwd(sessionId: String) -> String? {
        let file = sessionStateRoot.appendingPathComponent(sessionId)
            .appendingPathComponent("workspace.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("cwd:") else { continue }
            let value = trimmed.dropFirst("cwd:".count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
