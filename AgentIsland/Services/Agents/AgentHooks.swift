//
//  AgentHooks.swift
//  AgentIsland
//
//  各 Agent 的**配置文件型 hook** 描述表：写哪个文件、用哪种结构、注册哪些事件、
//  决定用什么形状回写。安装器（`AgentConfigInstaller`）与 hook 脚本只读这张表，
//  因此「支持一个新工具」在这里是一行数据，而不是散在各处的分支。
//
//  事实来源：CodeIsland（同生态的刘海应用，已支持这些工具）的 `ConfigInstaller`
//  的 `builtInCLIs` 表与其 `HookFormat` 语义；事件名一律是该工具自己的原生写法，
//  归一成应用侧事件名由 hook 脚本负责（见 `Resources/agent-island-hook.py`）。
//

import Foundation

/// hook 配置的写入格式。每种格式对应一种既有的配置结构，安装器各有一个写入器。
nonisolated enum AgentHookFormat: String, Sendable {
    /// Claude Code 系：`{event: [{matcher, hooks: [{type, command, timeout}]}]}`。
    case claude
    /// Codex / Gemini 系：`{event: [{hooks: [{type, command, timeout}]}]}`（没有 matcher）。
    case nested
    /// Cursor 系：`{event: [{command}]}`（事件名即 camelCase）。
    case flat
    /// Trae IDE 系：`{version, hooks: {event: [{matcher, loop_limit, hooks: [...]}]}}`。
    case traeIDE
    /// TraeCli：`~/.trae/traecli.yaml` 里的托管 YAML 块（`hooks:` 下一个带 matchers 的命令项）。
    case traecli
    /// Copilot CLI：`{version, hooks: {event: [{type, bash, timeoutSec}]}}`。
    case copilot
    /// Kimi Code CLI：`~/.kimi-code/config.toml` 里追加 `[[hooks]]` 数组表。
    case kimi
    /// Cline：`~/Documents/Cline/Hooks/<EventName>` 一个事件一个可执行文件。
    case cline
}

/// 回写决定的协议：应用只回 `{"decision":"allow"|"deny"}`，各工具的 stdout 形状由
/// hook 脚本按这里翻译。
nonisolated enum AgentVerdictProtocol: String, Sendable {
    /// Claude 系：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`。
    case claudeEnvelope
    /// Gemini CLI：`{"decision":"allow"}`。
    case geminiDecision
    /// 不回决定：Cline 的 hook 必须立刻返回 `{"cancel":false}`（转发在后台完成）。
    case none
}

/// 安装时需要一并处理的前置开关。
nonisolated enum AgentHookPrerequisite: String, Sendable {
    /// Codex 只在 `$CODEX_HOME/config.toml` 的 `[features] hooks = true` 时才触发 hook。
    case codexHooksFeature
}

/// 一个要注册的事件：原生事件名 + 超时 + 是否阻塞等待刘海决定。
nonisolated struct AgentHookEvent: Sendable, Equatable {
    let name: String
    /// 超时（秒；`timeoutsInMilliseconds` 为真时写进配置的是毫秒）。
    let timeout: Int
    /// 该事件是否等待刘海决定（只有审批类事件为真，超时必须足够长）。
    var blocking: Bool = false

    init(_ name: String, _ timeout: Int, blocking: Bool = false) {
        self.name = name
        self.timeout = timeout
        self.blocking = blocking
    }
}

/// 某个 Agent 的 hook 安装描述。
nonisolated struct AgentHookSpec: Sendable {
    let format: AgentHookFormat
    /// 配置文件相对用户主目录的路径；`rootEnvVar` 有值时相对那个根目录。
    let configPath: String
    /// 覆盖配置根目录的环境变量（`CODEX_HOME` / `GROK_HOME`）；缺省用 `~`。
    let rootEnvVar: String?
    /// 事件所在的顶层键（Cline 无配置结构，留空）。
    let configKey: String
    let events: [AgentHookEvent]
    let verdict: AgentVerdictProtocol
    /// 超时写进配置时是否用毫秒（Gemini 系按毫秒解释 `timeout`）。
    var timeoutsInMilliseconds: Bool = false
    /// 配置根目录不存在时是否跳过安装（宁可不动用户的机器，也不要凭空造目录）。
    var requiresExistingRoot: Bool = true
    /// 存在性闸门的判据路径（相对用户主目录）；nil 表示按 `configPath` 推导。
    ///
    /// 用于「配置**文件所在的目录**本身也要由我们创建」的工具：Cline 的 hook 目录
    /// `~/Documents/Cline/Hooks` 是它按需创建的，判据必须往上退一层到工具自己的
    /// 目录 `~/Documents/Cline`——否则会给没装 Cline 的用户凭空造目录。
    var gatePath: String? = nil
    var prerequisites: [AgentHookPrerequisite] = []

    /// 该 Agent 的事件里是否有阻塞审批事件。
    var hasBlockingEvent: Bool { events.contains { $0.blocking } }
}

