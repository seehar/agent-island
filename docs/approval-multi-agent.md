# AgentIsland 刘海审批扩展到 omp / pi —— 实施方案

- 目标仓库：`/Users/seehar/work/code/mine/agent-island`（只读测绘，本文件是唯一产物）
- 参考仓库：`/Users/seehar/work/code/git/CodeIsland`、`/Users/seehar/work/code/git/oh-my-pi`、pi 0.85.1 安装包
- 输入报告：`/tmp/ai-approve/ws-a-omp-pi-approval.md`（WS-A）、`ws-b-codeisland.md`（WS-B）、`ws-c-island-gap.md`（WS-C）、`ws-d-claude-protocol-opencode.md`（WS-D）、**`ws-e-adversarial.md`（WS-E，独立对抗评估，含 `T1–T10` 与 `R1–R3` 实验）、`ws-f-worktree-state.md`（WS-F，工作树状态与按符号名的行号表）**
- 日期：2026-09-20（**v2 修订**同日）
- 版本：**v2** —— v1 之后并入 WS-E 的对抗结论与 WS-F 的工作树取证；凡本次改动处均标注「**v2 修订**」

**证据约定**：`文件:行` 一律沿用**亲自复核**的行号（WS-C 的行号整体偏移约 +40，见附录 B；WS-F 独立复核了本文档的行号表，见 §0.2）；WS-A 的 `RUN A–J` / `TUI-1/2` / `RPC-1/2` 与 WS-E 的 `T1–T10` / `R1–R3` 均为隔离环境真实运行结论，可直接引用；本方案作者新增实测记 `E1–E7`（附录 A）；`[推断]` 表示未逐条实测。

**本文档的用法**：**§0 是开工前置（并行 WIP 协调，先读）**；§1 先给结论，§3 是决策对比，§4–§7 是「照此编码」级别的契约，§8 是排期，§9 是验收，§10 是待你拍板的 6 件事。

---

## 0. 开工前置：并行 WIP 协调（v2 修订）

**先读这一节再动手**：本仓库 `main` 工作树此刻有**另一场会话的未提交 WIP**，且与本方案的文件重叠。

| 项 | 事实（WS-F，采集 2026-09-20 17:48:40） |
| --- | --- |
| 基线 | `main@0ae1e9c`；无 stash、索引干净、**无未跟踪文件** |
| 在飞的 WIP | 12 个已修改/已删除文件，+643 / −568，是同一场「**omp/pi 子 Agent 追踪**」特性：`HookEvent` 新增 7 个 `subagent*` / `parentToolCallId` 字段；pi 扩展订阅 `task:subagent:lifecycle\|progress`；`ChatView` 新增 `SubagentRunsList`/`SubagentRunRow`（hunk 全落在 `ToolCallView` 约 800–995 行）；`Localizable.xcstrings` +52 行新键；**删除** `Services/Session/AgentFileWatcher.swift` 与 `Services/State/ToolEventProcessor.swift`（各 225 行） |
| 审批链路 | **零字节改动**：对整份 `git diff` 的 `^[+-]` 行扫审批符号（`respondToPermission` / `pendingPermissions` / `expectsResponse` / `PermissionRequest` / `permission.ask` / `tool_approval_requested` / `InlineApprovalButtons` / `supportsPermissionControl` / `approvePermission` / `denyPermission`）→ **零命中**；`HookSocketServer.swift` 的 +44 行全部落在 `struct HookEvent` 内，且**保留了 11 参旧 init**，故 `updatedEvent`（533 行）照旧编译 |
| 并发度 | 本机同时有 3 个 omp 会话在跑本仓库；WIP 文件在采集前 9–14 分钟仍有写入 → **实现期间还会变** |

### 0.1 三条纪律

1. **一律按符号名定位，不按行号**。动手前先 `grep -n '<符号>'`；本文档所有行号都是 2026-09-20 的快照（见 §0.2 表）。
2. **需先协调的四个文件**（同文件、区域不重叠，仍须约定）：
   - `AgentIsland/Services/Hooks/HookSocketServer.swift` —— 对方只改 `struct HookEvent`（字段 + CodingKeys + 两个 init，约 1–120 行）；我们只动 `class HookSocketServer`（160 行以后）。**不要整文件重写**，用最小 edit。
   - `AgentIsland/Resources/agent-island-pi-extension.ts.txt` —— 对方 +162 行、行号位移明显；改审批块前必须重新 grep 符号。
   - `AgentIsland/UI/Views/ChatView.swift` —— 对方只占 `ToolCallView`(800–995)；我们只碰 `approvalBar`(432) / `ChatApprovalBar`(1262) / `approvePermission()`(478) / `denyPermission()`(482)。
   - `AgentIsland/Resources/Localizable.xcstrings` —— **最高冲突风险**（对方已 +52 行新键，本文件是历史热区）：新增审批文案必须**按键名合并**，**禁止整文件覆盖或重排**。
   - **零冲突、可放手改**（均 HEAD 态）：`Models/AgentKind.swift`、`Services/Session/ClaudeSessionMonitor.swift`、`UI/Views/ClaudeInstancesView.swift`、`Resources/agent-island-opencode-plugin.js`。
3. **不 commit、不 stash、不 checkout、不 add -A**：WIP 属于他人。我们若需要落盘产出（例如本方案的仓库副本），**只新增自己的文件**。

### 0.2 按符号名的行号快照（WS-F 复核；与 §2 / §4 / §8 的引用一致）

| 文件（行数） | 符号 → 行 |
| --- | --- |
| `Services/Hooks/HookSocketServer.swift`（715） | `expectsResponse` 148 · `PendingPermission` 160 · `PermissionFailureHandler` 172 · `permissionFailureHandler` 183 · `pendingPermissions` 187 · `start(onEvent:onPermissionFailure:)` 200 · `respondToPermission` 288 · `respondToPermissionBySession` 295 · `cancelPendingPermissions` 302 · `cancelPendingPermission` 328 · `let updatedEvent = HookEvent(` 533 · `sendPermissionResponse` 567 · `sendPermissionResponseBySession` 603 · `permissionFailureHandler?(sessionId,…)` 623、650 |
| `Models/AgentKind.swift`（91） | `supportsPermissionControl` 58 · `requiresIntegrationInstall` 64 |
| `Services/Session/ClaudeSessionMonitor.swift`（175） | `onPermissionFailure` 75 · `approvePermission(key:)` 97 · `denyPermission(key:reason:)` 118 |
| `Resources/agent-island-pi-extension.ts.txt`（448） | `socket.setTimeout(400, finish)` 208 · `pi.on("tool_approval_requested"` 383 |
| `Resources/agent-island-opencode-plugin.js`（179） | `"permission.ask"` 134 · `case "permission.asked":` 163 |
| `UI/Views/ClaudeInstancesView.swift`（510） | `!session.agent.supportsPermissionControl` 270 · `InlineApprovalButtons(` 294 · `struct InlineApprovalButtons` 365 |
| `UI/Views/ChatView.swift`（1380） | `isWaitingForApproval` 49 · `approvalTool` 54 · `approvalBar(tool:)` 432 · `approvePermission()` 478 · `denyPermission()` 482 · `struct ChatApprovalBar` 1262 |
| `UI/Components/AgentSettingsSection.swift` | `toggle(_:)` 43 |

> `ChatView.swift` **不含** `supportsPermissionControl` / `InlineApprovalButtons`（它走 `approvalBar` / `ChatApprovalBar` 这套 UI）。采集后若已过数分钟，**重跑** `git status --porcelain` 与上述符号 grep 再动手。

---

## 1. 结论摘要

### 1.1 每个 Agent 一句话

| Agent | 能否在刘海上批准/拒绝 | 唯一接缝 | 主要代价 |
| --- | --- | --- | --- |
| **Claude Code** | 能（**已实现**，本期只做泛化不改契约） | hook `PermissionRequest` + stdout `hookSpecificOutput.decision.behavior` | 无 |
| **omp** | **能，且能做「完整闸门」**（不是只有危险命令） | 扩展 `pi.on("tool_call")` 的 `{block:true, reason}`；`async` handler 可 `await` 我们的 socket（RUN B/C/D/H 已验证） | 需给用户装/升级扩展；**超时有两档解法**（改配置 / 用 OMP 自有对话框做预算豁免，§5.3）；omp 自身审批提示在 `yolo` 下本就不出现（**默认即 yolo**），所以刘海是唯一闸门，语义要设计清楚（三态让位 §5.7、降级三档 §5.4） |
| **pi** | **能，同样能做完整闸门** | 同名 `pi.on("tool_call")`，同一套字段与返回契约（`{block:true,reason?,terminate?}`） | pi **没有**内建审批门、**没有** `tool_approval_*` 事件、**没有** handler 超时 → 超时必须由扩展自持，且失败语义只能由我们承担 |
| **opencode** | **能**（本期不做也说得清代价） | 插件订阅事件 `permission.asked` → 问刘海 → HTTP `POST /permission/{requestID}/reply` `{reply:"once"\|"always"\|"reject", message?}`，服务端阻塞等待 | 需要一个会阻塞等待的插件路径 + 拿到 `serverUrl.port` / `client._client`；**不要**依赖 `permission.ask` hook（E/WS-D：有类型有文档但 1.18.27 二进制内无调用点） |

### 1.2 推荐落地顺序

1. **P0（应用侧泛化 + 缺陷修复，不新增能力）**：把 `toolUseId` 从全局键降级为「agent 内唯一」、修 agent 归属丢失、加 pending 收割与版本戳。**omp/pi 行为此时不变**（仍是只展示），但 Claude 链路的既有缺陷一并修掉。
2. **P1（omp + pi 闸门，主路径）**：扩展内阻塞闸门 + `yolo`（默认已是）+ 客户端危险命令兜底。这是本期唯一必须落地的能力。
3. **P2（opencode）**：插件事件 + HTTP reply。
4. **P3（可选）**：always/记住决定、问答（ask / AskUserQuestion）通道、tmux 或 collab 兜底、**`omp --mode rpc` 原生审批产品形态（C′）**、ACP/SDK 拥有会话、远端 SSH、多 agent 待批计数。

**一句话**：omp/pi 的可行路径是「扩展内阻塞闸门」（方案 A），**不是** CodeIsland 那种「危险 bash 正则 + 问答竞速」的降级版；opencode 走「事件 + HTTP reply」（方案 C 的变体）；tmux 按键（B）、接管/拥有会话（C）、以及 **`omp --mode rpc` 原生审批（C′）** 都不做主线，只作为可选形态与兜底（C′ 见 §3 与 §8 P3）。

---

## 2. 事实基础（带证据）

### 2.1 现状：展示面已泛化，决策面仍 Claude-only（三处硬编码）

| # | 硬编码 | 证据 | 后果 |
| --- | --- | --- | --- |
| H1 | 能力开关只认 Claude | `AgentIsland/Models/AgentKind.swift:58-60`：`var supportsPermissionControl: Bool { self == .claudeCode }` | UI 对 omp/pi 只渲染「Waiting for approval in terminal」（`AgentIsland/UI/Views/ClaudeInstancesView.swift:270-276`） |
| H2 | **应答通道重建事件时丢 `agent`** | `AgentIsland/Services/Hooks/HookSocketServer.swift:533-548`（构造 `updatedEvent` 未传 `agent`/`sessionFile`）→ `:66-70` 的 `agentKind` 回落到 `.claudeCode` | 排队中的审批被重新定义成 Claude 会话 → `SessionStore` 往 `SessionKey(.claudeCode, sessionId)` 写状态（幽灵会话） |
| H3 | pending 的键是**裸 `toolUseId`**，且无 agent 维度 | `HookSocketServer.swift:160-166`（`PendingPermission` 无 agent）、`:187`（`pendingPermissions: [String: PendingPermission]`）、`:302`/`:328`/`:334` 的 cancel 只按 `sessionId`/`toolUseId`、`:172` + `:623`/`:650` 的失败回调只带 `sessionId`，而 `ClaudeSessionMonitor.swift:75-77` 把失败**硬编码**成 `.claudeCode` | 跨 agent 同 id 时互相覆盖/误取消/错发应答（测试桩与确定性 id 极易撞） |

另外两处「决策面」的 Claude-only 闸门：`AgentIsland/Services/Session/ClaudeSessionMonitor.swift:105`（allow）与 `:125`（deny）。

**已经是 agent 无关、直接复用**（不要在方案里重造）：`SessionKey(agent, sessionId)`、`SessionPhase.waitingForApproval`、`PermissionContext`、`SessionStore.process(.permissionApproved/…Denied/…SocketFailed)`、`AgentBadge`、`AgentIntegrationInstaller` 的 per-agent 分派、`AgentRegistry.enabled`（`AgentIsland/Services/Agents/AgentRegistry.swift:27`）、本地化基建。

### 2.2 omp/pi 的唯一接缝：扩展 `tool_call`

- 事件字段（omp 实测 RUN B）：`{ type:"tool_call", toolName, toolCallId, input }`，`input` 是规范化视图；`ctx` 另有 `hasUI/mode/cwd/sessionManager/signal`。
- 返回契约（WS-A §2.2，源码 `oh-my-pi/packages/coding-agent/src/extensibility/shared-events.ts:311-330`）：`{ block?: boolean, reason?: string, input?: … }`；`block:true` → 工具不执行，**`reason` 作为工具错误文本回灌模型**（RUN D 模型逐字复述理由）。
- 与 Claude 的 deny 语义**等价**（都是「不执行 + 理由回灌」），差异只是 omp 走「工具错误」而非专门事件。
- handler 是 `async` 且**在等待期间工具不执行**（RUN B：往返 1–8 ms；RUN F：挂起 30s 期间 TUI footer 计时器继续走，不冻结）。
- **子会话同样过闸**（RUN I）：omp subagent 是**同进程、不同 sessionId**的独立会话，`bash` 与 `yield` 的 `tool_call` 都被调用，`hasUI:false`。
- pi 0.85.1 同签名（`pi/dist/core/extensions/runner.js:745-763`），且 pi 自己的示例扩展就有 `permission-gate.ts`（`on("tool_call")` + `ui.confirm`，`docs/extensions.md:2963`）。
- **扩展拿不到 tier**（WS-A §3 实测）：`pi.getAllTools()` 的 `ToolInfo` 无 approval 字段，运行时构造内置工具会抛 `TypeError` → tier/名单必须由扩展自持；能读到的只有生效 settings。

### 2.3 omp 的审批门与「默认就是 yolo」（这条决定成败）

- 三档 `tools.approvalMode`：`always-ask` / `write` / `yolo`，**schema 默认 `yolo`**：`oh-my-pi/packages/coding-agent/src/config/settings-schema.ts:4129-4133`；文档同源（`omp://approval-mode.md`「Modes」表标注 `yolo (default)`）。
- **本机实测生效值 = `yolo`**：`omp config get tools.approvalMode` → `yolo`；`tools.approval` → `{}`；且 `~/.omp/agent/config.yml` **没有 `tools:` 段**（今日读取）。→ 对这位用户，「omp 自己不弹审批提示」是既有事实，**不是我们造成的**。
- `yolo` 下的关键副作用（源码 + RUN J，`oh-my-pi/.../src/tools/approval.ts:189-302`）：
  - 仍生效：`tools.approval.<tool>: deny/prompt`、`bash.patterns` 的 deny/prompt、用户的 `deny`（**在 `#beforeToolCall` 就短路，扩展根本看不到这次调用**，`hasUI` 路径见 `oh-my-pi/.../src/session/agent-session.ts:4154-4158`）。
  - 失效：bash 危险模式的 **bare `override`**（`CRITICAL_BASH_PATTERNS` 命中后本来会强制 prompt）→ **必须由扩展自己兜住**。名单在 `oh-my-pi/packages/coding-agent/src/tools/bash.ts:163`（`export const CRITICAL_BASH_PATTERNS`）。
  - `computer` 的 provider safety checks 在 yolo 下仍强制 prompt，headless 直接 fail-closed。
