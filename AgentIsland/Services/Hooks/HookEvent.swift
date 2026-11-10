//
//  AgentIsland/Services/Hooks/HookEvent.swift
//  AgentIsland
//
//  hook 事件的线上结构：事件信封、`ask` 提问负载、回传响应与作答折算的纯函数。
//

import Foundation

/// Event received from an agent's live integration (Claude Code hooks, pi/omp
/// extension, OpenCode plugin).
nonisolated struct HookEvent: Codable, Sendable {
    /// 集成侧判定「命中危险命令名单」的档位取值（`approval_kind`）；只影响刘海展示强度。
    private static let criticalApprovalKind = "critical"

    /// 集成侧「写档」与「执行档」的取值（`approval_kind`）：这两档在「只问危险命令」档下放行。
    private static let writeApprovalKind = "write"
    private static let execApprovalKind = "exec"
    /// 集成侧的默认降级档；不是这一档就要在卡片上提示「闸门已降级」。
    private static let defaultDegradationTier = "notify-only"
    /// 会话身份三件套与 `toolUseId` 一样是 `var`：三处「复制并改写」的入口
    /// （`withToolUseId` / `withLivePending` / `owning`）都靠副本语义保真，不再走全参重建。
    var sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    /// 工具调用 id；`var` 只为 `withToolUseId(_:)` 的副本语义（见 `sessionId` 的说明）。
    var toolUseId: String?
    let notificationType: String?
    let message: String?
    /// 集成是否要求应用回传决定（`expects_response`）。缺省 nil = 只展示，不登记待批。
    let wantsResponse: Bool?
    /// 集成侧判定的审批档位（`allow|write|exec|critical`）；只影响展示强度，缺省 nil = 老集成。
    let approvalKind: String?
    /// 集成侧烘焙的降级档（`notify-only` / `strict` / `read-only-allow`）。
    let degradation: String?
    /// 集成侧闸门是否启用；显式 false 说明「应用不在时按降级档放行」这件事发生过。
    let gateEnabled: Bool?
    /// 集成侧上报「这次审批由 Agent 自己的终端弹窗负责」（`omp_owns_approval`）。
    let ompOwnsApproval: Bool?
    /// 集成侧 `ask` 工具的问题负载（`ask`）；其它工具有待批时该字段缺省。
    let ask: AskPayload?
    /// 上报方所属 Agent；旧版 Claude hook 脚本不带该字段，按 Claude 处理。
    var agent: String?
    /// 记录文件路径，由非 Claude 集成上报，避免应用再按目录反推。
    let sessionFile: String?
    /// Paseo（`@getpaseo/server`）托管终端的 id（集成读 `PASEO_TERMINAL_ID` 上报）。
    /// 有值时「发消息 / 中断」不必走 tmux：`paseo terminal send-keys <id> …` 直接写 pty。
    let paseoTerminalId: String?
    /// Paseo 自己给该终端解析出的 CLI 绝对路径（集成读 `PASEO_HOOK_CLI` 上报）。
    /// 应用是 GUI 进程、PATH 里没有 nvm/bin，因此优先用它而不是自己猜。
    let paseoCliPath: String?
    /// 子 Agent 实例标识（omp 的 job 名，如 `EchoAlpha`）。
    let subagentId: String?
    /// 子 Agent 类型名（omp 的 agent 名，如 `scout` / `sonic`）。
    let subagentAgent: String?
    /// 子 Agent 状态：`started` / `running` / `completed` / `failed` / `aborted`。
    let subagentStatus: String?
    /// 子 Agent 当前正在执行的工具名；空闲时为空。
    let subagentCurrentTool: String?
    /// 子 Agent 的任务描述（`SubagentLifecycle` 带 `description`，进度事件带 `task`）。
    let subagentTask: String?
    /// 派生该子 Agent 的父会话工具调用（task 工具的 tool_use_id）。
    var parentToolCallId: String?
    /// 子 Agent 自己的记录文件路径。
    let subagentSessionFile: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message, agent
        case wantsResponse = "expects_response"
        case approvalKind = "approval_kind"
        case degradation
        case gateEnabled = "gate_enabled"
        case ompOwnsApproval = "omp_owns_approval"
        case ask
        case sessionFile = "session_file"
        case paseoTerminalId = "paseo_terminal_id"
        case paseoCliPath = "paseo_cli_path"
        case subagentId = "subagent_id"
        case subagentAgent = "subagent_agent"
        case subagentStatus = "subagent_status"
        case subagentCurrentTool = "subagent_current_tool"
        case subagentTask = "subagent_task"
        case parentToolCallId = "parent_tool_call_id"
        case subagentSessionFile = "subagent_session_file"
    }

    /// 事件所属 Agent（缺省视为 Claude Code，兼容已安装的旧 hook 脚本）。
    var agentKind: AgentKind {
        guard let agent, let kind = AgentKind(rawValue: agent) else { return .claudeCode }
        return kind
    }

    /// 会话键：Agent + 会话 id。
    var sessionKey: SessionKey {
        SessionKey(agent: agentKind, sessionId: sessionId)
    }

    /// Create a copy with updated toolUseId
    init(
        sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?,
        tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?,
        notificationType: String?,
        message: String?, agent: String? = nil, sessionFile: String? = nil
    ) {
        self.init(
            sessionId: sessionId, cwd: cwd, event: event, status: status, pid: pid, tty: tty,
            tool: tool, toolInput: toolInput, toolUseId: toolUseId,
            notificationType: notificationType,
            message: message, agent: agent, sessionFile: sessionFile,
            subagentId: nil, subagentAgent: nil, subagentStatus: nil, subagentCurrentTool: nil,
            subagentTask: nil, parentToolCallId: nil, subagentSessionFile: nil,
            paseoTerminalId: nil, paseoCliPath: nil
        )
    }

    init(
        sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?,
        tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?,
        notificationType: String?,
        message: String?, agent: String?, sessionFile: String?, subagentId: String?,
        subagentAgent: String?, subagentStatus: String?, subagentCurrentTool: String?,
        subagentTask: String?, parentToolCallId: String?, subagentSessionFile: String?,
        wantsResponse: Bool? = nil,
        approvalKind: String? = nil, degradation: String? = nil, gateEnabled: Bool? = nil,
        ompOwnsApproval: Bool? = nil, ask: AskPayload? = nil,
        paseoTerminalId: String? = nil, paseoCliPath: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.agent = agent
        self.sessionFile = sessionFile
        self.subagentId = subagentId
        self.subagentAgent = subagentAgent
        self.subagentStatus = subagentStatus
        self.subagentCurrentTool = subagentCurrentTool
        self.subagentTask = subagentTask
        self.parentToolCallId = parentToolCallId
        self.subagentSessionFile = subagentSessionFile
        self.wantsResponse = wantsResponse
        self.approvalKind = approvalKind
        self.degradation = degradation
        self.gateEnabled = gateEnabled
        self.ompOwnsApproval = ompOwnsApproval
        self.ask = ask
        self.paseoTerminalId = paseoTerminalId
        self.paseoCliPath = paseoCliPath
    }

    /// 是否为子代理总线事件（omp/pi 的 `task:subagent:*` 上报，不是会话自身的一轮活动）。
    nonisolated var isSubagentBusEvent: Bool {
        event == "SubagentLifecycle" || event == "SubagentProgress"
    }

    /// 复制一份事件，改写到另一个会话、并指定它应挂靠的父工具调用。
    ///
    /// 子代理实例上报的是「它自己派出的子代理」，事件里的 `parent_tool_call_id` 指向上一层
    /// 会话里的工具调用（本应用没有那张卡片），因此折算落点时统一改成「上报者所属卡片」。
    ///
    /// **用复制语义而不是全参重建**（评审 F2）：重建会把没列进参数的字段静默丢成默认值——
    /// 其中就有进程内的 `hasLivePending`（子代理进度事件因此又能把相位推回 `processing`，
    /// 正是本次要修的症状）以及 `expects_response` / `ask` 这类信封字段。
    nonisolated func owning(sessionKey: SessionKey, parentToolCallId: String?) -> HookEvent {
        var copy = self
        copy.sessionId = sessionKey.sessionId
        copy.agent = sessionKey.agent.rawValue
        copy.parentToolCallId = parentToolCallId ?? copy.parentToolCallId
        return copy
    }

    /// 复制事件并只替换 `toolUseId`，其余字段（含 `agent` / `sessionFile` / 子 Agent
    /// 归属）原样保留。不要用便利 init 重建：那会把 agent 与子 Agent 字段重置为 nil，
    /// 使排队中的审批被重建成 Claude 会话（幽灵会话 + 真实会话卡在等待批准）。
    func withToolUseId(_ toolUseId: String) -> HookEvent {
        var copy = self
        copy.toolUseId = toolUseId
        return copy
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(
                PermissionContext(
                    toolUseId: toolUseId ?? "",
                    toolName: tool ?? "unknown",
                    toolInput: toolInput,
                    receivedAt: Date()
                ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    /// 该事件是否要求应用回传决定。
    /// - Claude 旧契约：`PermissionRequest` + `waiting_for_approval`（逐字不变）。
    /// - omp / pi / opencode：`ToolApproval` + **等待态** + 显式 `expects_response`；
    ///   只展示的集成（`expects_response: false` / 缺省）不满足该条件，因此不会被
    ///   登记成待批。
    ///
    /// 三个条件都要。只认 `expects_response` 时，一条 `status != waiting_for_approval`
    /// 的信封也会被登记成待批——那条连接的卡片与相位来源（`determinePhase` 的
    /// `ToolApproval` 兜底分支）不是同一判据，长期看会漂移成「登记了但没人能撤」的
    /// 悬挂连接。集成侧三处带 `expects_response: true` 的信封（闸门 `pi-extension:1230`、
    /// 影子 ask `:1557`、opencode 插件 `:234`）status 都是 `waiting_for_approval`，
    /// 因此收紧不影响任何既有集成；真收到不合规信封时的降级是**立即关闭 fd**，
    /// 集成侧按「拿不到决定」回落自己的原生路径（不会挂住）。
    nonisolated var expectsResponse: Bool {
        if event == "PermissionRequest" && status == "waiting_for_approval" { return true }
        return event == "ToolApproval" && status == "waiting_for_approval" && wantsResponse == true
    }

    /// 交付这一条事件时，该会话**是否正有待批在等**。
    ///
    /// 由 `HookSocketServer` 在交给事件处理者之前盖章：待批是已经发生的事实（服务端还攥着
    /// 那条等应答的连接），状态上报只是描述。相位机据此把「等待审批」钉住（见
    /// `SessionStore.processHookEvent`）。**不是线上字段**：不进 `CodingKeys`，只在进程内传递。
    var hasLivePending = false

    /// 复制一份并盖上「该会话此刻有待批在等」的章。
    func withLivePending(_ value: Bool) -> HookEvent {
        var copy = self
        copy.hasLivePending = value
        return copy
    }

    /// 是否为「危险命令」档：卡片据此用警示色；未知档位一律按普通档处理。
    nonisolated var isCriticalApproval: Bool {
        approvalKind == Self.criticalApprovalKind
    }

    /// 是否要在卡片上提示「闸门已降级」：闸门未启用，或降级档不是默认档。
    nonisolated var isGateDegraded: Bool {
        if gateEnabled == false { return true }
        guard let degradation else { return false }
        return degradation != Self.defaultDegradationTier
    }

    /// 这一条待批是否落在用户当前档位之外（落在档位外 = 应用直接放行、不上卡）。
    ///
    /// **判定权最终在应用**：档位是应用自己的设置，集成只是把它烘焙进扩展文件。而集成是
    /// **进程启动时求值一次**的——改档位前启动的会话会继续按旧档位问（实测症状：改完
    /// 「只问危险命令」后，已经跑着的会话仍旧每条写 / 执行都上卡）。应用在这里按当前档位
    /// 再判一次，与集成侧同一口径，只是让档位对已跑的会话也立刻生效；这也是 CodeIsland 的
    /// 做法：政策（自动批准）留在应用侧，由应用自己决定哪些许可不必弹出来。
    ///
    /// 只管闸门信封（`ToolApproval` + `expects_response`）：
    /// * Claude 的 `PermissionRequest` 是它自己的对话框，档位管不着；
    /// * 带 `ask` 载荷的信封是「要回答」而不是「要许可」——放行等于把提问取消掉。
    ///
    /// 会拦的档位只有两种：`writesAndExec`（写 / 执行都拦）与 `criticalOnly`（只拦危险命令）。
    /// 其余档位（当前只有「始终允许」）语义就是「一律不问」，一律放行——判定按**取值**而不是
    /// 逐个列出，档位取值本身由 `ApprovalAskScope` 收口。
    ///
    /// 档位取值缺失或不认识时在会拦的档位下**照常上卡**：宁可多问一次，也不静默放行一条
    /// 看不懂的调用。
    nonisolated func isAutoAllowedByScope(_ scope: ApprovalAskScope) -> Bool {
        guard event == "ToolApproval", expectsResponse, ask == nil else { return false }
        if scope == .writesAndExec { return false }
        guard scope == .criticalOnly else { return true }
        return approvalKind == Self.writeApprovalKind || approvalKind == Self.execApprovalKind
    }
}

// MARK: - Ask 负载（交互式提问）

/// `ask` 工具给出的一个选项。
nonisolated struct AskOption: Codable, Equatable, Sendable {
    /// 选项文本；用户选中的就是这个文本，回传时原样带回。
    let label: String
    /// 选项的补充说明（副标题）。
    let description: String?

    init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// `ask` 工具提出的一个问题。
nonisolated struct AskQuestion: Codable, Equatable, Sendable {
    /// 问题 id；作答字典的键就是它。
    let id: String
    /// 问题正文。
    let question: String
    /// 问题的短标题（可缺省）。
    let header: String?
    /// 是否多选；缺省按单选。
    let multiSelect: Bool
    /// 是否允许自由文本作答（可缺省）。
    let freeText: Bool
    /// 候选选项；空数组表示只能自由文本作答。
    let options: [AskOption]

    init(
        id: String, question: String, header: String? = nil, multiSelect: Bool = false,
        freeText: Bool = false, options: [AskOption] = []
    ) {
        self.id = id
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.freeText = freeText
        self.options = options
    }

    /// 载荷里这两个开关可能缺省，按 false 处理；选项缺省按空数组。
    private enum CodingKeys: String, CodingKey {
        case id, question, header
        case multiSelect = "multi_select"
        case freeText = "free_text"
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        freeText = try container.decodeIfPresent(Bool.self, forKey: .freeText) ?? false
        options = try container.decodeIfPresent([AskOption].self, forKey: .options) ?? []
    }
}

/// `ask` 工具的完整问题集（信封里的 `ask` 字段）。
nonisolated struct AskPayload: Codable, Equatable, Sendable {
    let questions: [AskQuestion]
}

/// Response to send back to the hook
nonisolated struct HookResponse: Codable {
    /// `allow` / `deny` / `ask` 三个取值的语义逐字不变；`answer` 是 `ask` 工具的回答。
    let decision: String
    /// 提问作答（`decision == "answer"`）：键为问题 id，值为选中的 label 或自由文本。
    /// 其余决定一律为 nil。
    let answers: [String: [String]]?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case decision, answers, reason
    }

    /// 手写编码而不是用合成的：它写死了「哪些键会出现」这条契约——缺省的字段一律不
    /// 出现在字节里（因此 `allow` / `deny` / `ask` 的字段集合与加 `answers` 之前相同），
    /// 也是消融实验唯一需要改的一行。键的**顺序**不在这里决定，由写回时用的
    /// `sortedKeys` 编码器保证（见 `responseEncoder`）。
    /// - Parameter encoder: 目标编码器。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(answers, forKey: .answers)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

// MARK: - 作答决定

/// 把用户在刘海上做出的选择折成回传决定。纯函数、无状态，因此「选择 → 答案 JSON」
/// 这一段可以脱离 UI 独立验证。
nonisolated enum AskAnswerBuilder {
    /// 集成侧据此把答案交给模型继续。
    static let decisionAnswer = "answer"
    /// 用户放弃作答：沿用既有 deny 语义，Agent 按「拒绝/未作答」继续。
    static let decisionDeny = "deny"

    /// 归一化一个回传决定：`allow` / `deny` / `ask` **原样透传**（既有语义逐字不变，
    /// 编码结果里不会多出 `answers` 键）；`answer` 且**一个键都没有**时折成 `deny`。
    /// 放在服务端这一层是为了让「整题都没答」不可能以 `answer` 发出去——写回 socket 前必过这里。
    /// 注意「值为空数组」不是「没答」：那是多选题的「明确一个都不选」，要原样发出（见 `response`）。
    static func normalized(
        decision: String, answers: [String: [String]]?, reason: String?
    ) -> HookResponse {
        guard decision == decisionAnswer else {
            return HookResponse(decision: decision, answers: nil, reason: reason)
        }
        return response(answers: answers ?? [:], reason: reason)
    }

    /// 由「问题 id → 答案」构造回传响应。
    ///
    /// **不变量（与集成侧冻结的语义，逐条对应）**：
    /// * **键存在** = 该题被作答；
    /// * **值为空数组** = 多选题的「明确一个都不选」，必须**原样**带着走；
    /// * **键缺失** = 该题未作答。
    /// 因此这里**不再过滤空数组**：把空数组当「没答」会让「明确不选」退化成「缺键」，
    /// 集成侧就再也区分不出这两件事了。
    ///
    /// 只有**所有键都缺失**（字典为空：用户直接跳过，或自由文本只输了空白）时才不发
    /// `answer`——那才是「放弃作答」，折成 `deny` 更接近用户意图，也让集成侧的闸门走
    /// 既有的拒绝分支。
    static func response(answers: [String: [String]], reason: String? = nil) -> HookResponse {
        guard !answers.isEmpty else {
            return HookResponse(decision: decisionDeny, answers: nil, reason: reason)
        }
        return HookResponse(decision: decisionAnswer, answers: answers, reason: reason)
    }
}

// MARK: - 工具入参拍平

nonisolated extension HookEvent {
    /// 工具入参拍平成 `[String: String]`（`ToolCallItem.input` / `SubagentToolCall.input` 用）。
    ///
    /// 这段循环原先在 `SessionStore` 的工具跟踪与子 Agent 跟踪里各写一遍；两处口径必须一致，
    /// 否则同一个工具在顶层卡片与子 Agent 卡片上会显示不同的入参。
    var flattenedToolInput: [String: String] {
        guard let toolInput else { return [:] }
        var flattened: [String: String] = [:]
        for (key, value) in toolInput {
            if let scalar = value.scalarString { flattened[key] = scalar }
        }
        return flattened
    }
}