nonisolated extension AgentKind {
    /// 该 Agent 的配置文件型 hook 描述；集成不由配置文件实现时返回 nil
    /// （Claude 走 hook 脚本、omp/pi 走扩展、opencode 走插件、DSH 没有集成）。
    var hookSpec: AgentHookSpec? {
        switch self {
        case .claudeCode, .ohMyPi, .pi, .opencode, .deepSeekHarness:
            return nil
        case .codex:
            return AgentHookSpec(
                format: .nested,
                configPath: "hooks.json",
                rootEnvVar: "CODEX_HOME",
                configKey: "hooks",
                events: [
                    // PermissionRequest 是阻塞审批：Codex 在 shell 提权 / 受管网络批准前触发。
                    AgentHookEvent("SessionStart", 5),
                    AgentHookEvent("SessionEnd", 3),
                    AgentHookEvent("UserPromptSubmit", 5),
                    AgentHookEvent("PreToolUse", 5),
                    AgentHookEvent("PostToolUse", 5),
                    AgentHookEvent("PermissionRequest", 86400, blocking: true),
                    AgentHookEvent("Stop", 5),
                ],
                verdict: .claudeEnvelope,
                prerequisites: [.codexHooksFeature]
            )
        case .gemini:
            return AgentHookSpec(
                format: .nested,
                configPath: ".gemini/settings.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: [
                    // Gemini 的 timeout 单位是毫秒；BeforeTool 是阻塞审批（工具执行前）。
                    AgentHookEvent("SessionStart", 10000),
                    AgentHookEvent("SessionEnd", 10000),
                    AgentHookEvent("BeforeTool", 86400000, blocking: true),
                    AgentHookEvent("AfterTool", 10000),
                    AgentHookEvent("BeforeAgent", 10000),
                    AgentHookEvent("AfterAgent", 10000),
                ],
                verdict: .geminiDecision,
                timeoutsInMilliseconds: true
            )
        case .cursor:
            return AgentHookSpec(
                format: .flat,
                configPath: ".cursor/hooks.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: Self.cursorStyleEvents,
                verdict: .none
            )
        case .copilot:
            return AgentHookSpec(
                format: .copilot,
                configPath: ".copilot/hooks/agent-island.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: [
                    AgentHookEvent("sessionStart", 5),
                    AgentHookEvent("sessionEnd", 5),
                    AgentHookEvent("userPromptSubmitted", 5),
                    AgentHookEvent("preToolUse", 5),
                    AgentHookEvent("postToolUse", 5),
                    AgentHookEvent("errorOccurred", 5),
                ],
                verdict: .none
            )
        case .qoder:
            return AgentHookSpec(
                format: .claude,
                configPath: ".qoder/settings.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: Self.claudeFamilyEventsWithApproval,
                verdict: .claudeEnvelope
            )
        case .factory:
            return AgentHookSpec(
                format: .claude,
                configPath: ".factory/settings.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: Self.claudeFamilyEvents,
                verdict: .none
            )
        case .codeBuddy:
            return AgentHookSpec(
                format: .claude,
                configPath: ".codebuddy/settings.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: Self.claudeFamilyEvents,
                verdict: .none
            )
        case .kimi:
            return AgentHookSpec(
                format: .kimi,
                configPath: "config.toml",
                rootEnvVar: nil,
                configKey: "hooks",
                events: [
                    // Kimi 的 hook 超时上限是 600；它没有 PermissionRequest 事件。
                    AgentHookEvent("UserPromptSubmit", 5),
                    AgentHookEvent("PreToolUse", 5),
                    AgentHookEvent("PostToolUse", 5),
                    AgentHookEvent("PostToolUseFailure", 5),
                    AgentHookEvent("Stop", 5),
                    AgentHookEvent("SubagentStart", 5),
                    AgentHookEvent("SubagentStop", 5),
                    AgentHookEvent("SessionStart", 5),
                    AgentHookEvent("SessionEnd", 5),
                    AgentHookEvent("Notification", 600),
                    AgentHookEvent("PreCompact", 5),
                ],
                verdict: .none
            )
        case .cline:
            return AgentHookSpec(
                format: .cline,
                configPath: "Documents/Cline/Hooks",
                rootEnvVar: nil,
                configKey: "",
                events: [
                    AgentHookEvent("UserPromptSubmit", 5),
                    AgentHookEvent("PreToolUse", 5),
                    AgentHookEvent("PostToolUse", 5),
                    AgentHookEvent("TaskStart", 5),
                    AgentHookEvent("TaskResume", 5),
                    AgentHookEvent("TaskCancel", 5),
                    AgentHookEvent("TaskComplete", 5),
                    AgentHookEvent("PreCompact", 5),
                ],
                verdict: .none,
                // 判据退一层到 Cline 自己的目录（`Hooks/` 由我们按需创建）。
                gatePath: "Documents/Cline"
            )
        case .grok:
            return AgentHookSpec(
                format: .nested,
                configPath: "hooks/agent-island.json",
                rootEnvVar: "GROK_HOME",
                configKey: "hooks",
                events: Self.grokEvents,
                verdict: .claudeEnvelope
            )
        case .trae:
            // 注意：Trae IDE 与 Trae CLI 共用 `~/.trae` 这个根，因此两者的
            // `requiresExistingRoot` 都是真——一旦有谁被允许凭空创建该目录，另一个的
            // 「工具装没装」判定就会被顺带解锁（会在没装 Trae IDE 的机器上写出它的配置）。
            // 事件表与 Cursor 逐字相同（Trae 的 hook 契约照抄 Cursor），共用一份常量。
            return AgentHookSpec(
                format: .traeIDE,
                configPath: ".trae/hooks.json",
                rootEnvVar: nil,
                configKey: "hooks",
                events: Self.cursorStyleEvents,
                verdict: .none
            )
        case .traeCli:
            return AgentHookSpec(
                format: .traecli,
                configPath: ".trae/traecli.yaml",
                rootEnvVar: nil,
                configKey: "hooks",
                events: [
                    AgentHookEvent("session_start", 5),
                    AgentHookEvent("session_end", 5),
                    AgentHookEvent("user_prompt_submit", 5),
                    AgentHookEvent("pre_tool_use", 5),
                    AgentHookEvent("post_tool_use", 5),
                    AgentHookEvent("post_tool_use_failure", 5),
                    AgentHookEvent("permission_request", 86400, blocking: true),
                    AgentHookEvent("notification", 86400),
                    AgentHookEvent("subagent_start", 5),
                    AgentHookEvent("subagent_stop", 5),
                    AgentHookEvent("stop", 5),
                    AgentHookEvent("pre_compact", 5),
                    AgentHookEvent("post_compact", 5),
                ],
                verdict: .claudeEnvelope
            )
        }
    }

    // MARK: - 共用事件表

    /// Claude fork 的基础事件集（不含 PermissionRequest：这些 fork 是否实现该事件
    /// 没有证据，宁可不装，也不要写一个永远不触发的配置）。
    private static let claudeFamilyEvents: [AgentHookEvent] = [
        AgentHookEvent("UserPromptSubmit", 5),
        AgentHookEvent("PreToolUse", 5),
        AgentHookEvent("PostToolUse", 5),
        AgentHookEvent("SessionStart", 5),
        AgentHookEvent("SessionEnd", 5),
        AgentHookEvent("Stop", 5),
        AgentHookEvent("SubagentStart", 5),
        AgentHookEvent("SubagentStop", 5),
        AgentHookEvent("Notification", 86400),
        AgentHookEvent("PreCompact", 5),
    ]

    /// Qoder 这类「有自己文档化 PermissionRequest」的 Claude fork：在基础集上加审批事件。
    private static let claudeFamilyEventsWithApproval: [AgentHookEvent] = [
        AgentHookEvent("UserPromptSubmit", 5),
        AgentHookEvent("PreToolUse", 5),
        AgentHookEvent("PostToolUse", 5),
        AgentHookEvent("PostToolUseFailure", 5),
        AgentHookEvent("PermissionRequest", 86400, blocking: true),
        AgentHookEvent("Stop", 5),
        AgentHookEvent("SubagentStart", 5),
        AgentHookEvent("SubagentStop", 5),
        AgentHookEvent("SessionStart", 5),
        AgentHookEvent("SessionEnd", 5),
        AgentHookEvent("Notification", 86400),
        AgentHookEvent("PreCompact", 5),
    ]

    /// Cursor / Trae 系（camelCase 事件，无审批事件）。
    private static let cursorStyleEvents: [AgentHookEvent] = [
        AgentHookEvent("beforeSubmitPrompt", 5),
        AgentHookEvent("beforeShellExecution", 5),
        AgentHookEvent("afterShellExecution", 5),
        AgentHookEvent("beforeReadFile", 5),
        AgentHookEvent("afterFileEdit", 5),
        AgentHookEvent("beforeMCPExecution", 5),
        AgentHookEvent("afterMCPExecution", 5),
        AgentHookEvent("afterAgentThought", 5),
        AgentHookEvent("afterAgentResponse", 5),
        AgentHookEvent("stop", 5),
    ]

    /// Grok CLI 的受管事件（`stop_failure` 在归一表里与 `Stop` 同义）。
    private static let grokEvents: [AgentHookEvent] = [
        AgentHookEvent("SessionStart", 5),
        AgentHookEvent("UserPromptSubmit", 5),
        AgentHookEvent("PreToolUse", 5),
        AgentHookEvent("PostToolUse", 5),
        AgentHookEvent("PostToolUseFailure", 5),
        AgentHookEvent("PermissionDenied", 5),
        AgentHookEvent("Stop", 5),
        AgentHookEvent("StopFailure", 5),
        AgentHookEvent("Notification", 5),
        AgentHookEvent("SubagentStart", 5),
        AgentHookEvent("SubagentStop", 5),
        AgentHookEvent("PreCompact", 5),
        AgentHookEvent("PostCompact", 5),
        AgentHookEvent("SessionEnd", 5),
    ]
}