- **「双提示」的适用范围（v2 修订；按 WS-E 的 T2/T3/T4/T10 细化）**：不是「用户一改成 write 就处处双提示」，而是**只在该 mode 不自动放行该档位**时成立。档位上限 `APPROVAL_MODE_MAX_TIER = { always-ask: read, write: write, yolo: exec }`（`oh-my-pi/packages/coding-agent/src/tools/approval.ts:106-109`）：

| 配置 | 该档位是否自动放行 | 扩展 allow 之后 OMP 是否还会弹 | 证据 |
| --- | --- | --- | --- |
| `yolo`（默认，用户实际生效值） | read/write/**exec** 全放行 | **不弹**（tier 层面） | T1 / T1b：bash 无 approval 事件、模型直接 `DONE` |
| `write` + **exec 档**（`bash` / `eval` / `task` / `computer` / `security_scan`） | 否 | **弹**（TUI = 双提示；headless / 子 agent → `requires approval but no interactive UI available` 被 OMP 自己拒） | **T2** |
| `write` + **write 档**（`write` / `edit` / …） | **是**（`MAX_TIER.write = "write"`） | **不弹** —— 给 write 档做「防双提示」是多余规避 | **T4**（`write` 工具执行成功、无 approval 事件） |
| 扩展返回 `{block:true}`（任何 mode） | —— | **不弹**：`block` 在审批闸门**之前**短路（`wrapper.ts:186-243`：先 `emitToolCall` → `throw new Error(reason)`，根本走不到 271 起的选择器） | **T3** |
| `yolo` + `tools.approval.<tool>: prompt`（用户显式策略） | 否（显式 policy 优先于 mode） | **仍弹** —— 这是双提示的第二种来源 | **T10** |
| `computer` 的 provider `pendingSafetyChecks` | 否（任何 mode / 任何 allow 都强制） | **仍弹**；无 UI 时 `pending provider safety checks but no interactive UI available` | `wrapper.ts:305-318` + `omp://approval-mode.md`「Safety overrides」 |

  → **结论（v2 修订）**：需要防双提示的只有「**exec 档 + 非 yolo mode**」与「**用户显式 `prompt` 策略**」两类；write 档、只读档、以及我们 `block` 的路径都不存在双提示。UI 告警必须按此收窄（§6.3），否则会误导实现去做无用的规避。
  → 另注：**`block` 短路意味着「刘海拒绝」永远不会再触发一次 OMP 弹窗**（T3），因此拒绝路径无需额外处理。

### 2.4 opencode：事件 + HTTP reply（不是插件返回决策）

- 插件形态：`export default { id, server: async ({ client, serverUrl }) => ({ event: async ({event}) => … }) }`；决策走 `POST /permission/{requestID}/reply`，body `{reply, message?}`，`reply ∈ {once, always, reject}`。
- 服务端语义：`ask()` 内部 `Deferred.await`，**没有超时** → 外部不回，run 就停在那里（这就是远程审批可行的原因）。
- 地址/凭据来源（CodeIsland 参考实现，`Sources/CodeIsland/Resources/codeisland-opencode.js:47-51,53-63`）：插件工厂参数里就有 `client` 与 `serverUrl` → `serverPort = parseInt(serverUrl.port) || 4096`、`heyApi = client._client`（`@hey-api/client-fetch`），回写时**优先 `heyApi.request(...)`，失败回落 `fetch("http://localhost:${serverPort}/permission/{id}/reply")`**（`codeisland-opencode-remote.js:339-352`）。→ **本机不需要额外凭据**（同机 localhost、无鉴权）；只有**远端主机**场景才需要经 `codeisland-remote-hook.py` 反代到本地 socket（`codeisland-opencode-remote.js:9-33`）。
- `permission.ask` hook **不可依赖**：类型声明存在（`~/.opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts:221`）、二进制内嵌文档也列了它，但 1.18.27 二进制里 `permission.ask` 字面量 22 处中 21 处是事件名 `permission.asked`，唯一一处是文档串；穷举 `trigger(` 调用点也没有它；上游 `permission/index.ts` 未触发 → **[推断] 当前无效**（WS-D §5.2）。
- 我方现状：`AgentIsland/Resources/agent-island-opencode-plugin.js:134-142` 注册了 `permission.ask` 但**只 `send` 状态、不改 `output`**，注释写明「批准仍在 OpenCode 内完成」；事件分支（`:163-173`）用 `event:"ToolApproval"` 上报 → 不满足当前 `expectsResponse`（要求 `event == "PermissionRequest"`）。

### 2.5 Claude 契约保持不变（回归红线）

- hook 注册：`~/.claude/settings.json` 的 `PermissionRequest` → `python3 '<...>/agent-island-state.py'`，`timeout: 86400`（今日读取实测；安装器 `AgentIsland/Services/Hooks/HookInstaller.swift:57-68,193-204`）。
- 脚本：`AgentIsland/Resources/agent-island-state.py:12-13`（socket / `TIMEOUT_SECONDS = 300`）、`:56-67`（`sendall` 后 `recv` 一次）、`:139-179`（`waiting_for_approval` → 读 `{"decision","reason"}` → 打印 `hookSpecificOutput` 的 `allow`/`deny`；其它情况 `exit 0` 无输出 = **fail-open 回落 Claude 原生 UI**）。
- 应答（应用→脚本）：`HookResponse{decision, reason?}`（`HookSocketServer.swift:154-157`），写回在 `:567-582`。
- **这些一行都不改**；P0 只改「谁可以走这条通道」（能力表）与键的维度。

### 2.6 我们自己的 socket 服务端语义（半关闭判定的基础）

- 读：`HookSocketServer.swift:467-487` —— 非阻塞 fd + `poll(..., 50ms)` 循环，**总预算 0.5s**；`bytesRead == 0`（EOF）或「50ms 静默且已有数据」都结束读。
- 保留 fd：`:514-561` 需要应答时不 `close`，把 fd 存进 `PendingPermission`（`:555`）后立即返回继续 accept（`acceptSource` 在串行队列上，`:263-268`）。
- 写：`:567-582` 编码 `HookResponse` → `write` 到保留的 fd → `close`。
- 因此：**服务端不要求客户端半关闭**，而客户端半关闭也不会导致应答丢失 —— 由 E1/E2/E3 实验坐实（见 §5.2）。

---

## 3. 方案选项对比

| 维度 | **A. 扩展内阻塞闸门**（`tool_call` + `{block:true}` + `yolo`） | **B. tmux 注入按键** | **C. 拥有/接管会话**（ACP/SDK）或 collab `ui-request/ui-response` | **C′. `omp --mode rpc` 原生审批（v2 新增）** | **D. 现状**（终端内批准 + 刘海通知） |
| --- | --- | --- | --- | --- | --- |
| 能否覆盖 omp 原生提示 | **不需要覆盖**：yolo 下 OMP 本来就不弹（§2.3），刘海就是唯一闸门 | 能（TUI-1 实测：`Allow tool: bash` 弹窗 + `↑/↓`+`Enter`；无 `y/n` 单键） | 能（collab 走通用对话框应答，先到者胜） | **本来就是原生提示**：`--mode rpc` 把审批弹窗以 `extension_ui_request{method:"select", title:"Allow tool: …", options:["Approve","Deny"]}` 交给外部客户端，回 `extension_ui_response` 即批准/拒绝（R2/R3 实测；`rpc-mode.ts:883-899, 1068-1089`） | 不算覆盖：刘海只能显示 |
| 是否需改用户配置 | **几乎不用**：`tools.approvalMode` 默认且实测已是 `yolo`；建议只加 `extensionHandlers.toolCallTimeoutMs`（§6），或走 §5.3 的方案 2 **完全不改** | 不用改 agent 配置，但**要求 agent 跑在 tmux 里**且注入会与用户抢键盘 | 不用改配置（ACP/SDK 需换启动方式）；collab 需用户 `/collab` 或 `collab.autoStart` **+ relay** | **不用改配置**：不依赖扩展、不依赖 yolo、不依赖 `extensionHandlers` | 不用 |
| 安全性 | **强**：`{block:true}` 是 agent 官方拦截面，名单在我们手里；app 不在时按 §5.4 的**用户可选三档**降级 | **低**：按键语义与弹窗状态解耦；弹窗不在屏上时 `Esc` 会**中断当前 agent 回合**（`app-keybindings.ts:88-91`），`Enter` 会**提交用户没写完的提示** | 强（官方审批通道），但等价于把会话交给外部 | **最强**：官方协议级，语义与 TUI 完全一致（bypass / safetyChecks / override 都由 OMP 自己判定，我们不用追平源码） | 无（omp 在 yolo 下**没有任何闸门**） |
| 失败模式 | 已明确且 fail-closed：handler 抛错 → `Extension <path> failed: …`；超 30s → `timed out after 30000ms`；会话中止 → `Tool execution was cancelled while an extension handler was pending`（WS-A §8）。**我们要做的是主动避开这些 fail-closed 分支**（§5.4） | 失败模式不可观测（按键没生效 = 什么都不发生，用户以为点过了；更糟的是**误伤**：`Esc` 中断回合、`Enter` 提交半句话） | collab：先到者胜、落败方 `abort()`；ACP/SDK：客户端不答 = 无限等待 | 客户端不答 = 无限等待（同 C），但**既没有 30s 上限也没有 fail-closed 风险**——审批权力本来就在客户端手里 | 「看不见 = 没批准」 |
| 维护成本 | 中：一份 TS 扩展（omp/pi 共用）+ 版本戳；omp 扩展 API 若漂移需要跟 | 高：per-agent 按键表 + 弹窗识别（`capture-pane` 默认含回滚缓冲 → 假阳性）+ 终端可见性 | 高：ACP/SDK/collab 三套协议；collab 还要 relay 与「链接=控制权」 | **最高**：要自己实现一个能渲染会话流（prompt/事件流）的 RPC 客户端——本方案里唯一的「产品形态」级工程量 | 0 |
| 适用 agent | **omp ✅ pi ✅**（同一份代码；opencode 用 A 的同构变体 = 方案 C 的 HTTP 变体） | 任何 TUI agent（含不支持扩展的）；但 `[推断]` 目标不在 tmux 里（GUI 终端）就直接不可用 | omp（ACP/SDK/collab）、未来其它可被接管的 CLI | **omp ✅**（R2/R3 实测；`--mode rpc-ui` = rpc + 会话级 `hasUI`）；pi 0.85.1 有 RPC 对话框但**没有**内建审批门 → 无审批可接管 | 全部 |
| 与现有代码的契合 | 高：展示面已泛化，只需把「决策面」抽象出来（§4） | 低：`ToolApprovalHandler.swift` 是未接线的遗留（按键硬编码 `1/2/n`，无 UI 调用者） | 中：需要新增协议客户端 | **低**：这不是「给现有 app 加一条通道」，而是「另一种启动 omp 的方式」（app 变成会话宿主）；`[推断]`「只审批、其余原样回显」的最小客户端是否可行未知 | 已实现 |

### 推荐组合

- **主路径：A**（omp + pi 共用一份扩展；opencode 用「A 的同构版」= 事件订阅 + HTTP reply）。
- **兜底：A 内置的客户端危险命令闸门**（§5.5）——即「应用不可达」时仍有最后一道 `rm -rf` / `sudo` / `chmod 777` 级拒绝。
- **可选兜底（P3）**：B（tmux 按键）用于「用户不想装扩展 / 扩展加载失败」的临时救急；C 的 **collab** 用于「不改用户启动方式就能答 TUI 原生弹窗」；C 的 **ACP/SDK** 用于「我们自己启动会话」的场景。
- **可选产品形态（P3，v2 新增）**：**C′ = `omp --mode rpc`**。它把审批**原生**交给外部客户端（实测 R2/R3），**无扩展、无 yolo 依赖、无 30s 上限、无 fail-closed**，语义与 TUI 完全一致；代价是会话变 headless、客户端必须自己持有并渲染会话流。
- **D 不作为选择**：它已经是现状，而 omp/pi 在 yolo 下等于没有闸门。

**为什么不选 B 作为主线**：按键通道与弹窗状态解耦（弹窗被覆盖即失效）、与用户抢键盘、每 agent 需要一份按键表；更关键的是**误伤** —— 弹窗不在屏上时 `Esc` 会中断当前 agent 回合、`Enter` 会把没写完的提示发给模型（WS-E §4.2），而且它**不改变「谁在决定」的语义**，出问题不可观测。
**为什么不选 C 作为主线**：ACP/SDK 都要求「外部拥有/启动会话」，改变了用户使用 omp 的方式；collab 需要用户开房间 + 默认走 `wss://my.omp.sh` relay，链接等价于会话控制权，还要在 Swift 里再实现一份 guest 协议（AES-256-GCM 解帧 + `ui-response` 定向）——把「一条本机 unix socket + 一个轻量扩展」换成「relay + 房间密钥 + 协议端」，成本与暴露面高一个数量级（WS-E §5.2）。**若只想要「不改启动方式」，collab 更划算的用法是当只读信号源**（`omp collab list --json` 的 `inputRequired`）驱动刘海 UI，应答仍走闸门扩展。
**为什么不选 C′ 作为主线（v2 修订）**：它是**唯一的官方协议级审批通道**，但要求我们自己成为会话宿主（渲染 prompt/事件流、处理 headless 语义），工程量在本方案里最大；而 A 已覆盖「用户照常跑 omp」这个主线场景。
**C′ 何时值得做**：① 用户明确要求「最强语义 / 不想装扩展」；② 未来做「由 AgentIsland 启动会话」的产品形态；③ 想彻底摆脱「扩展模拟审批门」——即不用追平 `bypass` / `safetyChecks` / `override` 这些源码级语义（WS-E P5）。
**为什么 opencode 的方案是「C 的变体」而不是 A**：opencode 没有扩展级 pre-tool 返回值拦截面（`tool.execute.before` 只做参数变换），它的官方决定权在 **HTTP reply** 上。

---

## 4. 目标架构

### 4.1 内层协议：统一决策信封（应用侧对 agent 方言零知识）

**上行（集成 → 应用）**：在现有事件信封上新增三个字段，其余不变。

```jsonc
{
  "session_id": "…", "cwd": "…", "pid": 1234, "tty": "ttys003", "agent": "omp",
  "session_file": "…",
  "event": "ToolApproval",            // omp/pi/opencode 已有事件名，不新增事件
  "status": "waiting_for_approval",
  "expects_response": true,           // ★新：声明「请回传决定」（缺省/false = 纯展示）
  "tool": "bash", "tool_input": {"command": "rm -rf /"},
  "tool_use_id": "call_abc…",
  "approval_kind": "exec",            // ★新：exec | write | critical —— 只影响刘海展示强度
  "parent_session": false,            // ★新：是否来自子代理会话（卡片归属展示）
  "approval_mode": "yolo"             // 可选：让应用能做「双提示」检测与提示
}
```

**下行（应用 → 集成）**：`{"decision":"allow"|"deny","reason"?:string}`（**不改**，与 Claude 脚本今天吃的一致）。
**措辞归属**：`reason` 的文本由**集成侧**决定要不要用/如何合成（例如用户拒绝时应用可不传 reason，扩展合成 `Denied on AgentIsland`）。理由：应用侧保持对模型措辞零知识，与 M5 一致。

**判定规则（替换 `HookSocketServer.swift:148-150`）**：

```swift
var expectsResponse: Bool {
  if event == "PermissionRequest" && status == "waiting_for_approval" { return true } // Claude 旧契约，逐字不变
  if event == "ToolApproval" && wantsResponse == true { return true }                 // omp/pi（显式声明）
  return false                                                                         // opencode 今天只展示 → 不放 pending
}
```

这解决了 WS-C 的 R5 隐患：opencode 插件（以及任何只展示的集成）**不会**因为事件名相同而被误登记成 pending。

**多会话并发是硬需求（v2 修订，WS-E §3.5/§9）**：本机此刻同时有 **7 个 omp 会话**在跑（跨 3 个项目），闸门扩展是**每会话一份**。因此：

- 信封里的 `session_id` / `session_file` / `cwd` 是**必填**（不是装饰），应用侧再补项目/工作区名（会话行的既有展示已能带出）；
- 刘海必须**按会话分组**展示待批（同一 agent 的多个会话各占一张卡，`AgentBadge` + 会话名/项目名区分），不能只显示一个「有审批」的手形图标了事（现状见 `NotchView.swift:94`）；
- **禁止「全局单例闸门状态」设计**：单例 pending/单例 socket 会让 N 个并发会话互相串台（M2 的 `PendingPermissionKey(agent, sessionId, toolUseId)` 正是这条的实现）。

### 4.2 per-agent 能力 + 传输抽象（两张小表，不要第三处 `switch`）

```swift
/// 审批能力（纯数据，挂在 AgentKind 上；放在 AgentKind.swift 同文件或新文件 ApprovalCapability.swift）
struct ApprovalCapability: Sendable {
  let canDecideRemotely: Bool   // 刘海的决定能否真正回传给 agent
  let waitsForDecision: Bool    // 集成会阻塞等待应答（决定 socket fd 是否保留）
  let requestEvent: String      // "PermissionRequest" | "ToolApproval"
}
var approval: ApprovalCapability {
  switch self {
  case .claudeCode: return .init(canDecideRemotely: true, waitsForDecision: true, requestEvent: "PermissionRequest")
  case .ohMyPi, .pi: return .init(canDecideRemotely: true, waitsForDecision: true, requestEvent: "ToolApproval")
  case .opencode:    return .init(canDecideRemotely: true, waitsForDecision: true, requestEvent: "ToolApproval") // P2 才置真
  }
}
```

```swift
/// 传输：应用侧只有一种实现（unix socket 写决策信封）。
/// 每个 agent 的方言（Claude 的 hookSpecificOutput / omp 的 {block} / opencode 的 HTTP reply）
/// 全部由**集成侧**翻译 —— 这就是为什么不需要 per-agent transport 类。
protocol ApprovalTransport: Sendable {
  var kind: AgentKind { get }
  @discardableResult func respond(key: SessionKey, toolUseId: String, decision: ApprovalDecision) -> Bool
  func cancel(key: SessionKey, toolUseId: String?)
}

struct SocketApprovalTransport: ApprovalTransport { /* 复用 HookSocketServer.sendPermissionResponse */ }
enum ApprovalDecision { case allow, deny(String?) }
```

**`ApprovalTransport` 需要第二个实现的唯一场景**（留给 P3，今天不要提前抽象）：远端 SSH 场景下应用不能直连远端 socket，需要经反向转发通道；或 tmux 兜底需要「按键」这种非 socket 传输。

### 4.3 与现有类型的对接：M1–M11（必须改；文件:行 → 改成什么）

> 行号为本方案作者复核值（WS-F 已独立复核，见 §0.2）。`AgentIsland/` 前缀省略处均在同一仓库。

| # | 位置（复核行号） | 改成什么 | 为什么 |
| --- | --- | --- | --- |
| **M1** | `Services/Hooks/HookSocketServer.swift:533-548`（构造 `updatedEvent`） | 补 `agent: event.agent, sessionFile: event.sessionFile`（以及 subagent 系列字段，见 §4.4） | 不修 → 排队中的审批被重定义成 Claude 会话（幽灵会话 + 真实会话卡 `.waitingForApproval`） |
| **M2** | `HookSocketServer.swift:160-166`（`PendingPermission`）、`:187`（字典）、`:288`/`:295`/`:302`/`:328`/`:334`（应答/取消 API） | 引入 `struct PendingPermissionKey: Hashable { let key: SessionKey; let toolUseId: String }`；字典键改它；API 全部收 `SessionKey`（`respond(key:toolUseId:decision:reason:)`、`cancelPendingPermissions(key:)`、`cancelPendingPermission(key:toolUseId:)`） | **跨 agent 串卡与「批到别人会话」的第一性原因**（R1/R2） |
| **M3** | `Models/AgentKind.swift:58-60` | 换成 §4.2 的 `ApprovalCapability`；`supportsPermissionControl` 保留为 `approval.canDecideRemotely` 的**过渡别名**（或直接删除并改三处消费点） | 避免能力分支散落；`AgentKind.swift:64`（`requiresIntegrationInstall`）无关，不要合并 |
| **M4** | `HookSocketServer.swift:148-150` | 按 §4.1 的判定规则 + 新增解码字段 `wantsResponse`（CodingKey `expects_response`） | `ToolApproval` 现在是三 agent 共用、语义已分叉 |
| **M5** | `HookSocketServer.swift:154-157`（`HookResponse`）、`:567-582` | **不变**（保留 `{"decision","reason"?}`）；只在集成侧实现翻译 | 应用侧对 agent 方言零知识 |
| **M6** | `Resources/agent-island-pi-extension.ts.txt` | 见 §5（新增 `requestDecision`；不复用 `chain`） | 不做这条，M1–M5 全是空转 |
| **M7** | `Services/Session/ClaudeSessionMonitor.swift:105`、`:125` | `if key.agent.approval.canDecideRemotely { transport.respond(...) }`；**无论是否回传都推进本地状态**（保持今天的语义） | 闸门从「是不是 Claude」变成「有没有可用的远程决策通道」 |
| **M8** | `ClaudeSessionMonitor.swift:75-77`、`HookSocketServer.swift:172`（typealias）、`:623`/`:650`（两处调用） | `typealias PermissionFailureHandler = @Sendable (SessionKey, String) -> Void`，由 pending 自带的 key 构造 | 否则非 Claude 的 socket 失败被记到 Claude 同 id 会话上 |
| **M9** | `ClaudeSessionMonitor.swift:68`、`:72` | 传 `SessionKey`：`cancelPendingPermissions(key: event.sessionKey)` / `cancelPendingPermission(key: event.sessionKey, toolUseId:)` | 同 id 跨 agent 误取消 |
| **M10** | `HookSocketServer.swift`（新增；或挂在 `SessionStore.recheckAllSessions` 周期里） | **pending TTL 收割器**：`PendingPermission.receivedAt` 已有 → 超 TTL（建议取「两端最小值 − 余量」，见 §5.3）后 `close(fd)` + 移除 + 触发 `permissionFailureHandler` | 脚本/扩展超时或断开后 pending 与 fd 泄漏（WS-C A21/R10）；多 agent 后翻倍 |
| **M11** | `Services/Agents/AgentIntegrationInstaller.swift:101-127`（写入）、`:78-90`（`isInstalled`） | 扩展文件头加 `// agent-island-extension-version: N`；安装时比对内容版本（不一致即重写）；`isInstalled` 从「存在即已安装」升级为「存在 **且版本匹配**」 | 正常升级会覆盖写（`:120` 无条件 `write`），但用户手改 / app 降级 / 写入抛错被 `catch` 吞掉（`:121-126`）时会静默停在旧行为，UI 仍显示「已安装」 |
| **M12（新发现；v2 修订）** | `HookSocketServer.swift` 的 `HookEvent` 两个便利 `init`（旧 11 参：`agent`/`sessionFile` 有默认值） | 它们把 `subagentId/subagentAgent/subagentStatus/subagentCurrentTool/subagentTask/parentToolCallId/subagentSessionFile` **全部写成 nil** —— 任何经它重建的事件都会丢掉子代理字段（M1 只补 `agent`/`sessionFile` 仍会丢子代理归属）。**改为「用原事件做副本、只替换 `toolUseId`」**（加 `func withToolUseId(_:) -> HookEvent`），不再手工重列参数 | 否则子代理上报被重建时静默降级。**注意（v2）**：这 7 个字段正是**另一场 WIP** 正在加的（§0）——实现时**以他们工作树中的字段清单为准**，先 `grep -n 'let subagent' AgentIsland/Services/Hooks/HookSocketServer.swift` 取全字段名，再写副本语义 |

