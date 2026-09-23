//
//  AgentKind.swift
//  AgentIsland
//
//  notch 支持监控的编码 Agent 集合。所有与具体 Agent 相关的差异（路径、记录格式、
//  实时事件接入）都收敛到这个枚举上，其余代码保持 Agent 无关。
//  `rawValue` 同时是集成侧的 `--source` 取值与 CodeIsland 的 source id：两侧对同一
//  个工具必须用同一个字符串，否则事件会被算到别的 Agent 名下。
//

import Foundation

/// 某个 Agent 的审批能力：决定「刘海上的批准/拒绝能否真正回传给该 Agent」，以及
/// 该 Agent 用哪个事件名请求审批。纯数据，避免能力判断散落到各个调用点。
nonisolated struct ApprovalCapability: Sendable {
    /// 刘海上的决定能否真正回传给该 Agent（为假时 UI 只提示「在终端中批准」）。
    let canDecideRemotely: Bool
    /// 该 Agent 的集成会阻塞等待应答；决定服务端是否保留 socket fd。
    let waitsForDecision: Bool
    /// 该 Agent 用来请求审批的事件名。
    let requestEvent: String
}

/// 受支持的编码 Agent CLI。
nonisolated enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Anthropic Claude Code（`claude`）。
    case claudeCode = "claude"
    /// Oh My Pi（`omp`）。
    case ohMyPi = "omp"
    /// Pi coding agent（`pi`）。
    case pi = "pi"
    /// OpenCode（`opencode`）。
    case opencode = "opencode"
    /// OpenAI Codex（`codex`）。
    case codex = "codex"
    /// Google Gemini CLI（`gemini`）。
    case gemini = "gemini"
    /// Cursor（`cursor-agent`；IDE 与 CLI 共用同一份 hooks.json）。
    case cursor = "cursor"
    /// GitHub Copilot CLI（`copilot`）。
    case copilot = "copilot"
    /// Qoder（`qodercli`；Claude Code fork）。
    case qoder = "qoder"
    /// Factory（`droid`；Claude Code fork，source id 沿用官方的 `droid`）。
    case factory = "droid"
    /// CodeBuddy（`codebuddy`；Claude Code fork）。
    case codeBuddy = "codebuddy"
    /// Kimi Code CLI（`kimi`）。
    case kimi = "kimi"
    /// Cline（VSCode 扩展，没有 CLI 二进制；hook 是 `~/Documents/Cline/Hooks/<Event>` 文件）。
    case cline = "cline"
    /// Grok CLI（`grok`）。
    case grok = "grok"
    /// Trae（IDE，`coco`；唯一没有磁盘记录解析的接入）。
    case trae = "trae"
    /// Trae CLI（`traecli`；hook 写在 `~/.trae/traecli.yaml` 的托管块里）。
    case traeCli = "traecli"
    /// DeepSeek Harness（`dsh`；插件运行时，事件由外部 dsh 插件直接写 socket）。
    case deepSeekHarness = "dsh"

    var id: String { rawValue }

    /// 面向用户的产品名。产品名在 `zh-Hans` 里是原文映射，保留 key 只是为了让
    /// 这些名字日后可被覆盖，而不是硬编码在代码里。本类型是 `nonisolated`，
    /// 因此走 `LocalizationManager` 的非隔离静态入口。
    var displayName: String {
        switch self {
        case .claudeCode: return LocalizationManager.t("Claude Code")
        case .ohMyPi: return LocalizationManager.t("Oh My Pi")
        case .pi: return LocalizationManager.t("Pi")
        case .opencode: return LocalizationManager.t("OpenCode")
        case .codex: return LocalizationManager.t("Codex")
        case .gemini: return LocalizationManager.t("Gemini CLI")
        case .cursor: return LocalizationManager.t("Cursor")
        case .copilot: return LocalizationManager.t("Copilot")
        case .qoder: return LocalizationManager.t("Qoder")
        case .factory: return LocalizationManager.t("Factory")
        case .codeBuddy: return LocalizationManager.t("CodeBuddy")
        case .kimi: return LocalizationManager.t("Kimi Code CLI")
        case .cline: return LocalizationManager.t("Cline")
        case .grok: return LocalizationManager.t("Grok CLI")
        case .trae: return LocalizationManager.t("Trae")
        case .traeCli: return LocalizationManager.t("Trae CLI")
        case .deepSeekHarness: return LocalizationManager.t("DeepSeek Harness")
        }
    }

    /// 紧凑标签，用于会话行、角标等密集 UI。
    var shortName: String {
        switch self {
        case .claudeCode: return LocalizationManager.t("Claude")
        case .ohMyPi: return LocalizationManager.t("OMP")
        case .pi: return LocalizationManager.t("Pi")
        case .opencode: return LocalizationManager.t("OpenCode")
        case .codex: return LocalizationManager.t("Codex")
        case .gemini: return LocalizationManager.t("Gemini")
        case .cursor: return LocalizationManager.t("Cursor")
        case .copilot: return LocalizationManager.t("Copilot")
        case .qoder: return LocalizationManager.t("Qoder")
        case .factory: return LocalizationManager.t("Factory")
        case .codeBuddy: return LocalizationManager.t("CodeBuddy")
        case .kimi: return LocalizationManager.t("Kimi")
        case .cline: return LocalizationManager.t("Cline")
        case .grok: return LocalizationManager.t("Grok")
        case .trae: return LocalizationManager.t("Trae")
        case .traeCli: return LocalizationManager.t("Trae CLI")
        case .deepSeekHarness: return LocalizationManager.t("DSH")
        }
    }

    /// CLI 可执行文件名，用于进程发现；扩展宿主（Cline）没有 CLI，返回空串。
    var binaryName: String {
        switch self {
        case .claudeCode: return "claude"
        case .ohMyPi: return "omp"
        case .pi: return "pi"
        case .opencode: return "opencode"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .cursor: return "cursor-agent"
        case .copilot: return "copilot"
        case .qoder: return "qodercli"
        case .factory: return "droid"
        case .codeBuddy: return "codebuddy"
        case .kimi: return "kimi"
        case .cline: return ""
        case .grok: return "grok"
        case .trae: return "coco"
        case .traeCli: return "traecli"
        case .deepSeekHarness: return "dsh"
        }
    }

    /// 该 Agent 的审批能力。`canDecideRemotely` 为真时 notch 才给出批准/拒绝
    /// 入口并回传决定；`waitsForDecision` 与 `requestEvent` 描述集成侧的等待
    /// 方式与事件名（扩展 / 插件 / hook 脚本据此实现阻塞闸门）。
    ///
    /// 只有装了「阻塞审批 hook」的 Agent 才为真：Claude 系（含 Qoder 这类 fork）、
    /// omp/pi 的闸门扩展、opencode 的插件、Gemini 的 `BeforeTool`、Codex 的
    /// `PermissionRequest`、TraeCli 的 `permission_request`。其余工具的事件表里
    /// 没有可回写决定的审批事件（Cursor / Copilot / Trae / Cline / Kimi / Factory /
    /// CodeBuddy / Grok / DSH），刘海只显示状态。
    var approval: ApprovalCapability {
        switch self {
        case .claudeCode, .qoder, .gemini, .codex, .traeCli:
            return .init(
                canDecideRemotely: true, waitsForDecision: true,
                requestEvent: "PermissionRequest")
        case .ohMyPi, .pi, .opencode:
            return .init(
                canDecideRemotely: true, waitsForDecision: true, requestEvent: "ToolApproval")
        case .factory, .codeBuddy, .cursor, .copilot, .kimi, .cline, .grok, .trae,
            .deepSeekHarness:
            return .init(
                canDecideRemotely: false, waitsForDecision: false, requestEvent: "")
        }
    }

    /// 是否需要用户安装集成（hook 脚本 / 扩展 / 插件）才能上报实时事件。
    /// 为 false 时仅靠读取记录推断状态。
    ///
    /// DSH 是插件运行时：事件由外部 dsh 插件直接写 socket，本应用既没有可写的
    /// 配置也没有可装的脚本，因此不参与集成安装。
    var requiresIntegrationInstall: Bool {
        switch self {
        case .deepSeekHarness: return false
        default: return true
        }
    }

    /// Claude 系（Claude Code 及其 fork）：同一条 hook 契约 + 同一套 JSONL 记录格式。
    /// Qoder / Factory / CodeBuddy 都从 Claude Code 派生，事件名、记录字段与
    /// `AskUserQuestion` 工具名都一致。
    var isClaudeFamily: Bool {
        switch self {
        case .claudeCode, .qoder, .factory, .codeBuddy: return true
        default: return false
        }
    }

    /// 该 Agent 用来派生 subAgent 的工具名：
    /// - Claude 系：`Agent`（新名）/ `Task`（旧名）
    /// - omp / pi / opencode：`task`
    /// - 其余：各自的记录里没有可识别的派生工具名，返回空集（宁可不认，也不误认）
    var subagentToolNames: [String] {
        if isClaudeFamily { return ["Agent", "Task"] }
        switch self {
        case .ohMyPi, .pi, .opencode: return ["task"]
        default: return []
        }
    }

    /// 启用口径改成「显式启用集合」（默认全关）之前，应用**默认启用**的那几个 Agent。
    ///
    /// 只在一次性迁移里用（`AppSettings.migrateAgentEnablementIfNeeded()`）：升级用户
    /// 原本在监控的就是这几个，不该因为换口径而掉线；而本特性之后新接入的 Agent 一律
    /// 保持关闭（它们是「旧口径默认全开」的副作用，不是用户的选择）。
    static let defaultEnabledBeforeOptIn: [AgentKind] = [.claudeCode, .ohMyPi, .pi, .opencode]

    /// 全部 Agent 的 subAgent 派生工具名并集。实时事件只带工具名、不带 Agent
    /// 归属，因此按并集判定；各 Agent 之间名称互不冲突。
    static let allSubagentToolNames: Set<String> = Set(allCases.flatMap(\.subagentToolNames))

    /// 该 Agent 的集成是否会**上报子 Agent 内部的工具调用**。只有 Claude 系具备这条
    /// 通道（hook 的 SubagentStart/Stop + 子 Agent 记录，fork 沿用同一契约）；
    /// omp/pi 的扩展与 opencode 插件只上报根会话，因此对它们不能把「Task 运行期间
    /// 到达的其它工具」当成子 Agent 内部调用。
    var reportsSubagentInnerTools: Bool {
        isClaudeFamily
    }

    /// 该 Agent 的「交互工具」：命中它们的待批不是「批准/拒绝」，而是要在刘海上
    /// 作答（选项、自由文本），因此卡片必须换成提问界面，给 Allow/Deny 会误导。
    /// - Claude 系：`AskUserQuestion`
    /// - omp / pi：`ask`（扩展把它报成 `ToolApproval` + `ask` 负载）
    /// - OpenCode：`question`（插件把 `question.asked` 报成 `ToolApproval` + `ask` 负载，
    ///   作答回写 `POST /question/{id}/reply`——工具名必须与插件里的 `TOOL_QUESTION` 一致）
    var interactiveToolNames: Set<String> {
        if isClaudeFamily { return ["AskUserQuestion"] }
        switch self {
        case .ohMyPi, .pi: return ["ask"]
        case .opencode: return ["question"]
        default: return []
        }
    }

    /// 该工具名在本 Agent 下是否需要在刘海上作答。
    func isInteractiveTool(_ toolName: String) -> Bool {
        interactiveToolNames.contains(toolName)
    }
}
