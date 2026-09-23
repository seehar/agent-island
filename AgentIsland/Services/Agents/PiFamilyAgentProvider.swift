//
//  PiFamilyAgentProvider.swift
//  AgentIsland
//
//  pi 系 CLI（Oh My Pi 与 Pi）共用的 Provider。两者的会话都以 JSONL 存放在
//  `<agent 目录>/sessions/<编码后的 cwd>/<时间戳>_<id>.jsonl`，并且都从
//  `<agent 目录>/extensions/` 加载实时事件扩展。
//

import Foundation

nonisolated struct PiFamilyAgentProvider: AgentProvider {
    let kind: AgentKind

    /// home 目录下的 agent 目录名。
    private var agentDirName: String {
        switch kind {
        case .pi: return ".pi/agent"
        default: return ".omp/agent"
        }
    }

    func paths() -> AgentPaths? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 用户指定目录（`AgentRootOverride`）替换的是 **agent 目录**（`~/.omp/agent` /
        // `~/.pi/agent`）；记录在它的 `sessions/` 下，因此**这个指定目录同时影响记录**。
        // 扩展与插件目录由工具自己的安装位置决定，不跟着走。
        let agentDir =
            AgentRootOverride.userOverride(for: kind)
            ?? home.appendingPathComponent(agentDirName)
        let plugins =
            kind == .ohMyPi
            ? home.appendingPathComponent(".omp/plugins")
            : home.appendingPathComponent(".pi")
        return AgentPaths(
            configDir: agentDir,
            sessionsDir: agentDir.appendingPathComponent("sessions"),
            pluginsDir: plugins,
            dataDir: nil
        )
    }

    // MARK: - 会话记录

    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        guard let sessionsDir = paths()?.sessionsDir else { return nil }

        let fm = FileManager.default
        // 快路径：直接由 cwd 推出分桶目录名。
        for bucket in Self.bucketNames(forCwd: cwd) {
            let dir = sessionsDir.appendingPathComponent(bucket)
            if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                if let match = entries.first(where: { Self.sessionIdForTranscript($0) == sessionId }
                ) {
                    return match
                }
            }
        }

        // 兜底：遍历所有分桶（会话 id 唯一，按文件名后缀匹配是安全的）。
        guard
            let buckets = try? fm.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: nil)
        else {
            return nil
        }
        for bucket in buckets {
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: bucket, includingPropertiesForKeys: nil)
            else { continue }
            if let match = entries.first(where: { Self.sessionIdForTranscript($0) == sessionId }) {
                return match
            }
        }
        return nil
    }

    func isTranscriptFile(_ path: String) -> Bool {
        Self.sessionIdForTranscript(URL(fileURLWithPath: path)) != nil
    }

    func sessionId(fromTranscriptFile path: String) -> String? {
        Self.sessionIdForTranscript(URL(fileURLWithPath: path))
    }

    func cwd(fromTranscriptFile path: String) throws -> String? {
        try TranscriptFileReader.firstRecordField(
            in: path,
            predicate: { $0["type"] as? String == "session" },
            value: { $0["cwd"] as? String }
        )
    }

    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] {
        // pi/omp 的子 Agent 记录放在同名兄弟目录中。
        guard let file = transcriptFile(sessionId: sessionId, cwd: cwd) else { return [] }
        let dir = file.deletingPathExtension()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else {
            return []
        }
        return entries.filter { $0.pathExtension == "jsonl" }
    }

    /// 会话 id 是 `<时间戳>_` 之后的 uuid。
    nonisolated static func sessionIdForTranscript(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard url.pathExtension == "jsonl", let separator = name.lastIndex(of: "_") else {
            return nil
        }
        let id = name[name.index(after: separator)...].replacingOccurrences(of: ".jsonl", with: "")
        // 会话 id 是 uuid（或 uuid 形式）；其余文件名一律拒绝。
        guard id.count >= 8, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return id
    }

    /// 工作目录对应的分桶目录候选名。
    ///
    /// 当前布局把 cwd 编码成相对 home 的路径（`-work-code-x`）；较早的布局把
    /// 绝对路径夹在双短横线之间（`--Users-name-work-code-x--`），临时目录根为
    /// `/private/tmp`。这里先给出现行写法，再给历史写法，若都不命中则由
    /// 会话 id 的遍历兜底。
    nonisolated static func bucketNames(forCwd cwd: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        var names: [String] = []

        if trimmed == home {
            names.append("-")
        } else if trimmed.hasPrefix(home + "/") {
            let relative = String(trimmed.dropFirst(home.count + 1))
            names.append("-" + relative.replacingOccurrences(of: "/", with: "-"))
            names.append("--" + trimmed.dropFirst().replacingOccurrences(of: "/", with: "-") + "--")
        } else {
            let absolute = trimmed.replacingOccurrences(of: "/", with: "-")
            names.append("-" + absolute + "-")
            if trimmed.hasPrefix("/tmp") {
                names.append("-private-tmp" + absolute.dropFirst("/tmp".count) + "-")
            }
        }
        // pi 的历史写法：绝对路径外层再包一对短横线。
        let legacyAbsolute =
            "--" + trimmed.dropFirst().replacingOccurrences(of: "/", with: "-") + "--"
        if !names.contains(legacyAbsolute) { names.append(legacyAbsolute) }
        return names
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        guard let paths = paths() else { return nil }
        let extensionFile = paths.configDir
            .appendingPathComponent("extensions")
            .appendingPathComponent(AgentIntegrationInstaller.piFamilyExtensionName)
        let installed = FileManager.default.fileExists(atPath: extensionFile.path)
        return AgentIntegrationStatus(
            health: installed ? .installed : .missing,
            installedFiles: [extensionFile]
        )
    }
}