### 4.4 顺带修掉的既有缺陷（P0 范围内，属于我们自己的改动）

| # | 位置 | 问题 | 处理 |
| --- | --- | --- | --- |
| B1 | `HookSocketServer.swift:555` | `pendingPermissions[toolUseId] = pending` 直接覆盖，旧条目既不 `close` 也不报失败（fd 泄漏） | 覆盖前若存在同键 pending → `close` 旧 fd + 记一次 warning |
| B2 | `HookSocketServer.swift:467-487` | 读窗口「0.5s 从连接建立开始」；客户端连上后若 >0.5s 才写数据，事件被丢弃（`guard !allData.isEmpty` 于 `:489` 直接 close） | 把窗口改为「首个字节之后 50ms 静默」或把预算提到 2s；P0 先加日志计数，P1 端到端实测后再定 |
| B3 | `HookSocketServer.swift:251` | `listen(serverSocket, 10)`：多 agent × 多会话 + 子代理并发时偏小 | 提到 32，并加「当前 pending 数 / 连接数」debug 指标 |
| B4 | `AgentIsland/UI/Views/ChatView.swift:381`、`:1212` | 文案硬编码 Claude（`"Message Claude..."`、`"Claude Code needs your input"`） | 去掉 Claude 化（i18n 键双向补齐，见 §9.5） |
| B5 | `ClaudeInstancesView.swift:270-276` | `!supportsPermissionControl` → 纯文本分支 | 改为 capability 驱动：能回传的走 `InlineApprovalButtons`（`:294`）；不能的保留终端提示 |

---

## 5. omp / pi 扩展的精确契约（照此编码）

### 5.1 `tool_call` handler：字段、返回语义、为何可以 await

```ts
// 伪码契约（不是最终实现）
pi.on("tool_call", async (event, ctx) => {          // omp: 在 tool_execution_start 之前；pi: 在其之后
  if (!isRootSession(ctx)) {                        // v2：判据用「sessionFile 不以 /<agent 名>.jsonl 结尾」（§5.7），
    // 子代理：只对 critical 询问，其余放行（§5.5）   //     拿不到判据时退回 hasUI/会话身份并在报告里标明
    if (!isCritical(event)) return;
  }
  const decision = await classify(event);           // "allow" | "ask" | "critical"
  if (decision === "allow") return;                 // 放行 = 返回 undefined（omp 会继续执行）
  const verdict = await requestDecision({           // 阻塞：写 socket → 等 {"decision","reason"} 
    event: "ToolApproval", status: "waiting_for_approval", expects_response: true,
    tool: event.toolName, tool_input: event.input, tool_use_id: event.toolCallId,
    approval_kind: decision, parent_session: hasParentSession(ctx),
  });
  return verdict.allowed ? undefined : { block: true, reason: verdict.reason };
});
```

| 项 | 事实 | 证据 |
| --- | --- | --- |
| 事件字段 | `{ type:"tool_call", toolName, toolCallId, input }`（`input` 规范化） | omp: `extensibility/extensions/types.ts:919-967`；实测 RUN B 的 `ext.jsonl` |
| 返回值语义 | `block:true` → 工具不执行，`reason` 作为**工具错误文本**给模型；省略/`undefined` → 放行 | `extensibility/shared-events.ts:311-330`；执行链 `extensibility/extensions/wrapper.ts:210-243`（`throw new Error(reason)`）；RUN C（放行=真执行）、RUN D（拒绝=模型收到 reason） |
| 能否 async / await 外部 I/O | **能**。实测 handler 里 await unix socket 往返 1–8 ms，期间工具不派发；TUI 不冻结 | RUN B/TUI-2 |
| handler 是否在子会话被调用 | **是**（同进程、不同 sessionId；`yield` 也过闸） | RUN I |
| pi 差异 | 同事件名/同返回契约；`terminate?` 仅 pi 有；pi **无** handler 超时、**无**内建审批门、**无** `tool_approval_*` 事件 | `pi/dist/core/extensions/runner.js:745-763`；`pi/docs/extensions.md:778-792`；`pi/docs/settings.md` 内 `approval\|permission` 零命中（今日复核） |
| 拿不到 tier | `pi.getAllTools()` 的 `ToolInfo` 无 approval；运行时构造内置工具抛 `TypeError` | WS-A §3 实测 |

### 5.2 socket 半关闭：判定 + 与 CodeIsland 结论的差异

**结论：Node 侧 `socket.write()` 之后可以安全地「等待应答再收尾」；最稳妥的写法是「写完后不 `end()`，收到完整 JSON 再 `destroy()`」。**

依据（三条实测，脚本在 `/tmp/ai-approve/halfclose/`）：

| # | 客户端行为 | 结果 | 含义 |
| --- | --- | --- | --- |
| **E1** | `write()` 后立即 `end()`（半关闭），继续等 `data` | **收到** `{"decision": "allow"}`，时间 1503 ms；服务端读循环已看到 EOF（`got_eof:true`，读到 79 B 用时 1 ms），**1.5s 后写回成功** | 半关闭**不会**丢应答 |
| **E2** | `write()` 后不 `end()`，保持连接等 `data` | **收到**应答（1558 ms）；服务端读到数据后 50 ms 静默即结束读（`got_eof:false`，用时 54 ms），**fd 保留** | 我们**不要求**半关闭；推荐写法 |
| **E3（负控）** | `write()` 后 50 ms `destroy()`（= 现有扩展 `setTimeout(400, finish)` 的等价物） | **应答丢失**：服务端 `write` 报 `Broken pipe`，客户端 `data:null` | 必须避免「在决策到达前收尾」 |

**与我方源码的对应**：服务端读语义在 `HookSocketServer.swift:467-487`（EOF 或 50ms 静默即结束读）、保留 fd 在 `:514-561`、写回在 `:567-582` —— 与 E1/E2 复刻的行为一致（实验用 Python 复刻读语义；**Node 侧是真实运行**）。端到端（真 Swift 服务端 + 真 omp）留给 P1 验收，标 **[推断]**。

**与 CodeIsland 结论的差异分析**：CodeIsland 的插件注释写「Node.js `net` 的半关闭（`sock.end()`）会让 macOS **NWConnection** 立即关闭，从而丢响应；必须走 bridge 二进制的 `shutdown(SHUT_WR)`」（`Sources/CodeIsland/Resources/codeisland-opencode.js:26-30`，同类注释见其 pi/omp 插件）。这是**服务端实现差异**，不是 Node 的普遍行为：

- 他们用 `NWListener`/`NWConnection` 做服务端，半关闭被 `NWConnection` 当成「连接结束」处理（响应写不回去）；
- 我们用 BSD `socket(AF_UNIX, SOCK_STREAM)` + `poll`：对端 FIN 只让**读方向**结束，**写方向仍然有效**，因此 E1 能收到应答。

**因此我们不引入 bridge 二进制**（省掉一个随包可执行文件、签名与去 quarantine 的全部麻烦）。代价是这条结论只对「我们自己实现的服务端」成立 —— 一旦将来换成 `NWListener`，就需要重新评估（这是把 E1/E2/E3 收进回归脚本的理由）。

**给扩展的实现要求（写入代码注释）**：
1. `net.createConnection(path)` → 注册 `data/error/close` **先于** `write()`；
2. `write(JSON.stringify(payload))` 后**不要** `end()`；
3. 累积 `data` 直到 `JSON.parse` 成功（或超时）；
4. 收到决策或超时/错误后必须 `destroy()`（否则 fd 泄漏）；
5. **永不 `throw`**（见 §5.4）。

### 5.3 超时预算（v2 修订：新增「预算豁免」方案）

