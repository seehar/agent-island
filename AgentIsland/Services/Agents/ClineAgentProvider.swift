//
//  ClineAgentProvider.swift
//  AgentIsland
//
//  Cline 是 VSCode 扩展（没有 CLI 进程），记录放在扩展的 globalStorage 里：
//  `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/`
//  —— `state/taskHistory.json` 是任务索引（`{id, ts, cwdOnTaskInitialization, modelId}`），
//  每个任务的对话在 `tasks/<任务 id>/api_conversation_history.json`。
//
//  **例外：用户在设置面板里为 Cline 指定的目录与本 Provider 的记录路径无关。** 那个目录
//  是 Cline 自己的根（默认 `~/Documents/Cline`），只用来定位**安装器写 hook 的落点**
//  （`<它>/Hooks/<事件名>`，见 `AgentConfigInstaller`）；对话记录永远在 VSCode 扩展的
//  globalStorage 下，换不了（扩展自己决定写哪）。因此这里**不读** `AgentRootOverride`：
//  让它影响记录路径只会把记录找错地方。
//
//  事实来源：CodeIsland `Sources/CodeIsland/AppState.swift:5668`（findActiveClineSessions：
//  globalStorage 根、taskHistory 排序取最近任务、会话文件 mtime 作为新鲜度）、
//  `:5713`（clineStorageRoot）、`:5723`（readRecentFromClineHistory：条目数组 +
//  `role`/`content`）。Cline 没有进程可匹配（CodeIsland `findClinePids` 恒返回空），
//  因此本 Provider 也不参与进程识别。
//

import Foundation

nonisolated struct ClineAgentProvider: AgentProvider {
    let kind: AgentKind = .cline

    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // 解析符号链接：遍历结果与传入路径必须是同一种写法（见 AgentProviderRoot）。
        self.home = AgentProviderRoot.canonical(home)
    }

    /// 扩展存储目录相对用户主目录的路径（VS Code 稳定版）。
    private let storageComponents = [
        "Library", "Application Support", "Code", "User", "globalStorage",
        "saoudrizwan.claude-dev",
    ]
    private let tasksDirName = "tasks"
    private let historyDirName = "state"
    private let historyFileName = "taskHistory.json"
    private let conversationFileName = "api_conversation_history.json"

    // MARK: - 布局

    var configRoot: URL {
        storageComponents.reduce(home) { $0.appendingPathComponent($1) }
    }

    var tasksRoot: URL {
        configRoot.appendingPathComponent(tasksDirName)
    }

    /// 任务索引文件。
    var historyFile: URL {
        configRoot.appendingPathComponent(historyDirName).appendingPathComponent(historyFileName)
    }

    func paths() -> AgentPaths? {
        guard FileManager.default.fileExists(atPath: configRoot.path) else { return nil }
        return AgentPaths(
            configDir: configRoot,
            sessionsDir: tasksRoot,
            pluginsDir: nil,
            dataDir: nil
        )
    }

    // MARK: - 会话记录

    /// 任务 id 直接就是目录名，与 cwd 无关。
    func transcriptFile(sessionId: String, cwd: String) -> URL? {
        tasksRoot
            .appendingPathComponent(sessionId)
            .appendingPathComponent(conversationFileName)
    }

    func isTranscriptFile(_ path: String) -> Bool {
        guard path.hasPrefix(tasksRoot.path + "/") else { return false }
        return (path as NSString).lastPathComponent == conversationFileName
    }

    func sessionId(fromTranscriptFile path: String) -> String? {
        guard isTranscriptFile(path) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        let id = (directory as NSString).lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// 工作目录只能从任务索引里取（记录正文里没有 cwd）。
    func cwd(fromTranscriptFile path: String) throws -> String? {
        guard let sessionId = sessionId(fromTranscriptFile: path) else { return nil }
        return taskRecords().first { $0.id == sessionId }?.cwd
    }

    /// 子 Agent 记录：Cline 没有可识别的子会话文件布局，因此不认。
    func subagentTranscriptFiles(sessionId: String, cwd: String) -> [URL] { [] }

    // MARK: - 任务索引

    /// `state/taskHistory.json` 里的一条任务。
    struct TaskRecord: Sendable, Equatable {
        let id: String
        let cwd: String
        /// 索引里的 `ts`（毫秒时间戳）；缺失时为 nil。
        let updatedAt: Date?
        let modelId: String?
    }

    func taskRecords() -> [TaskRecord] {
        guard let data = FileManager.default.contents(atPath: historyFile.path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let cwd = entry["cwdOnTaskInitialization"] as? String ?? ""
            let stamp = (entry["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return TaskRecord(
                id: id,
                cwd: cwd,
                updatedAt: stamp,
                modelId: entry["modelId"] as? String
            )
        }
    }

    // MARK: - 集成状态

    func integrationStatus() -> AgentIntegrationStatus? {
        hookConfigIntegrationStatus(home: home, isAvailable: paths() != nil)
    }
}