nonisolated extension AgentKind {
    /// 「配置目录覆盖」实际作用在哪个目录：**安装器写 hook 的那个根**。
    ///
    /// 对绝大多数 Agent 来说它就是 `provider.paths().configDir`；**Cline 是例外**——它的对话
    /// 记录在 VSCode globalStorage，而目录选择器管的是 hook 根（`~/Documents/Cline`）。
    /// 显示错的那一个会让用户以为选的是记录目录，所以界面的「自动检测」与选择面板的起始目录
    /// 都走这里。
    func directoryOverrideRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let gatePath = hookSpec?.gatePath {
            return home.appendingPathComponent(gatePath)
        }
        return AgentRegistry.provider(for: self).paths()?.configDir
    }
}

// MARK: - hook 脚本

/// 上报脚本在机器上的唯一落点。
///
/// 所有「配置文件型」Agent（Claude 系、Codex、Gemini、Cursor、Copilot、Kimi、
/// Cline、Grok、Trae、TraeCli）都引用**同一个**脚本文件：一份实现、一处升级，
/// 不会出现两份副本各自漂移。Claude 原先装在 `~/.claude/hooks/`，那条路径已废弃
/// （`HookInstaller` 会在安装时清理旧副本）。
nonisolated enum AgentHookScript {
    /// 脚本文件名（仓库资源同名）。
    static let fileName = "agent-island-state.py"
    /// 改名前的脚本名，安装与卸载都要一并清理。
    static let legacyFileNames = ["claude-island-state.py"]
    /// 应用自己的 hooks 目录（相对用户主目录）。
    static let directoryComponents = [".agent-island", "hooks"]

    /// 脚本所在目录。
    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directoryComponents.reduce(home) { $0.appendingPathComponent($1) }
    }

    /// 脚本文件路径。
    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent(fileName)
    }

    /// 写进各 Agent 配置里的 shell 路径（`~` 展开后的绝对路径，避免 IDE 环境的
    /// 波浪号解析差异）。
    static func shellPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        fileURL(home: home).path
    }
}