**首要事实（WS-E §3.3 / P1，T5 实证）**：omp 的 30s 是 **active-work 预算**，**等待 OMP 自有对话框期间不计时**。源码：`runner.ts:150-195`（`runDialog` 与 `ui.custom` 分别 `pause()`/`resume()` 预算）、`runner.ts:248-330`（`pause()` 扣减已用时间、`pauseDepth > 0` 不重新 arm）；schema 描述原文「**active-work** timeout … time awaiting OMP-owned dialogs does not count」（`config/settings-schema.ts:6094-6104`）。T5 用 `extensionHandlers.toolCallTimeoutMs: 3000` + handler 睡 8s 复现了超时 fail-closed（说明该键**可配置且生效**）。

因此有两档解法：

| 方案 | 做法 | 代价 / 风险 | 适用条件 |
| --- | --- | --- | --- |
| **方案 1（默认）** | 安装器 merge 写 `extensionHandlers.toolCallTimeoutMs: 300000`（§6.2），客户端自持 120s 超时 | 改了用户配置（有痕迹，需备份/回滚）；30s→300s 只是把「被拒」推迟 | **默认走这条**（简单、已验证 T5 该键生效） |
| **方案 2（预算豁免）** | handler 在等待刘海期间持有一个 OMP 自有对话框（推荐 `ctx.ui.custom(...)` 渲染一行非抢焦点的「等待刘海决策…」；或在用户明示允许时用 `ctx.ui.select`），利用「对话框挂起不计预算」的语义 → **理论上可无限期等待** | ① 依赖**未文档化**的预算语义（`pause/pauseDepth`）；② OMP TUI 上会多一个**扩展自有浮层**，须设计成不抢焦点的一行；③ 必须处理「用户在 TUI 上直接答了」的竞速（与 socket 决策 `Promise.race`，先到者胜，参照 collab 的本地/远端竞速）；④ **本方案尚未端到端验证** | 仅当方案 2 经 P1 端到端验证通过后才启用；否则**不得**用它替代方案 1 |

**推荐组合**：**默认方案 1**（客户端 120s、超时=拒绝），把方案 2 作为 P1 的并行验证项与 P3 的增强（验证通过后可去掉对用户配置的写入 —— 这对「不愿被改配置」的用户是更好的答案）。

| 层 | 现值 | 建议 | 理由 |
| --- | --- | --- | --- |
| omp 扩展 handler 预算（**方案 1**） | `extensionHandlers.toolCallTimeoutMs = 30000`（`omp config list` 实测；schema `config/settings-schema.ts:6094-6104`；T5 证明可配置且生效） | **300000**（由安装器在用户开启开关时写入，见 §6） | 30s 意味着「用户在刘海上犹豫超过 30 秒」→ omp 自己 fail-closed（`Extension <path> timed out after 30000ms`，RUN F / T5），用户看到的是**未知原因的工具失败**。把服务端预算抬到 5 分钟，让「我们的客户端超时」成为唯一裁决者（可给出可读理由） |
| 我们的客户端超时 | ——（新增） | **120s**，卡片在最后 10s 显示倒计时 | 「刘海上的一次决定」是看一眼的动作；2 分钟足够覆盖「用户在看别的东西后扫一眼」。超过 2 分钟大概率人不在 → 拒绝（§5.4），模型可重试、用户可再点 |
| 应用侧 pending TTL（M10） | 无 | **150s**（> 客户端 120s） | 保证「扩展先超时、应用后收割」，避免应用先关 fd 导致扩展收到 EOF 而语义反了 |
| Claude 脚本超时 | 300s（`agent-island-state.py:13`） | **不动** | 与 hook `timeout: 86400` 配合是既有契约（§2.5） |
| pi | 无内建超时 | 同上 120s（**唯一**由扩展决定） | pi 没有兜底，超时语义完全由我们定义 |
| opencode | 无（`Deferred.await`） | 插件侧 120s → `reject` | 服务端不超时，只能我们计时 |

**「用户不点会怎样」**：120s 后扩展返回 `{block:true, reason:"Approval request timed out — no answer on AgentIsland within 120s"}` → 该次工具不执行，模型看到理由并可重试/换方案；**不会**卡住会话（RUN F 证明挂起期间 TUI 正常）。这与「无限期挂着」相比，代价小得多（参见 §10 待拍板 1）。

**服务端预算与客户端超时的关系（v2 明确）**：两端都要有预算，且**客户端必须更早超时**——
- 客户端 120s < 应用侧 pending TTL 150s < 服务端 300s（方案 1）/ 不受限（方案 2）；
- 这样「谁先说话」永远是我们的扩展：模型看到的是 `Approval request timed out …`（**可读**），而不是 omp 的 `Extension <path> timed out after 30000ms`（**不可读**），也不会出现「应用先关 fd 导致扩展读到 EOF 而误判语义」。
- 方案 2 下服务端不再计时，但**客户端 120s 与 TTL 150s 保持不变** —— 「超时=拒绝」的结论不因预算方案而变。

### 5.4 失败语义矩阵（逐条：期望行为 + 实现手段）

| 情形 | 期望行为 | 实现手段 | 判据/证据 |
| --- | --- | --- | --- |
| **应用未运行 / socket 不存在**（ENOENT/ECONNREFUSED） | **按用户选定的降级档执行**（v2 修订，三档见下表）；**绝不能因为 AgentIsland 没开就让 omp/pi 不可用**，也**不能**静默放行 —— 降级必须在 TUI 可见 | `connect` 失败 → 读用户配置的 `degradation` 档；`critical` 无论哪档都本地拒绝；**在 TUI 打印一行**「闸门离线，已降级为 <档>」（`ctx.ui.setStatus`/一次性 notify） | 与 Claude 的 fail-open 语义一致（`agent-island-state.py:179-181` 的 `exit 0`）；降级三档见下（WS-E P3）；[推断] errno 文案随实现（RUN G 覆盖了「已连接但无响应」） |
| **socket 可达但应用不回**（应用卡住/未回） | **拒绝** + 可读 reason | 客户端 120s 超时 → `{block:true, reason}` | E3 负控证明「收尾太早」会丢应答；RUN G 证明「无响应」在 omp 侧会 fail-closed（我们要主动给出理由，而不是让 omp 报 `timed out`） |
| **决策返回 `deny`** | 工具不执行，理由回灌模型 | `return { block: true, reason }` | RUN D：模型逐字复述理由 |
| **决策返回 `allow`** | 放行 | `return undefined` | RUN C：`ISLAND_TOOL_RAN` |
| **决策到达前会话被中止**（Esc/Ctrl+C） | omp 侧 fail-closed；扩展侧撤下等待、释放 fd | 监听 omp 的 `ctx.signal`（若有）与 socket `close/error` → `destroy()`；应用侧 M9 的 cancel | 源码 `extensibility/extensions/runner.ts:1523-1525`：`Tool execution was cancelled while an extension handler was pending` |
| **应用在等待中被杀**（连接断开，已投递过卡片） | **拒绝**（已问过人，不静默放行）→ 待拍板（§10-4） | 等待态收到 `close`/`error` → `{block:true, reason:"AgentIsland is no longer available"}` | [推断] 语义选择，非实测 |
| **扩展内部异常（bug）** | **绝不抛错**；catch 后放行（保留 critical 拒绝） | handler 全体包 `try/catch`，`catch { return critical ? {block:true,…} : undefined }` | 抛错 → omp 报 `Extension <path> failed: <msg>` 并**阻塞**（RUN E）→ 会把「我们的 bug」变成「用户的工具不可用」 |
| **OMP 自己也在问**（`yolo` + 显式 `prompt` 策略、`computer` 的 `provider safetyChecks`、或非 yolo mode 的 exec 档） | 刘海**让位**：撤下自己的 Allow/Deny，只显示「终端正在询问」（三态状态机见 §5.7） | 扩展订阅 `tool_approval_requested` / `tool_approval_resolved`（`...ts.txt:383` 已有）→ 上报 `omp_owns_approval: true`；应用侧据此把卡片切到「OMP 负责」态 | T2/T10 + `wrapper.ts:271-341`；WS-E §3.4（两个入口互相等待） |
| **OMP 自己拒绝**（headless/子 agent/no-UI：`requires approval but no interactive UI available`） | 刘海必须**与自己拒绝区分**：不同卡片状态 + 不同 `reason` 前缀，否则用户会以为是自己点的拒绝 | 应用侧按「该 tool_call 是否曾进入 pending」判定归属；UI 文案用 `OMP 拒绝（无审批 UI）` 而非 `已拒绝` | WS-E §2.3 第 2 点（这两类拒绝在 UI 上语义不同） |
| **集成已降级**（`pi.pi.*` / `pi.on` 特性探测失败、版本戳不匹配） | **降级为只上报**（不闸门）+ 刘海显示「集成已降级」告警；**绝不静默放行** | 扩展启动自检：任何特性探测失败 → 不注册决策逻辑，只发 `ToolApproval` 展示事件；并上报 `gate_enabled: false` + 原因 | WS-E P4。**注意与本表首行的区别**：这是「**集成坏了**」（必须告警，不退化为放行），首行是「**应用没开**」（按用户选的档降级） —— 两者 UI 提示不同 |
| 应用侧报文解析失败 / 拿不到 `tool_use_id` | 视为普通事件，不登记 pending（fail-open，保持与 Claude 路径一致） | `HookSocketServer.swift:492-502`（decode 失败 close）、`:514-530`（无 id 时 close + 不登记） | 现状即如此，P0 保留 |

**为什么「超时 = 拒绝」而不是「超时 = 放行」**：omp 的生效 `approvalMode` 是 `yolo`（§2.3），**没有任何原生兜底提示**。若超时放行，则「用户没看见 / 没点」这条路径会静默执行任意命令（`rm -rf`、`git push --force`、写生产库），攻击面与事故面都不可控。拒绝的代价只是「这次工具失败、模型可重试」。注意这与「应用未运行 → 降级」不矛盾：**「问了没答」= 拒绝（保安全）；「无人可问」= 按用户选的档降级（保可用性，且降级可见）**。

**降级三档（v2 修订，WS-E P3）** —— 把「app 未运行就放行」从硬编码提升为**用户可选、且必须在 TUI 可见**的策略：

| 档 | 行为 | 适用 |
| --- | --- | --- |
| `strict` | socket 不可达 → 一律拒绝 | 把 omp 当生产工具、宁可停也不能误执行 |
| **`notify-only`（默认）** | 放行 + 记录（审计日志）+ 刘海事后展示；`critical` 仍本地拒绝 | 日常使用：不打断工作，同时危险命令仍有底线 |
| `read-only-allow` | read 档放行；write/exec 档拒绝 | 只想给「读」开绿灯的谨慎用户 |

- **可见性是硬要求**：降级时必须在 TUI 打印一行（`ctx.ui.setStatus(...)` 或一次性 notify）「闸门离线，已降级为 <档名>」，否则用户会以为审批还生效。
- 配置存放：**应用侧**（`AppSettings`，§6.4 的 UI 选择器），随请求信封在 `session_start` 时下发给扩展（不写进用户 agent 配置）。
- 这一档也决定 `critical` 之外的**默认行为**：`notify-only` 下「app 未运行」＝ 普通命令照跑、危险命令被拒、刘海事后能看到发生过什么。

### 5.5 策略来源（默认哪些工具要刘海批准）

**为什么必须自持**：扩展运行时拿不到 tier（§5.1 末行）。因此在扩展里维护一张**带版本戳的名单表**，随 app 升级重写。

**`pi.pi.settings` 只作诊断，不作安全判定（v2 修订，WS-E P4）**：
- **允许的用途**：① 上报 `approval_mode` 让应用侧做「双提示」告警；② `isConfigured("tools.approvalMode") && get(...) !== "yolo"` 时提示用户「闸门与 OMP 原生提示会叠加」（§6.3）。
- **禁止的用途**：**不得**用它决定「要不要闸门」「该拦哪一档」。理由：`pi.pi` 是**包根导出**（`pi: typeof PiCodingAgent`），不是扩展 API 契约，omp 升级即可能改变形状；把它绑进安全判定等于把安全性挂在私有实现上。
- **漂移自检**：任何 `pi.pi.*` / `pi.on` 特性探测失败 → **降级为只上报** + 刘海显示「集成已降级」告警（§5.4 对应行），**绝不静默放行**；并在 app 内声明「支持 omp ≥ 18.2.x」，握手时校验 `omp --version`。

| 档 | 工具（初值，随 omp 版本校准） | 行为 |
| --- | --- | --- |
| **never-ask**（只读/UI/协议） | `read, glob, grep, ask, todo, yield, think, ast-grep, checkpoint, memory-edit, memory-recall, memory-reflect, memory-retain` | 直接 `return undefined`（连 socket 都不发） |
| **ask**（写/执行） | `bash, eval, task, computer, security_scan, write, edit, ast-edit, debug, gh, lsp(写动作), learn, mcp__*` | 上报 → 等刘海决定 |
| **critical**（危险模式） | `bash` 命中危险模式（等价 `CRITICAL_BASH_PATTERNS`） | 上报（卡片标红）→ 等决定；**应用不可达时直接拒绝** |
| 例外 | `yield` **永不上刘海** | 拒 `yield` 会让子代理交付失败（RUN I） |

- **危险模式名单**：权威来源 `oh-my-pi/packages/coding-agent/src/tools/bash.ts:163`（`CRITICAL_BASH_PATTERNS`，实测 21 条）。**不要 import omp 内部模块**（会随包结构与导出变化崩），而是在扩展里内联一份精简名单（`rm -rf`/`--recursive --force` 类、fork bomb、remote-fetch-then-execute、写 `/etc/passwd`、关机类）+ 版本戳注释，升级时人工对齐。
- **根会话 vs 子代理**（RUN I 事实）：默认**子代理不上刘海**（除 critical），理由三条：① omp 官方定位里 `task` 调用本身就是授权边界；② 子代理常并发，逐条上卡片会刷屏并阻塞子代理；③ `yield` 被拒会破坏交付。实现上用已有的 `hasParentSession`（`agent-island-pi-extension.ts.txt:151-158`）判定，并在 `parent_session:true` 时仍上报（应用侧可选择折叠展示，不做阻塞）。**这一条列入待拍板（§10-2）**。
- **危险命令客户端兜底**（app 不可达时的最后一道）：文字上必须诚实 —— 它是**客户端启发式**，可被变量拼接/别名绕过，且只有 deny 生效。UI 文案不得宣称「等价于完整审批」。

### 5.6 与现有扩展的兼容（改造要点）

| 点 | 现状 | 改造 |
| --- | --- | --- |
| 发送路径 | `send()`（`...ts.txt:178-216`）：`write` → `end()` → `setTimeout(400, finish)` → `destroy()`，且 `socket.on("data", finish)` **丢弃数据** | **审批不复用 `send()`**。新增 `requestDecision(payload, timeoutMs)`：独立 Promise、累积 data 直到能 parse、超时/决策后 `destroy()`；普通事件仍走 `send()` |
| 串行链 | `chain`（`:113`）串行所有事件 | **审批不得进 `chain`**（否则审批会与普通事件互相排队，一个待批会堵住整条上报链）。`chain` 只用于 fire-and-forget 事件 |
| `tool_call` handler | `:356-368` 只上报 `PreToolUse` | 改为「先上报（走 chain）→ 再等决策（独立 Promise）→ 返回 block 或 undefined」；注意必须先上报，否则刘海上卡片来不及出现 |
| `tool_approval_requested` handler | `:383-395` 只上报 | **保留**（它仍是「omp 自己的门是否在响」的观测点，也是双提示检测手段） |
| 学习/兼容 | `try { pi.on("agent_settled", …) } catch {}`（`:343-352`） | 沿用同一风格：`pi.pi`、`pi.events`、`ctx.signal` 全部特性探测 |
| 版本 | 无版本戳 | 文件头 `// agent-island-extension-version: 2`（M11） |
| 两份安装 | `~/.omp/agent/extensions/agent-island-state.ts`（9441 B）与 `~/.pi/agent/extensions/agent-island-state.ts`（9439 B），由 `__AGENT_ISLAND_AGENT__` 占位符替换（`AgentIntegrationInstaller.swift:101-127`） | 不变；注意**不要**整目录重写 —— 同目录还有第三方扩展（`herdr-omp-agent-state.ts` / `herdr-agent-state.ts` / `statusbar.ts`），只能写自己那一个文件 |

### 5.7 会话角色与「让位」三态状态机（v2 修订）

**判据：谁负责这次审批**（决定卡片形态与是否阻塞）：

| 态 | 触发条件 | 闸门行为 | 刘海 UI |
| --- | --- | --- | --- |
| **① 刘海负责**（默认） | 根会话 + 该档位需要问 + OMP 自己不会问（yolo 且无显式 `prompt`） | 阻塞等待 socket 决策 | 正常卡片（Allow / Deny） |
| **② OMP 负责**（让位） | 任一：`tool_approval_requested` 已发出（yolo 下的显式 `prompt` 策略 T10）、`computer` 的 provider safetyChecks、或非 yolo mode 的 exec 档（T2） | **不阻塞**（或立即放行以让 OMP 的门说话），并上报 `omp_owns_approval` | 撤下 Allow/Deny，只显示「**终端正在询问**」（可带「前往终端」按钮） |
| **③ 已取消** | 会话被 Esc/Ctrl+C/`Stop` 中止；或应用侧 `cancelPendingPermission`（M9）命中 | 停止等待、`destroy()` 释放 fd、不返回决策 | 卡片**撤下**（不是留在屏上等人点一个已死的请求） |

**实现要点**：

1. **根/子会话判据（特性探测优先）**：WS-E 的 T7 实证——子会话的 `sessionFile` 形如 `…/SubagentEcho.jsonl`（即 `<agent 名>.jsonl`），根会话是 `<ISO 时间戳>_<uuid>.jsonl`。因此判据 = `ctx.sessionManager.getSessionFile()` **不以 `/<agentName>.jsonl` 结尾**即子会话。**拿不到该字段时**退回「`hasUI` / 会话身份」判定（现有 `isRootSession`，`...ts.txt:170-175`），**并在交付报告里明确标注走了哪条判据**（判据依赖 omp 的命名约定，升级可能变，需自检）。
2. **让位的方向性**：让位只发生在「OMP 自己已经开始问」时；若 OMP 只是**将要**问（还没发 `tool_approval_requested`），闸门仍按 ① 负责——因为 `block` 会短路 OMP 的门（T3），此时交给刘海更顺。判「已经开始问」的唯一可靠信号是**收到 `tool_approval_requested`**（该事件是纯 observability，正好适合做信号）。
3. **让位不解锁「拒绝能力」**：② 态下刘海不再能拒绝（决定权已归 OMP）；这是**有意的**——两个入口都能拒绝会导致「先拒者胜」的语义叠加（WS-E §3.4）。
4. **③ 态与「OMP 自拒」区分**（WS-E §2.3 第 2 点）：OMP 自己拒（no-UI/headless）走的是 `requires approval but no interactive UI available`，与「刘海拒绝」在 UI 上必须是**不同状态与不同文案**（§5.4 对应行）。

**状态表（应用侧 `SessionPhase` 的对接）**：`waitingForApproval(PermissionContext)` 保持不变；新增两个**展示维度**（不新增 phase，避免动状态机）：
- `approvalOwner: .notch | .omp`（决定卡片给不给 Allow/Deny）；
- `approvalOutcome: .pendingDecision | .ompRejected | .cancelled | .timedOut`（决定文案与着色）。

---

## 6. 配置改动清单

### 6.1 要写什么、什么时候写

**总原则：只在用户打开开关时执行；写前备份、写后校验、卸载/关闭时回滚。**

| 文件 | 键 | 何时写 | 值 | 回滚 |
| --- | --- | --- | --- | --- |
| `~/.omp/agent/config.yml` | `extensionHandlers.toolCallTimeoutMs` | 用户开启「在刘海上批准」时 | `300000`（原值 `30000`） | 关闭开关时写回备份内容 |
| `~/.omp/agent/config.yml` | `tools.approvalMode` | **默认不写**（见 §6.3 的实测与理由） | —— | —— |
| `~/.pi/agent/settings.json` | 无 | —— | pi 没有审批相关配置 | —— |
| `~/.claude/settings.json` | **不动** | —— | 既有 `PermissionRequest` + `timeout: 86400` 保持 | —— |
| `~/.omp/agent/extensions/agent-island-state.ts`、`~/.pi/agent/extensions/agent-island-state.ts` | 扩展本体 | 开启/升级时（M11 版本戳比对） | 闸门版 | 关闭时替换为「只上报」版（保留状态展示） |
| （**不写文件**）闸门降级档 `strict` / `notify-only` / `read-only-allow` | —— | 用户在设置面板选择时（v2 新增） | 存 `AppSettings`（UserDefaults），随 `session_start` 下发给扩展 | 切回默认 `notify-only` |
| `<cwd>/.omp/config.yml`（**可选**，项目层） | `tools.approvalMode: yolo` | 仅当用户显式要求「只在本项目生效」时（v2 新增） | 项目层覆盖全局（T6 实测：全局 `always-ask` + 项目 `yolo` → 生效 `yolo`） | 删除该文件/该键 |

**为什么不写全局 `tools.approvalMode`（v2 修订）**：默认已是 `yolo`，写它只会给用户留一处「被改过」的痕迹；且会把用户**显式选择过**的限制模式静默抹掉（WS-E §1.3）。需要范围化时用项目层；**本方案不主动写这一项**。

### 6.2 写入方式：merge，不是 overwrite

- **不要自己拼 YAML**：Swift 侧没有 YAML 依赖，手写正则合并极易破坏用户文件。
- **用 omp 自己的写入口**：`omp config set extensionHandlers.toolCallTimeoutMs 300000` / `omp config get …` / `omp config path`（今日实测可用，`omp config path` → `/Users/seehar/.omp/agent`）。它的语义是**合并写**（保留注释与其它键）。
- **但它会重排少量格式**（**E4 实测**）：把 `providers.maxInFlightRequests: {}` 展开成两行、末尾补键且**无换行结尾**。
  → 因此：**写之前 `cp config.yml config.yml.agent-island.bak`**（备份文件与目标同目录、权限一致），并把「原值 + 备份路径 + 写入时间」记进 `UserDefaults`；`omp config set` 失败（非 0 退出）时**不要**降级成自己写文件。
- **副作用告知**：这类格式漂移对用户是不可见但真实的改动，卸载时必须能从备份还原。

### 6.3 `tools.approvalMode` 的用户可见影响（必须写进 UI 文案）

- **事实（今日实测）**：`omp config get tools.approvalMode` → `yolo`；`tools.approval` → `{}`；`~/.omp/agent/config.yml` **无 `tools:` 段**。schema 默认也是 `yolo`（`oh-my-pi/packages/coding-agent/src/config/settings-schema.ts:4129-4133`）。
- **推论（关键，必须告知用户）**：
  1. 「omp 自己不弹审批提示」**不是开启本功能造成的**，而是用户 omp 的既有状态；
  2. 因此**关闭开关不会恢复「omp 自己问」的状态** —— 关闭后 omp 在 yolo 下**完全没有审批闸门**（只剩 `bash.patterns` 等显式规则）。UI 文案必须直说。
  3. **（v2 修订）双提示只对「会双提示的档位」告警**，不要泛化（详见 §2.3 的 T2/T3/T4/T10 表）：

| 检测到的配置 | 是否告警 | 告警文案要点 |
| --- | --- | --- |
| `approvalMode = yolo` 且 `tools.approval` 为空（= 本机现状） | **不告警** | —— |
| `approvalMode ∈ {write, always-ask}` | **告警**（但只针对 **exec 档**：`bash/eval/task/computer/security_scan`） | 「非 yolo 模式下，exec 类工具会同时出现刘海与终端两个提示」；提供可选「一键改为 yolo」（merge 写 + 备份） |
| `tools.approval.<tool>: prompt` 非空 | **告警**（无论什么 mode，T10 证明 yolo 下也弹） | 「你为 `%@` 设了 prompt 策略，它会绕过本闸门单独弹窗」 |
| 只有 write 档工具（`write`/`edit`） | **不告警** | T4：write 模式自动放行 write 档，不存在双提示 |

  → 检测方式（**只作诊断**，§5.5）：`pi.pi.settings.isConfigured("tools.approvalMode") && get(...) !== "yolo"` 或 `get("tools.approval")` 非空 → 上报 `approval_mode` / `approval_policies`，由应用侧决定告警。
  → **静默接管防护（v2 新增）**：若用户**显式**配置过限制模式（`isConfigured == true`），应用**不得**静默改写它——只提示，并把闸门的默认档降为「只上报 + 让位」（§5.7 ② 态），把决定权留给用户的原生提示。

### 6.4 UI 开关（默认关、opt-in）

- 位置：`AgentIsland/UI/Components/AgentSettingsSection.swift` 的 per-agent 行区域（现有 `AgentSettingsRow` + `toggle(_:)` 在 `:43-66`）；新增一个与本功能绑定、**默认关**的开关，仅对 `AgentKind.allCases` 中 `approval.canDecideRemotely && requiresIntegrationInstall` 的 agent 显示。
- 状态存储：`AgentIsland/Core/Settings.swift`（`AppSettings`，UserDefaults；参考既有 `isAgentEnabled`/`setAgent` 的写法）。
- 开启动作（顺序）：① 校验目标 agent 的配置目录存在 → ② 备份 omp `config.yml` → ③ `omp config set extensionHandlers.toolCallTimeoutMs 300000` → ④ 安装/升级「闸门版」扩展（写版本戳）→ ⑤ 记录原值与备份路径 → ⑥ 刷新 UI 状态；任一步失败 → 回滚已做的步骤并保持开关关闭。
- 关闭动作：① 恢复 `config.yml` 备份（若曾写过）→ ② 把扩展替换为只上报版 → ③ 清状态。
- 文案（zh-Hans / en 双向都要）：
  - 标题：`在刘海上批准工具调用` / `Approve tool calls on the notch`
  - 说明：`会接管 omp 的审批：omp 自身不再提示（其默认 approvalMode 已是 yolo）。关闭后 omp 将不再有任何审批闸门。` / `Takes over approval for omp: omp stops prompting on its own (its default approvalMode is already yolo). Turning this off leaves omp with no approval gate at all.`
  - 危险兜底说明：`应用未运行时仍会拒绝已知的危险命令；该名单是客户端启发式，可被绕过。` / `Known-dangerous commands are still rejected when the app is not running; that list is a client-side heuristic and can be bypassed.`
- **应用未运行时的行为（降级档，v2 修订）**：开关下方给一个三选一（`strict` / `notify-only`（默认）/ `read-only-allow`，语义见 §5.4）：
  - 标题：`应用未运行时的行为` / `When AgentIsland is not running`
  - 选项文案：`一律拒绝（strict）` / `放行并事后展示（notify-only，默认）` / `只放行只读工具（read-only-allow）`；对应 en：`Reject everything (strict)` / `Allow, show afterwards (notify-only, default)` / `Allow read-only tools only (read-only-allow)`
  - 说明：`降级时 agent 会在终端显示一行「闸门离线」。已知的危险命令在任何档位下都会被拒绝。` / `On degradation the agent prints "gate offline" in the terminal. Known-dangerous commands are rejected in every mode.`
- **「OMP 负责」与「OMP 自拒」的展示（v2 修订）**：卡片需区分三态（§5.7）：`刘海负责` 给 Allow/Deny；`OMP 负责` 只显示「终端正在询问」+「前往终端」；`OMP 自拒` 显示 `OMP 拒绝（无审批 UI）`——文案必须与用户自己的拒绝区分开。
  - en：`Waiting in terminal` / `Rejected by OMP (no approval UI)`

---

## 7. opencode 路径（P2；本期不做也要写清代价）

### 7.1 做法

```
opencode 插件（~/.config/opencode/plugins/agent-island-state.js）
  ├─ server: async ({ client, serverUrl }) => { … }        // 宿主注入 client + serverUrl
  ├─ event hook 订阅 permission.asked / permission.v2.asked
  │     → socket 问刘海（expects_response:true, tool_use_id = p.id）
  │     → 决策：allow → POST /permission/{id}/reply {reply:"once"}
  │              deny  → POST … {reply:"reject", message: reason}
  │     → 应用不可达/超时 → 不 reply（保持 opencode 原生 TUI 审批）
  └─ 阻塞期间不再上报同会话的非生命周期事件（避免刷屏）
```

| 项 | 事实 | 证据 |
| --- | --- | --- |
| 事件与 payload | `permission.asked{id, sessionID, permission, patterns, metadata, always, tool?}`；`permission.replied{sessionID, requestID, reply}`；另有 `permission.v2.asked/replied` | WS-D §5.3（二进制 zod 定义）；CodeIsland 参考实现 `codeisland-opencode-remote.js:257-283` 同时兼容两代 |
| reply 端点 | `POST /permission/{requestID}/reply`，body `{reply:"once"\|"always"\|"reject", message?}`；v2：`POST /api/session/:sessionID/permission/:requestID/reply` | WS-D §5.3；CodeIsland `:339-352` |
| 服务端阻塞语义 | `ask()` → `Deferred.await`，无超时 → 不 reply 则 run 停住 | WS-D §5.3（上游 `permission/index.ts`） |
| 插件如何拿地址/凭据 | **插件工厂参数直接给**：`server: async ({ client, serverUrl })` → `serverPort = parseInt(serverUrl.port) \|\| 4096`、`heyApi = client._client`（`@hey-api/client-fetch`）；回写优先 `heyApi.request(...)`，失败回落 `fetch("http://localhost:${serverPort}/…")` | `CodeIsland/Sources/CodeIsland/Resources/codeisland-opencode.js:47-51,53-63`；`codeisland-opencode-remote.js:339-352` |
| 需要凭据吗 | **本机不需要**（同机 localhost，无鉴权）。只有插件跑在**远端主机**时才需要经 `codeisland-remote-hook.py` 反代到本地 socket（`_remote_host_id/_remote_host_name` 靠环境变量） | `codeisland-opencode-remote.js:1-33,339-352` |
| `permission.ask` hook | 类型与文档都在，但 1.18.27 二进制内**无调用点**，上游 service 也不触发它 → **[推断] 当前无效，不要依赖**。参考实现的两个插件都**没有**用它 | WS-D §5.2（字节级穷举）；[推断] 需在真机做一次「插件改 `output.status` 是否影响审批」的消融才能确证 |
| 我方现状 | `AgentIsland/Resources/agent-island-opencode-plugin.js:134-142` 注册了 `permission.ask` 但只 `send` 状态；`:163-173` 用 `event:"ToolApproval"` 上报 | 今日复核 |
| 与 Claude 的语义差异 | Claude 是「hook 同步 stdio 应答」；opencode 是「事件 + 独立 HTTP 回调，请求本身是一次挂起的 HTTP 事务」 | WS-D §5.5 |
| 多会话并发（v2） | 上报与应答都必须带 `session_id` + `tool_use_id`（= `p.id` = requestID）；插件阻塞期间用 `pendingRequestSessions` 抑制同会话的普通事件，避免刷屏 | 参考实现 `codeisland-opencode-remote.js:45,357-362,408-414`；§4.1 的并发硬需求同样适用 |
| 降级（v2） | 应用不可达 / 超时 → **不 reply**；用户可选档位在这里体现为「不 reply 就是交给 opencode 原生 TUI」（opencode 没有「拒绝一切」的档位语义，`strict` 档在 opencode 上退化为「超时后 reply reject」——需在 UI 上注明） | §5.4 三档 + 本节 ③ |

### 7.2 代价与工作量

- 工作量：小（约 1 个文件、80–120 行）：把 `permission.ask` 分支改成 `expects_response:true` 上报 + 等待 + reply；`allow/deny` → `once/reject` 映射；阻塞期抑制事件。
- 代价/风险：① `permission.asked` 与 v2 变量都要兼容（版本漂移）；② 需要真机消融才能确认 `permission.ask` 是否已可用（若可用则可退化为「插件内直接决定」，更简单）；③ 应用不可达时必须**不 reply**（让 opencode 原生 TUI 接管），与 Claude 的 fail-open 一致；④ 「always」在 opencode 里是 `reply:"always"`（服务端自己把 patterns 加进 approved），我们不额外实现（§11）。

---

## 8. 分阶段实施计划

### P0 —— 应用侧泛化与缺陷修复（不新增能力；omp/pi 行为不变）

| 项 | 内容 |
| --- | --- |
| 改动文件 | `Services/Hooks/HookSocketServer.swift`（M1/M2/M4/M8/M10/M12、B1/B2/B3）、`Models/AgentKind.swift`（M3）、`Services/Session/ClaudeSessionMonitor.swift`（M7/M8/M9）、`Models/SessionEvent.swift`（不改判定，只加注释与 `ToolApproval` 语义说明）、`Services/Agents/AgentIntegrationInstaller.swift`（M11 版本戳基础设施）、`UI/Views/ChatView.swift` + `UI/Views/ClaudeInstancesView.swift` + `Resources/Localizable.xcstrings`（B4/B5、i18n） |
| 验收判据 | ① Claude 全链路逐跳不变：真 Claude 会话触发一次 `PermissionRequest` → 刘海 Allow → 工具执行；Deny → 模型收到 `Denied by user via AgentIsland`（脚本 `agent-island-state.py:171` 的兜底串）② 新增单测：同 `toolUseId` 不同 agent 两条 pending **独立存活**；opencode 式 `ToolApproval`（无 `expects_response`）**不**产生 pending；TTL 收割后 `hasPendingPermission` 转 false ③ `grep -rn supportsPermissionControl AgentIsland/` 归零（或仅剩过渡别名定义）④ swiftc 整树类型检查 0 error ⑤ i18n 双向校验通过（§9.5） |
| 回滚 | 单个 commit `revert`（无用户配置写入，无外部文件改动） |

### P1 —— omp + pi 闸门（本期核心）

| 项 | 内容 |
| --- | --- |
| 改动文件 | ① `Resources/agent-island-pi-extension.ts.txt`（闸门版 + `requestDecision` + 名单表 + **三态让位（§5.7）** + **降级三档（§5.4）** + 版本戳；**替换后保留一份只上报版** `agent-island-pi-extension-report-only.ts.txt` 供关闭开关时用）② `Services/Agents/AgentIntegrationInstaller.swift`（版本戳比对 + 只上报版切换）③ **新文件** `Services/Agents/OmpConfigInstaller.swift`（`config.yml` 备份 / `omp config set` / 校验 / 回滚）④ `Models/AgentKind.swift`（omp/pi 的 `approval.canDecideRemotely = true`）⑤ `UI/Components/AgentSettingsSection.swift` + `Core/Settings.swift`（默认关的开关 + 降级档选择器）⑥ `Localizable.xcstrings`（§6.4 文案，zh-Hans + en，**按键名合并**）⑦ `Services/Hooks/HookSocketServer.swift`（若 P0 的 B2 读窗口需调整）。**动手前按 §0.1 重新 grep 符号**（该文件与他人 WIP 同文件） |
| 验收判据 | ① 隔离环境复跑 RUN 矩阵（allow → `ISLAND_TOOL_RAN`；deny → 模型收到理由且工具未执行；静默 → 客户端超时 → 拒绝且理由可读）② **降级三档各验一次**（`strict` 全拒 / `notify-only` 普通命令照跑且 TUI 出现「闸门离线」/ `read-only-allow` 只放只读）+ 危险命令在任何档位都被拒 ③ 真 TUI（tmux）下**只有刘海上一个提示**（T2 场景需真的构造：`--approval-mode write` + exec 档 → 断言刘海**让位**显示「终端正在询问」而不是两个入口） ④ **OMP 自拒与刘海拒绝可区分**（构造 headless/no-UI 场景，断言 UI 文案不同）⑤ **多会话并发**：同时开 2 个 omp 会话各触发一次审批 → 两张卡分属不同会话、互不串台 ⑥ pi 侧一次端到端（`~/.pi` 无审批门，验证 deny 生效 + 降级行为）⑦ 应用侧 `pendingPermissions` 在 TTL 后自清（`lsof` 无残留 fd） |
| 回滚 | 关闭开关 → 恢复 `config.yml` 备份 + 换回只上报扩展；再不行 `git revert` P1 commit（用户配置由备份还原） |

### P2 —— opencode

| 项 | 内容 |
| --- | --- |
| 改动文件 | `Resources/agent-island-opencode-plugin.js`（§7.1）、`Models/AgentKind.swift`（opencode capability 置真）、`Localizable.xcstrings` |
| 验收判据 | 真 opencode（1.18.27）触发一次 `permission.asked` → 刘海 Allow → run 继续；Deny → 工具被拒且理由可读；app 未运行 → 插件**不 reply** → opencode 原生 TUI 审批照旧 |
| 回滚 | 插件替换为只上报版（版本戳比对自动生效） |

### P3 —— 可选增强（不做不影响本期目标）

| 项 | 说明 | 判据 |
| --- | --- | --- |
| always / 记住决定 | omp：写 `tools.approval.<tool>: allow`（要 merge 写用户配置）；opencode：`reply:"always"`；Claude：`updatedPermissions`（`destination:"session"`） | 各 agent 独立验收；**默认不做**（§11） |
| 问答通道 | omp/pi 的 `ask`（`tool_execution_start` 已可用，`:413-440`）与 Claude 的 `AskUserQuestion` 复用决策通道 | 刘海能答题 |
| tmux 兜底 | 按键表 per-agent（`Escape/↑/↓/Enter`，TUI-1 实测）+ 弹窗识别 | 无扩展时也能批准 |
| collab / ACP / SDK | 对 live TUI 的 `ui-response`（需 relay）或拥有会话 | 不改启动方式地答原生弹窗 |
| **`omp --mode rpc`（C′，v2 新增）** | **官方协议级审批通道**：`extension_ui_request{method:"select"}` → `extension_ui_response`（R2/R3 实测）。收益＝无扩展、无 yolo、无 30s 上限、语义与 TUI 一致；代价＝**会话变 headless、客户端必须自己持有并渲染会话流**（prompt/事件流），是本方案最大工程量。**何时值得做**：用户要求最强语义/不愿装扩展；或未来做「由应用启动会话」的产品形态（WS-E P5） | 用最小客户端跑通「审批 + 其余原样回显」；`[推断]` 可行性未知，故列为可选形态而非承诺 |
| 远端 SSH | 反向转发 socket | 远端 omp/pi 也能上刘海 |
| 多 agent 待批计数 | 闭合态只有一个手形图标（`NotchView.swift:94`） | 3 agent 同待批时可区分 |

---

## 9. 验证计划（怎么证明「真的生效」）

### 9.1 隔离环境跑真 omp/pi（复用 WS-A 手法）

```bash
# 一次性准备（真实环境零改动）
mkdir -p /tmp/ai-approve/p1/{home,agent,ext,logs}
# 凭据纪律见 §9.7：只用 600 权限的副本，或 symlink，或实验后删除
install -m 600 ~/.omp/agent/models.yml /tmp/ai-approve/p1/agent/models.yml
install -m 600 ~/.omp/agent/config.yml /tmp/ai-approve/p1/agent/config.yml   # 需要改配置的实验才复制
# 推荐：不改凭据配置时**不要**复制 models.yml，改用一个假 key 的自建 models.yml

# 每次运行：真实 omp，沙箱 HOME + 沙箱 agent 目录 + 我们的扩展
HOME=/tmp/ai-approve/p1/home \
PI_CODING_AGENT_DIR=/tmp/ai-approve/p1/agent \
  omp -p --no-session -e /tmp/ai-approve/p1/ext/agent-island-state.ts \
  "run: printf ISLAND_MARK"
```

- 环境变量语义：`PI_CODING_AGENT_DIR` = agent 目录整体覆盖；`PI_CONFIG_DIR` = home 下的配置根名（`omp://environment-variables.md`）。
- **隔离成立的证明**（WS-A §1 的做法，P1 要重跑一遍）：新增日志文件的 pid 全部落在本次进程集合内；`find ~/.pi ~/.claude -newer <marker>` 为空。

### 9.2 刘海替身（unix socket）

复用 `/tmp/ai-approve/approve_server.py` 的形态：按 `/tmp/…/server_mode.txt` 逐请求决定 `allow` / `deny` / `silence`（沉默用于超时路径），并记录收到的 payload 与时刻。

### 9.3 四条路径（P1 必测）

| 路径 | 操作 | 期望 |
| --- | --- | --- |
| allow | server_mode=allow，扩展问一件事 | 模型输出 `ISLAND_MARK`；server 日志有一来一回 |
| deny | server_mode=deny | 模型看到 `reason`（逐字核对）；工具未执行 |
| timeout | server_mode=silence，客户端超时设为 3s（测试用） | 工具被拒，理由 = 超时文案（**不是** `Extension … timed out after 30000ms`） |
| kill app | 不启动 server（ENOENT） | 普通命令**照常执行**；`rm -rf /` 被拒（客户端兜底） |

### 9.4 真 TUI 取帧（无双提示）

```bash
tmux -L ara new-session -d -s omp 'HOME=/tmp/ai-approve/p1/home PI_CODING_AGENT_DIR=/tmp/ai-approve/p1/agent omp'
tmux -L ara send-keys -t omp 'run: printf TUI_MARK' Enter
tmux -L ara capture-pane -p -t omp > /tmp/ai-approve/p1/frames/f1.txt
# 断言：挂起期间帧里没有 "Allow tool: bash"（OMP 自己的弹窗），且 footer 计时器仍在推进
grep -c "Allow tool" /tmp/ai-approve/p1/frames/f1.txt   # 期望 0
```

（`Allow tool:` 文案来自 omp 的审批提示格式；TUI-1 帧见过 `up/down navigate enter select esc cancel`。）

### 9.5 应用侧单测、消融与 i18n

| 项 | 内容 |
| --- | --- |
| 单测（新增） | ① 两 agent 同 `toolUseId` 的 pending 隔离（M2 的守护）② TTL 收割（M10）③ `ToolApproval` 无 `expects_response` 不产生 pending（M4）④ 失败回调带 `SessionKey`（M8）⑤ capability 驱动的 UI 分支（M3/B5） |
| 消融 | 把 M2 临时改回裸 `toolUseId` → ① 必须变红；把 M4 的 `wantsResponse` 判定去掉 → ③ 必须变红。**红绿两态都要留证据**（共享工作树里做消融要按仓库既有纪律，改动最小化并及时恢复） |
| 类型检查（本机无 Xcode） | `DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc -typecheck -swift-version 5 -default-isolation MainActor -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -target arm64-apple-macos15.6 …`（判据 `grep -cE ': (error\|warning):'`，**告警也要清零**） |
| i18n 双向校验 | ① 代码 → catalog：扫 `.t("…")` 字面量（含 `l10n.t(` / `Self.l10n.t(` / `LocalizationManager.t(`）② catalog → 代码：找死键 ③ en/zh-Hans 的 `%` 说明符多重集必须一致。**缺键会静默回退成英文 key，单测不会红**，所以必须机器校验 |
| 端到端（真机） | 开启开关 → 在真 omp 会话里让模型跑 `printf X` → 刘海上点 Allow → 终端出现 `X`；再点 Deny → 模型收到理由。**这是本功能唯一的最终验收** |

### 9.6 v2 追加的验收项（来自 WS-E 的 T 系列与 R 系列）

| # | 要证明的事 | 怎么做 | 判据 |
| --- | --- | --- | --- |
| V1 | `block` 短路 OMP 提示 | 复跑 **T3**：`--approval-mode write` + handler 返回 `{block:true}` | 模型收到我们给的 reason，**且没有** `tool_approval_requested` 事件 |
| V2 | write 档不双提示（不要做多余规避） | 复跑 **T4**：`--approval-mode write` + 让模型用 `write` 工具写文件 | 文件真的被写；**无** approval 事件 |
| V3 | 双提示只在 exec 档发生 | 复跑 **T2**：`--approval-mode write` + `bash` | 出现 `approval_requested` → 断言刘海**让位**为「终端正在询问」（§5.7 ②） |
| V4 | 用户显式 `prompt` 策略仍会弹（yolo 下） | 复跑 **T10**：`tools.approval.bash: prompt` + yolo + 扩展 allow | 出现 approval 事件 → 刘海让位；应用侧告警（§6.3） |
| V5 | 超时预算可配 + 预算豁免 | 复跑 **T5**（`toolCallTimeoutMs: 3000` + 睡 8s）；再验 §5.3 方案 2（`ctx.ui.custom` 持有 + 睡 > 30s） | T5：`handler timed out after 3000ms` 且工具未执行；方案 2：**不超时**（若成立则记录为「方案 2 通过验证」） |
| V6 | 子会话过闸 + `yield` 也过闸 | 复跑 **T7**（`task` 起子 agent 跑 `echo`） | 子会话的 `sessionFile` 为 `<agent>.jsonl`；断言闸门**放行**子会话（除 critical） |
| V7 | `--mode rpc` 原生审批（若做 C′） | 复跑 **R2/R3**：`omp --mode rpc --approval-mode write`，客户端回 `Approve`/`Deny` | `tool_execution_end isError=false` / `Tool call denied by user: bash` |
| V8 | `hooks/pre/` 不能绕过超时（别指望这条捷径） | 复跑 **T8**：探针放 `$PI_CODING_AGENT_DIR/hooks/pre/` + 3s 超时 + 睡 8s | 仍报 `handler timed out after 3000ms`（`docs/hooks.md`：默认 CLI 走 extension runner） |
| V9 | 多会话并发不串台 | 同时开 2 个 omp 会话各触发一次审批 | 两张卡分属不同 `session_id`/`session_file`；点 A 的 Allow 不影响 B |
| V10 | **「刘海拒绝」与「OMP 自拒」在 UI 上可区分**（WS-E §2.3 第 2 点） | 构造一次 **OMP 自拒**：headless（`omp -p`）下让模型跑一个需要审批的工具（或 `--approval-mode write` + exec 档） | 刘海显示 `OMP 拒绝（无审批 UI）`（而非 `已拒绝`），reason 前缀与刘海拒绝不同；断言两者**不会**被渲染成同一状态 |
| V11 | 「OMP 负责」让位时刘海不给拒绝入口 | 复跑 T10（yolo + `tools.approval.bash: prompt`） | 卡片切到「终端正在询问」，**没有** Allow/Deny 按钮（避免先拒者胜） |

### 9.7 实验凭据卫生（v2 新增，硬纪律）

- **背景**：`/tmp` 在 macOS 上是 `/private/tmp`（默认 1777）。WS-E 发现 `/tmp/ai-approve/agent/` 下有另一位 worker 复制的**真实** `models.yml`（含明文 `sk-…` key）与 `agent.db`（6.7 MB）。
- **本轮已做的加固（E7）**：`chmod 600` 于 `/tmp/ai-approve/agent/models.yml`、`/tmp/ai-approve/agent/history.db`、`/tmp/ai-approve/e-agent/models.yml`；并确认 `/tmp/ai-approve/agent` 目录本身是 `0700`（其他用户无法遍历，故此前实际不可被他人读取——**但不应依赖目录权限兜底**）。
- **规则（P1 起遵守）**：
  1. **优先不复制凭据**：自建一个只含**假 key** 的 `models.yml`（WS-E 的做法：指向本机网关 `http://127.0.0.1:15721/v1`，假 `sk-`），隔离实验完全够用；
  2. 确实需要真实凭据时：用 `install -m 600` 复制（**不要 `cp` 后用默认 644**），或直接 `ln -s` 指向原文件（不产生副本）；
  3. **实验结束即删**：`rm -rf /tmp/ai-approve/<本次实验目录>`，或至少删除 `models.yml` / `agent.db` / `history.db`；
  4. 交付前自查：`grep -rl 'sk-' /tmp/ai-approve/ | head` 与 `ls -l` 复核权限。

---

## 10. 风险与未决问题

### 10.1 风险

| 类别 | 风险 | 缓解 |
| --- | --- | --- |
| 安全 | **闸门被绕过**：扩展未加载（omp 的扩展加载失败是逐扩展隔离，失败的扩展 = 无门）、用户手改扩展、app 升级未重写 | M11 版本戳 + `isInstalled` 判版本 + 启动自检「扩展内容版本 == app 期望版本」，不一致时 UI 警告；扩展文件头写清「由 AgentIsland 管理，勿手改」 |
| 安全 | **yolo 下无原生兜底**：一旦我们的 handler 静默失效（例如事件名漂移），omp 就是「无审批」 | ① 名单表与 handler 里加「自检心跳」：扩展启动时上报 `integration_version` + `gate_enabled`，应用侧据此判断「闸门是否真的在用」；② 单元/端到端矩阵（§9.3）纳入回归 |
| 可用性 | **超时取值**：120s 太短会打断深度思考的用户；太长会在用户离开时长时间卡住会话（该工具及其并行批次被阻塞，TUI 不冻结） | 默认 120s + 卡片最后 10s 倒计时；真的需要长考的用户可在 §10-1 选择 300s |
| 可用性 | **双提示**：用户显式 `approvalMode: write` 或 `tools.approval.<tool>: prompt` 时 | 安装时（以及每次 `session_start`）读 `approval_mode` 上报 → 设置面板提示 + 可选一键改 yolo（§6.3） |
| 可用性 | **fd / 并发**：每个 pending 占一个 fd，backlog 目前 10 | B3 提到 32；M10 收割；`lsof` 观测 |
| 维护 | **omp 扩展 API 漂移**：`tool_call` 事件字段/返回语义、`extensionHandlers` 键名、`CRITICAL_BASH_PATTERNS` 内容 | 版本戳 + 把 §9.3 的矩阵脚本固化成 `scripts/verify-omp-gate.sh`，omp 升级后跑一次；tier/危险名单注明「随 omp 版本人工校准」 |
| 维护 | **名单过时**：omp 新增工具默认落 `exec`（文档：未声明即 `exec`），我们的名单会漏 | 采用「默认询问」取向：名单只列 **never-ask** 白名单，其余一律问 → 新工具自动落入「要问」，漏的是「多问」而不是「漏问」 |
| 维护 | **opencode 变体**（`permission.asked` vs `permission.v2.asked`） | 两代都订阅（参考实现的做法）；`permission.ask` 不可依赖 |
| 反直觉 | 拒 `yield` → 子代理无法交付 | `yield` 进 never-ask（§5.5） |
| 配置 | `omp config set` 会重排用户 YAML 格式（**E4**） | 写前备份 + 只写一个键 + 卸载还原 |
| 安全（v2） | **fail-closed 的真实触发面比预想宽**：headless（`-p` / `--mode json`）、子 agent（强制 yolo 但 `hasUI=false`）、以及任何「OMP 自认为该弹但弹不出来」的场景，都会被 **OMP 自己**拒掉，而不是被闸门拒掉 | 两类拒绝在 UI 上必须可区分（§5.4/§5.7 ③）：`刘海拒绝` vs `OMP 拒绝（无审批 UI）`，否则用户以为是自己点的 |
| 安全（v2） | **两个入口互相等待**：非 yolo 的 exec 档、yolo + 显式 `prompt`、`computer` safetyChecks 下，OMP 自己也会弹 | 让位三态（§5.7 ②）+ 告警收窄（§6.3）；让位时刘海不再提供拒绝，避免先拒者胜的语义叠加 |
| 可用性（v2） | **降级不可配置 = 用户三次之后卸载闸门**（app 一没开就什么都不能做）| 三档可配置 + 降级在 TUI 可见（§5.4/§6.4）；默认 `notify-only` |
| 安全性（v2） | **把 `pi.pi.settings` 当安全判据** → omp 升级即可能失效或语义漂移 | 该 API 只作诊断/告警（§5.5）；策略来自自持名单表；特性探测失败 → 降级为只上报（§5.4） |
| 可用性（v2） | **多会话并发是现场事实**：本机 7 个 omp 会话跨 3 个项目同时跑 | 信封带 `session_id`/`session_file`/`cwd`；刘海按会话分组；**禁止全局单例闸门状态**（§4.1） |
| 可用性（v2） | **远端 SSH 上跑 omp：闸门完全不存在**（扩展与 socket 都在远端） | 明确不支持，**UI 不假装支持**；要支持需远端也装扩展 + 反向隧道（P3） |
| 可用性（v2） | **会话被 kill / Esc 后卡片还留在屏上**：点「批准」等于给一个已死的请求作答 | ③ 态（§5.7）：收到中止/取消 → 撤卡；扩展侧在 abort 时通知应用 |
| 维护（v2） | **omp 升级可能改默认值/超时语义/事件契约** | 启动握手校验 `omp --version`（声明支持 ≥ 18.2.x）+ 版本戳 + `scripts/verify-omp-gate.sh`（§9.3/9.6 固化为脚本）；`pi.pi` 探测失败即降级告警 |
| 维护（v2） | **`xdev`/ACP bypass 干扰**：`wrapper.ts:257-270` 在特定条件下跳过 tier 提示 | 闸门只按「是否需要 approval」决策，**不去镜像 OMP 的 bypass 逻辑**；把 bypass 视为「OMP 已批准」（WS-E §3.12） |
| 纪律（v2） | **凭据副本留在共享目录**（`/tmp` 默认 1777，真实 `models.yml` 含明文 key） | §9.7 四条规则 + 交付前 `grep -rl 'sk-' /tmp/...` 自查（本轮已 `chmod 600`，见 E7） |

### 10.2 必须由你拍板的决定（6 条）

| # | 决定 | 推荐 | 理由 |
| --- | --- | --- | --- |
| 1 | 客户端超时预算与语义 | **120s，超时=拒绝**；omp 服务端预算提到 300s | 刘海上的一次决定是「扫一眼」；yolo 下超时放行 = 静默执行任意命令（§5.4） |
| 2 | 子代理（subagent）的工具调用是否上刘海 | **默认不上**（除危险命令），卡片标注子代理归属 | 子代理常并发，逐条上卡片会刷屏并阻塞；`task` 本身已是授权边界（omp 文档）；但可能漏掉「子代理里的危险动作」→ 由 critical 兜住 |
| 3 | 允许安装器改写 `~/.omp/agent/config.yml` 吗 | **允许，但只写 `extensionHandlers.toolCallTimeoutMs`**（方案 1），不写 `approvalMode`；写前备份。**若 §5.3 的方案 2（预算豁免）验证通过，可完全不写**（v2 修订） | 不写超时会让 30s 的 fail-closed 成为默认体验；不动 `approvalMode` 因为默认已是 yolo（写了反而掩盖「用户自己选的」）；需要范围化时用项目层（§6.1） |
| 4 | **app 不可达 / 在等待中被杀时的行为**（v2 修订，把原第 4 条与 WS-E P3 合并） | 拆成两个场景：**① app 从未运行** → **默认 `notify-only`（放行 + 记录 + 刘海事后展示；危险命令仍拒）**，另备 `strict` / `read-only-allow` 两档由用户选；**② 等待中被杀（已投递过卡片）** → **拒绝** + 可读 reason | ① 保证「AgentIsland 没开也不会让 omp/pi 不可用」，同时降级**必须可见**（TUI 打印「闸门离线」）；② 已经问过人，不静默放行。两者 UI 提示必须不同（§5.4） |
| 5 | opencode 是否本期做 | **本期做 P2**（工作量小、收益明确），但不阻塞 P1 上线 | 一个文件、80–120 行；且能让「多 agent 都能在刘海上决定」这件事一次说清 |
| 6 | 「关闭开关」的安全语义 | **仅停用闸门 + 文案明确告知「omp 将不再有任何审批闸门」**；若你愿意，再加一个可选按钮「同时把 approvalMode 设为 write（恢复 omp 原生提示）」 | 关闭不等于恢复原状（§6.3）；给用户一个真正能回到「omp 自己问」的选项 |

---

## 11. 明确不做的事

1. **不照搬 CodeIsland 的 17 个 agent 安装器**（`Sources/CodeIsland/ConfigInstaller.swift` 约 3400 行里约 2000 行是 YAML/TOML 外科手术式合并）。本期只做 **Claude（已存在）+ omp + pi + opencode** 四条。
2. **不逐字抄 `CodeIsland` 的代码**（虽同为 MIT）：只借鉴结构（能力矩阵、fail-open 语义、版本戳、pending 键的教训）。所有需要的能力都能独立实现。
3. **不引入 bridge 二进制**：E1/E2 证明我们的 BSD socket 服务端容忍半关闭，不需要 `shutdown(SHUT_WR)` 绕道；仅当真机端到端复现出丢应答时才重新评估。
4. **不做「影子 `ask` 工具 + 竞速」**（CodeIsland `codeisland-omp.ts:637-905`）：本期问答通道不在范围内（P3 再议），它引入的竞速/abort 复杂度与我们的目标无关。
5. **不做 tmux 按键作为主路径**（`ToolApprovalHandler.swift` 仍是未接线遗留代码：`1/2/n` 硬编码、无 UI 调用者）。只在 P3 作为「无扩展时」的兜底。
6. **不用 ACP/SDK/collab 作为主路径**：它们都要求「外部拥有会话」或「开房间 + relay」，改变了用户使用 omp 的方式。
   - **（v2 修订）也不用 `omp --mode rpc`（C′）作为主路径**：它是唯一官方协议级通道（R2/R3 实测），但要求 app 成为会话宿主并渲染会话流 —— **本期只作为 P3 的可选产品形态**记录下来，不在 P0–P2 实施；也**不**把它写成「已经支持」。
7. **本期不做 always / 记住决定**：CodeIsland 对 pi/omp 也没有 always（`{block:true}` 只支持拦、不支持批）；我们要做就得写进各 agent 自己的配置（omp `tools.approval.<tool>: allow`；Claude `updatedPermissions`），属于独立能力，风险与验收面都不同。
8. **不抄 Gemini 的 24 小时超时写法**（把 `86400`/`86400000` 写进用户配置）：用户会看到诡异的配置值；omp 侧用 `extensionHandlers.toolCallTimeoutMs` 这个**语义明确的键**表达同一件事。
9. **不引入「按 source 全局免打扰」默认白名单**（CodeIsland 的 `autoApproveSources`；它有注释记录「默认放过 9 个内部工具」是错误决定）。默认必须问。
10. **不做无决策能力的 agent 的「假审批」**（Hermes/Cursor 类只有 before/after 事件、没有决策语义的）：只展示状态。
11. **不在 P0 里夹带能力改动**：P0 的判据是「Claude 行为逐跳不变」，任何能力开关的打开都放 P1。
12. **（v2 新增）不做 tmux 盲发按键**：不发 `Esc`（弹窗不在屏上时会**中断当前 agent 回合**）、不盲发 `Enter`（会把没写完的提示提交给模型）。若 P3 做 tmux 兜底，必须「先验屏（只取可视区 + 光标行）、只发 `Enter`、发完再验屏、失败即回滚为 OMP 原生提示」（WS-E §4.3）。
13. **（v2 新增）不把 `pi.pi.settings` 等未文档化内部出口用作安全判据**：只用于诊断与告警（§5.5）。
14. **（v2 新增）不做「静默接管」**：用户显式配置了非 yolo 的 `approvalMode` 时，不擅自改写、不假装闸门仍在决定——只告警并让位（§6.3/§5.7）。
15. **（v2 新增）不动全局 `~/.omp/agent/config.yml` 的 `tools.approvalMode`**：默认已是 yolo，写它纯属留痕；需要范围化时用项目层（§6.1）。

---

## 12. 问答通道（ask）（v3 新增）

**目标**：omp 的交互式提问（原生 `ask` 工具）过去只能在终端作答。本切片把它接到刘海——扩展注册**同名影子 `ask`** 顶掉内置实现，刘海与终端两条路竞速，**先答者胜**；两条路的败者都要收干净。

### 12.1 协议

**上行**（扩展 → 应用）沿用 `ToolApproval` 信封（老信封字节不变，只新增两个可选键）：

> 零选/取消的一手依据：omp 源码 `packages/coding-agent/src/tools/ask.ts`（`askSingleQuestion` 的多选分支、`formatSingleQuestionResponse`、`formatQuestionResult`），以及本机 omp 二进制内的两条文案 `User did not select any options` / `User cancelled the selection`（前者走 `multi` 分支、后者是取消）。


```
event: "ToolApproval", status: "waiting_for_approval", expects_response: true,
tool: "ask", tool_use_id: <该 ask 调用的 toolCallId>,
ask: { questions: [ { id, question, header?, multi_select, free_text, options: [ { label, description? } ] } ] }
```

- `multi_select` 取自原生 `multi`（缺省按单选）；`options[].label` 必有、`description?` 可选、`preview` **不上行**（刘海不渲染富预览）。
- `free_text` **恒为 true**：原生对每个问题都会自动补一行 “Other (type your own)”（`ask.ts:42`），上报 `false` 等于凭空砍掉一个原生就有的入口。
- 应用侧解码为 `HookEvent.ask: AskPayload?`（`HookSocketServer.swift`，`CodingKeys` 里 `ask`；`AskQuestion` 的 `multi_select` / `free_text` 缺省按 `false`、`options` 缺省空数组）。

**下行**（应用 → 扩展）：

```
{"decision":"answer","answers":{<问题 id>: [<选中的 label> | <自由文本>]}}
```

- 用户放弃作答走既有的 `deny`；`allow` / `ask` 两个旧取值的语义与**字段集合**逐字不变（`HookResponse.encode` 是手写的，缺省键不会出现在字节里；写回统一经 `AskAnswerBuilder.normalized`，因此「`answer` 但一个答案都没有」在服务端就被折成 `deny`，空答案不可能被发出去）。编码器固定 `sortedKeys`，字节形态稳定。
- **`answers` 的三种状态必须在字节上分得开（v5 冻结）**：**键存在** = 该题被作答；**值为空数组 `[]`** = 多选题的「一个都没选」；**键缺失** = 该题未作答。只有**所有键都缺失**时才折成 `deny`（= 跳过/取消）——**只要存在任一键（哪怕值是 `[]`）就发 `answer`**。
- **「零选」与原生同义，且不是取消**：omp 原生多选靠 `Next →`（`navigation.allowForward`）前移结束，**零勾选照样返回**（`selectedOptions = []`），结果文案 `User did not select any options`（多题形态是 `<id>: []`）→ 工具**正常完成、本轮继续**；而**取消**（单选 `choice === undefined`）走 `User cancelled the selection` + `ToolAbortError` → **终止本轮**。因此在刘海里：「零选」= **多选题未勾选任何项时点「提交」**（与逐题 `Next →` 等价，不需要额外控件），「跳过」= 取消/放弃（→ `deny`）。**提交可用性**（贴原生规则、且任何一次按键都不替用户做决定）：**全部都是多选** → 零交互也能提交，未勾选的题即零选；**含任一单选** → 每道单选都必须已有输入（选中或输入文本），否则提交不可用（用户要么选，要么走「跳过」）。此时未勾选的多选题仍按零选提交，卡片底部有提示说明这件事。
- **单选没有零选态**：未选中就是「不提交该题」（键缺失）。单选在原生里只有取消这一条出路，对应刘海侧的「跳过」。
- **Claude 不适用上一条**：Claude 的 `answers` 是「问题正文 → 字符串（多选逗号连接）」，**没有空值语义**——在 `updatedInput.answers` 里给空串等于「答了空文本」，与「零选」不是一回事；Claude 自己的对话框也不允许留空提交（每问都要作答或输入文本）。因此 `AskUserQuestion` 的零选不可表达（见 §12.6）。

### 12.2 影子 ask 的竞速与取消（扩展侧）

- 注册同名 `ask`：`approval: "read"`、`concurrency: "exclusive"`（都照抄原生，避免与原生并发抢弹窗），`NEVER_ASK_TOOLS` 里也含 `ask`，否则自己的 `tool_call` 闸门会把这次提问再拦一次。
- `execute` 内并发两条路：
  - **刘海**：发带 `ask` 负载的阻塞询问，等 `ASK_TIMEOUT_MS`（缺省 **240s**，`AGENT_ISLAND_ASK_TIMEOUT_MS` 可覆盖）；
  - **原生**：`ctx.invokeTool(params, { signal })` 委托内置实现，终端作答能力完整保留。
- 结算规则：
  - 刘海先答（`answer` + 非空答案）→ `abort()` 原生那条（撤下终端对话框）并返回刘海作答；
  - 原生先答 → 关掉刘海那条 socket，应用按「外部已裁决」撤卡；
  - 刘海明确放弃（`deny`）→ 撤下终端对话框，并**按原生取消语义**抛 `ToolAbortError`（不是「返回空答案」）；
  - 刘海超时 / 应用不可达 / 拿不到会话身份 / 非 TUI 根会话 / 没有原生可委托 → **一律原生独占**（功能不退化，也绝不假装问过）。
- 影子工具只在 **omp** 注册：pi 0.85.1 没有原生 `ask`，注册同名只会凭空多出一个永远失败的工具。

### 12.3 撤卡与超时的不变量

- **撤卡不依赖 TTL**：工具结束时扩展上报 `PostToolUse`（成功）或 `PostToolUseFailure`（拒绝/中止），应用在 `ClaudeSessionMonitor` 里按 `tool_use_id` 关掉那张卡。`Stop` 清会话待批的既有逻辑保留。
- **超时预算必须严格有序**（四层从外到内，任何两层**不得相等**）：

| 层 | 值 | 出处 |
| --- | --- | --- |
| **应用侧 pending TTL** | **330s** | `HookSocketServer.pendingTTL`（`AGENT_ISLAND_PENDING_TTL_SECONDS` 可覆盖） |
| omp 服务端 handler 预算 | 300000 ms（300s） | `~/.omp/agent/config.yml` 的 `extensionHandlers.toolCallTimeoutMs`（`OmpConfigInstaller.gateHandlerTimeoutMs`，用户开闸门时写入）；消费方是扩展 `tool_call` handler 的 active-work 预算（`config/settings-schema.ts:6094-6104`） |
| ask 客户端预算 | **240s** | 扩展 `ASK_TIMEOUT_MS`（`AGENT_ISLAND_ASK_TIMEOUT_MS` 可覆盖）；读题/权衡比「许可/拒绝」慢，且原生 `ask.timeout` 默认关闭 |
| 闸门客户端预算 | 120s | `AgentIntegrationInstaller.gateApprovalTimeoutMs`（安装时写进扩展的 `GATE_CONFIG.timeoutMs`） |

链条：**`app pending TTL 330s > omp 服务端 toolCallTimeoutMs 300s > ask 客户端 240s > 闸门客户端 120s`**。

- **为什么必须严格小于、不能相等**：相等时「谁先到点」不可判定——客户端以为自己仍是裁决者，服务端却可能在同一时刻 fail-closed，用户看到的是不可读的 `Extension … timed out` 而不是我们给的可读理由；而且相等这种配置在真机上要等满该时长才能证伪（整合验收已把它标为 [未实测]）。ask 客户端因此取 240s（相对服务端 300s 留 60s 余量），闸门客户端 120s 与服务端 300s 均不变。
- **TTL 与 ask 预算的关系**：TTL 330s 仍 > ask 240s、也 > 服务端 300s，保证「扩展先超时、应用后收割」；TTL 小于 ask 预算时，卡片会在用户思考期间被应用先收割 → 下图那条「作答无门」的路径就是它，因此 v3 把 TTL 从 150s 提到 330s。

### 12.4 只上报版也带影子 ask

`agent-island-pi-extension-report-only.ts.txt` 与闸门版**同源**，同样注册影子 ask：「只上报」只表示**不做闸门**（不拦 `tool_call`），问答通道与闸门开关无关。两个变体的版本戳同为 **3**（`AgentIntegrationInstaller.piFamilyExtensionVersion = 3`；安装器按「版本 + 变体 + （闸门版）降级档」判定是否重装）。

### 12.5 仍然存在的边界

- **「零选」已可表达（v5）**：多选题在刘海**未勾选任何项**时点「提交」即以 `[]` 作答（与原生 `User did not select any options` 同义，见 §12.1）；**整单都是多选时零交互也能直接提交**（与原生从零交互 `Next →` 前移一致）。**一条硬边界**：题面里只要有单选，未选中的单选就不允许被当成任何答案——提交保持不可用，用户要么选，要么走「跳过」（= 取消，终止本轮）。**Claude 例外**：它的 `answers` 没有空值语义，零选不可表达。
- **opencode 无提问通道**：插件不带 `ask`，本切片未改动它。

### 12.6 Claude 的 `AskUserQuestion`（v4 新增）

Claude 链路不是 TS 扩展，而是 hook 脚本 `AgentIsland/Resources/agent-island-state.py`（由
`HookInstaller` 装到 `~/.claude/hooks`，注册在 `PermissionRequest`，hook `timeout: 86400`）。
它在**同一条答案通道**上多做了两步：把提问归一成 `ask` 上行、把刘海的回答映射成 Claude 的
`updatedInput` 下行。

**与 omp 影子 ask 的差异**（同一条通道，两种接法）：

| | omp / pi 影子 ask | Claude `AskUserQuestion` |
| --- | --- | --- |
| 承载 | 扩展注册同名影子工具，`tool_call` 阻塞询问 | hook 脚本在 `PermissionRequest` 里阻塞一次 `recv` |
| 上行 | `ToolApproval` + `ask` | 同一个信封 + 同一份 `ask`（`event` 仍是 `PermissionRequest`，`tool` = `AskUserQuestion`） |
| 下行 | 扩展把 `answers` 当**工具返回值**交回模型 | 脚本把它折成 `hookSpecificOutput.decision = {"behavior":"allow","updatedInput":{…,"answers":{…}}}`，由 PermissionRequest 的 allow 通道**直接满足这次交互**（Claude 侧日志：`Hook satisfied user interaction for AskUserQuestion via updatedInput`），不再弹原生提问 |
| 放弃作答 | 扩展 `abort()` 原生那条并抛 `ToolAbortError` | 脚本回 `{"behavior":"deny"}`，Claude 按「被 hook 拒绝」处理 |
| 竞速 | 刘海与终端两条路抢 | 无竞速：刘海作答就完全替代原生弹窗；超时/不可达则不输出，原生弹窗照旧 |

**`answers` 的形状（Claude 侧）**：`Record<问题正文, 答案字符串>` ——

- **键 = 问题正文**（不是 header、不是序号）。两个一手证据：工具 `outputSchema.answers` 的描述是
  `"question text -> answer string; multi-select answers are comma-separated"`；工具结果的
  `mapToolResultToToolResultBlockParam` 里就是 `answers[question.question]`。
- **值 = 字符串**，多选用**逗号连接**；含 `", "` 或引号的项按 Claude 自己的编码加 JSON 引号
  （`label.includes(", ") || label.includes('"') ? JSON.stringify(label) : label`，解析侧按
  `", "` 切分并对 `"` 开头的段做 JSON.parse）——两端必须一致，否则标签会被拆错。
- `updatedInput` 里**必须原样带上 `questions`**（Claude 对它直接调 `.map()`，缺键抛
  `undefined is not an object (evaluating 'H.map')`）。
- 不需要去重后缀：输入 schema 的 refine 硬性要求同一调用内问题正文唯一
  （`"Question texts must be unique, option labels must be unique within each question"`），
  因此正文天然是唯一键；`ask.questions[].id` 直接取问题正文，下行不需要再做 id → 正文映射。
- 没有「不做答任何一题」的原生表达：Claude 自己用哨兵 `"(notes only)"` 表示「看完没选」。
  本实现不发这个值——**一题不答就整体走 `deny`**（刘海点「跳过」），避免替用户编造一个状态。

**上行归一（`build_ask_payload`）**：`question`→`question`+`id`、`header?`、`multiSelect`→`multi_select`、
`options[{label, description?}]`（`preview` 不上行，刘海不渲染富预览），`free_text` **恒真** ——
Claude 的原生弹窗对任何问题都提供自定义输入，且 `kind: "text" | "number"` 的问题本来就没有选项。

**等待预算**：ask 分支取 **240s**，与 omp 侧同值（`AGENT_ISLAND_ASK_TIMEOUT_SECONDS` 可覆盖，
正常路径不会触发）；普通审批分支保持 300s 逐字不变。四层链条不变：
**app pending TTL 330s > 普通审批 300s（本脚本）> ask 240s（本脚本 / 扩展）> 闸门 120s**。

**老客户端兼容**：旧版应用不认识 `ask` 键，会忽略它并照旧回 `allow`/`deny`；此时脚本按今天的语义
输出（`behavior: "allow"`），只是白白采不到答案，不会崩。

**真机验证的边界**：`claude -p`（headless）会话里 `AskUserQuestion` **不可用**——模型自报它不在
deferred tool list 里、ToolSearch 也搜不到，因此 headless 跑不出这条链路；可行的方法是 tmux 里的
交互式 `claude`（见附录 A 的 E8）。这也意味着：本通道只在交互式 Claude 会话里生效（与刘海的
存在前提一致）。

## 附录 A：本方案新增的实测证据

| # | 实验 | 命令/对象 | 结果 | 用于 |
| --- | --- | --- | --- | --- |
| E1 | Node 半关闭后仍能收应答 | `/tmp/ai-approve/halfclose/emu_server.py` + `client.mjs end` | 1503 ms 收到 `{"decision":"allow"}`；服务端 `got_eof:true`、读到 79 B 用 1 ms、1.5s 后写回成功 | §5.2 |
| E2 | 保持连接等待应答 | 同上 `client.mjs keep` | 1558 ms 收到应答；服务端 54 ms 结束读（50ms 静默）、fd 保留 | §5.2 |
| E3 | **负控**：写完即 `destroy()` | `node -e` 50 ms 后 destroy | 应答丢失；服务端 `write` → `Broken pipe` | §5.2/§5.4（现有扩展 400ms destroy 的等价物） |
| E4 | `omp config set` 是合并写但会重排格式 | 对 `config.yml` 副本执行 `omp config set extensionHandlers.toolCallTimeoutMs 300000` | 值写入成功；`providers.maxInFlightRequests: {}` 被展开成两行、末尾无换行 | §6.2 |
| E5 | omp 生效审批配置 | `omp config get tools.approvalMode` / `tools.approval` / `omp config list \| grep extensionHandlers` | `yolo` / `{}` / `extensionHandlers.toolCallTimeoutMs = 30000`；`~/.omp/agent/config.yml` 无 `tools:` 段 | §2.3/§6.3 |
| E6 | 已安装集成与 Claude 契约 | 读 `~/.claude/settings.json`、`~/.omp/agent/extensions/`、`~/.pi/agent/extensions/` | `PermissionRequest` + `timeout: 86400`；`agent-island-state.ts` 两处（omp 9441 B / pi 9439 B）；同目录存在第三方扩展（不得整目录重写） | §2.5/§5.6 |
| **E7（v2）** | 实验目录凭据加固 | `ls -l /tmp/ai-approve/agent/models.yml`；`chmod 600` 三处 | `models.yml` 原为 **644 且含明文 `sk-…`**；加固后 600；目录本身是 `0700`（此前不可被他人遍历）→ **规则见 §9.7** | §9.7/§10.1 |
| **E8（v4）** | Claude `AskUserQuestion` 经刘海答案通道作答（真机，端到端） | `~/.claude/hooks` 临时装载本仓脚本（挂载前后 sha256 对账、测后还原）+ `/tmp/ai-approve/r1-probe/e2e-server.py` socket 替身 + tmux 交互式 `claude`（2.1.263） | 替身收到 `PermissionRequest` / `tool: AskUserQuestion`，`ask.questions[0]` 完整（`id`/`question`/`header`/`multi_select`/`free_text`/`options[].label,description`）；TUI 显示 `User answered Claude's questions: · Which option should we ship? → Option BETA` 与 `Allowed by PermissionRequest hook`，模型随后回 `You chose Option BETA.`，**未弹原生提问** | §12.6 |
| **E9（v4）** | 同一链路的脚本级 harness（37 断言） | `/tmp/ai-approve/r1-probe/harness.py`（真 unix socket 替身 + 真脚本子进程） | `answer`→`behavior:"allow"` 且 `updatedInput.answers` 逐字段相符、`questions` 原样回带；`deny`→`behavior:"deny"`+message；沉默→2s（压小后的预算）到点、`exit 0` 且 **stdout 为空**；非 ask 的 `PermissionRequest`→字节与改造前逐字一致；旧应用只回 `allow`→字节不变；应用不可达→0.03s 返回且无输出；畸形/对不上的 `answer`→无输出回落原生 | §12.6 |

**非本方案作者运行的实验（引用他人结果）**：`RUN A–J` / `TUI-1,2` / `RPC-1,2` 来自 WS-A 的隔离实验；`T1–T10` / `R1–R3` 来自 WS-E 的隔离实验（脚本 `/tmp/ai-approve/{run_probe.sh, ext/probe.ts, ws-e-rpc-probe.py, ws-e-rpc-plain.py}`，日志 `/tmp/ai-approve/logs/probe.jsonl`）。本方案只引用其结论并标注用途。</

## 附录 B：与 WS-C 行号的差异说明

- WS-C 引用的行号整体偏小约 40 行（例：`expectsResponse` WS-C 记 `HookSocketServer.swift:104-106`，复核为 `:148`；`PendingPermission` 记 `:116-122`，复核为 `:160`；`pendingPermissions` 记 `:143`，复核为 `:187`；`ChatView` 的 `Claude Code needs your input` 记 `:1115`，复核为 `:1212`）。**符号与结论全部一致**。差异原因推测为 WS-C 测绘时的仓库版本与当前 HEAD 不同。
- **WS-F 已独立复核本文档的行号表**（§0.2），并给出结论：审批链路所需符号**逐个存在、无一缺失**，且**没有任何未提交改动触碰审批代码**（对全量 diff 的 `^[+-]` 行扫审批符号零命中）；`HookSocketServer.swift` 的 +44 行全部在 `struct HookEvent` 内并保留 11 参旧 init（故 `updatedEvent` 照旧编译）。
- **v2 后的口径**：行号只是 2026-09-20 的快照 —— 实现一律**按符号名 grep 定位**（§0.1），并以当时工作树为准。凡报告之间冲突之处，本文档以**可复核的当前源码**为准。