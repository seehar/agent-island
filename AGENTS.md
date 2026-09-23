# AgentIsland（macOS 刘海 Agent 会话面板）

> 一款 macOS 菜单栏应用（`LSUIElement`，无 Dock 图标）：把 17 个编码 Agent CLI —— Claude Code、Oh My Pi（`omp`）、Pi、OpenCode、Codex、Gemini CLI、Cursor、Copilot、Qoder、Factory（`droid`）、CodeBuddy、Kimi Code CLI、Cline、Grok CLI、Trae、Trae CLI、DeepSeek Harness（`dsh`）—— 的会话状态搬到 MacBook 刘海处的浮层里：实时状态、对话历史、用量统计，以及支持阻塞审批的工具在刘海上批准 / 拒绝 / 作答。
> 派生自 `engels74/claude-island`，已全量改名 AgentIsland（目录、target、scheme、bundle id、socket、集成文件名、偏好域）。

- 语言/框架：Swift（工程 `SWIFT_VERSION = 5.0`，但已打开 Swift 6 并发语义：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`、`SWIFT_APPROACHABLE_CONCURRENCY = YES`、`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`）
- UI：SwiftUI 为主 + AppKit 桥（无边 `NSPanel` 浮层、`NSHostingView`、全局事件监听）
- 依赖（SPM）：Sparkle（自动更新）、swift-markdown（聊天 Markdown 渲染）
- 平台：macOS 15.6+；只构建本机 arm64 产物
- 工程：`AgentIsland.xcodeproj` 用 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77）→ **源文件放进 `AgentIsland/<层>/` 即自动进 target**，资源（`.py`/`.js`/`.xcstrings`）自动进 Resources，通常不需要改 pbxproj
- 签名：ad-hoc（`codesign --force --deep --sign -`）。没有 Developer ID、不做公证 —— 这是既定取舍，不要再提议申请证书或改回 developer-id 导出流程
- 测试 target 是 `AgentIslandTests`（纯逻辑用例，挂在 scheme 的 Testables 上；没有 SwiftLint/SwiftFormat/CI 配置）：质量门禁是 `scripts/gate.sh`（编译 0 诊断 + 本地化守卫 0 错误 0 警告）+ 实机观察

## 命令

```bash
# 编译门禁：scripts/gate.sh 是唯一入口。判据 = BUILD SUCCEEDED + 编译诊断 0 条
# + 本地化守卫 0 错误 0 警告
./scripts/gate.sh                 # Release 编译（默认）
./scripts/gate.sh --debug         # Debug 编译
./scripts/gate.sh --with-tests    # 追加跑测试：xcodebuild test -only-testing:AgentIslandTests
# 脚本任一步不达标就 exit 非 0 —— 不要只看日志。派生数据与日志在 ${TMPDIR}/agent-island-gate，
# 不写用户的 DerivedData，也不改 build/ 与 releases/。

# 单独跑本地化守卫（gate.sh 的第一步：缺键、格式符不一致、绕过自研查表、未引用键）
python3 scripts/check-localization.py
python3 scripts/check-localization.py --strict

# 构建 + 安装到本机 /Applications（无 Developer ID 机器上的主路径）
./scripts/build-and-install.sh                 # 编译门禁 → 归档 → 安装 → 启动
./scripts/build-and-install.sh --no-launch     # 只安装
./scripts/build-and-install.sh --build-only    # 只产出 build/export/AgentIsland.app 与 releases/*.dmg
# 第一步就是 scripts/gate.sh --release（未过即中止），再归档、ad-hoc 重签、校验签名

# 需要 Apple 证书的路径（本机环境跑不通，仅作记录）
./scripts/build.sh               # developer-id 导出（需要证书）
./scripts/create-release.sh      # 编译门禁 → 公证 → DMG → Sparkle 签名 → GitHub Release → 推 gh-pages appcast
./scripts/generate-keys.sh       # Sparkle EdDSA 密钥（一次性；已有密钥时不要重跑）
```

## 目录结构

```
AgentIsland/
  App/          # 入口（AgentIslandApp @main）、AppDelegate（生命周期/单实例/偏好迁移/装集成/Sparkle）、ScreenObserver、WindowManager
  Core/         # 应用状态与版面：NotchViewModel（@Observable UI 状态）、NotchGeometry（纯几何）、NotchMenuLayout、Settings（UserDefaults）、Localization、各 Selector（语言/屏幕/声音/高度/Claude 目录）
  Models/       # AgentKind、SessionState、SessionPhase（状态机）、SessionEvent、ChatMessage、SubagentToolInfo、TmuxTarget
  Events/       # 全局鼠标事件监听（悬停/点击命中刘海）
  Services/
    Agents/     # Agent 接入面：AgentProvider 协议、AgentRegistry、各 Provider、集成安装/卸载、进程与记录扫描
                #   AgentHooks.swift 是「配置文件型 hook」的描述表（格式/路径/事件/回写协议），
                #   AgentConfigInstaller.swift + AgentConfigMerger.swift 按它写入各工具自己的配置
    Session/    # 记录解析：TranscriptSchema + 各 Agent schema、ConversationParser（JSONL 增量）、AgentFileWatcher、OpenCodeSessionStore（SQLite）、AgentSessionDiscovery
    State/      # SessionStore（actor，唯一状态入口）、FileSyncScheduler、ToolEventProcessor
    Hooks/      # HookSocketServer（/tmp/agent-island.sock）、HookInstaller
    Chat/       # ChatHistoryManager
    Tmux/       # 审批键序下发：ToolApprovalHandler、TmuxController/TargetFinder/Matcher
    Window/     # 聚焦终端窗口：WindowFinder/Focuser、YabaiController
    Update/     # Sparkle 更新 UI 做进刘海（NotchUserDriver）
  UI/
    Components/ # 角标/图标/设置行套件（SettingsKit）/形状/调色
    Views/      # NotchView（关闭态 + 展开态）、NotchMenuView/NotchMenuPages（设置面板）、ClaudeInstancesView（会话列表）、ChatView（对话）
    Window/     # NSPanel 宿主：NotchPanel、NotchWindowController、NotchViewController
  Resources/    # Localizable.xcstrings、三个 Agent 侧集成资源（.py/.js/.ts.txt）、entitlements
AgentIslandTests/ # 纯逻辑单测（target AgentIslandTests，scheme 的 Testables 里挂了它）
scripts/          # build.sh / build-and-install.sh / create-release.sh / gate.sh / generate-keys.sh / check-localization.py / make-appicon.py
```

## 架构

### 事件驱动的单一状态源

```
Agent 侧集成（Claude hook 脚本 / omp·pi 扩展 / opencode 插件）
  → Unix socket /tmp/agent-island.sock（每条连接一个 JSON 对象，snake_case 字段）
  → HookSocketServer（GCD DispatchSource）→ SessionEvent
  → SessionStore.process(_:)   ← actor，唯一的状态变更入口
  → sessionsPublisher（Combine）→ ChatHistoryManager / ClaudeInstancesView …
  → SwiftUI 重绘

未装集成的会话：AgentSessionDiscovery 定时扫记录目录（或库）→ 登记会话 + 触发增量读取
  → 状态由记录内容推断（SessionStore.applyTranscriptActivity）
```

- 所有会话状态变化都只经过 `SessionStore.process(_:)`；视图不直接改状态。
- 权限审批是请求/响应：`HookSocketServer` 收到需要响应的事件后保持连接，等刘海上的批准/拒绝，再由 `ToolApprovalHandler` 通过 tmux 把键序发给正确的 pane。`PermissionRequest` 不带 `tool_use_id`，靠 `PreToolUse` 的 `sessionId:toolName:tool_input` 缓存做关联。

### 新增一个 Agent 要动的地方（接入面）

1. `Models/AgentKind.swift` 加 case。`rawValue` **就是集成侧的 `--source`、也是 CodeIsland 的 source id**（两侧必须同一个字符串，否则事件会被算到别的 Agent 名下；且不能含冒号——`SessionKey` 按第一个冒号切分）。补 displayName / shortName / binaryName / approval / subagentToolNames / interactiveToolNames；`isClaudeFamily` 决定它是否复用 Claude 的 hook 契约与记录格式。
2. `Services/Agents/AgentHooks.swift` 的 `hookSpec` 补一行：写入格式、配置路径（可带 `CODEX_HOME` / `GROK_HOME` 这类根目录环境变量）、事件表、决定回写协议。**没有配置文件型 hook 的工具填 nil**（Claude 走 hook 脚本、omp/pi 走扩展、opencode 走插件、DSH 由外部插件直接写 socket）。
3. `Services/Agents/` 实现 `AgentProvider`（`paths()`、`transcriptFile`、`isTranscriptFile`、`sessionId(fromTranscriptFile:)`、`cwd(fromTranscriptFile:)`、`subagentTranscriptFiles`、`integrationStatus()`），**带可注入的 `home`**（用例要能指向临时目录），并在 `AgentRegistry.all` 注册（**home 必须过 `AgentProviderRoot.canonical`**，理由见已知坑）；同时补 `AgentProcessScanner.matches` 与 `AgentSessionScanner` 的发现源。
4. `Services/Session/` 加记录解析实现：Claude 系 fork 直接复用 `ClaudeFamilyTranscriptSchema`；其它格式自己实现 `AgentTranscriptSchema`（追加式 JSONL 继承 `JSONLTranscriptSchema`，整文档 JSON 则用「文件指纹 + 已消费条数」做增量），并在 `AgentTranscriptSchemaRegistry` 注册；有 token 字段的再接 `TranscriptUsageScanner`。
5. `Resources/agent-island-state.py` 的事件归一表补该工具的原生事件名（与 CodeIsland `EventNormalizer` 对齐；`scripts/verify-agent-hooks.sh` 是它的验证矩阵）。
6. `UI/`：`AgentPalette` 补品牌色、`AgentMarks.swift` 补标记形状（`AgentLogo` 的 `Glyph` 是穷举 switch，编译器会提醒）；本地化补产品名与短名的 en/zh-Hans 键。
7. 跑 `./scripts/gate.sh --with-tests`：`AgentIslandTests/AgentKindTests.swift` 是表完整性用例——漏填某一列、rawValue 重名、阻塞事件却不让回传决定，都会在那里红。

### 本地化（必须遵守的不变量）

- 界面文案一律 `LocalizationManager.t("…")`（`nonisolated` 静态入口供后台代码使用）；**键就是英文源文案**，`Localizable.xcstrings` 的 `sourceLanguage = en`，语言固定为 `en` / `zh-Hans`。
- 禁止 `Text("…")` 字面量、`NSLocalizedString`、`String(localized:)`、`localizedString(forKey:)`：它们由平台按 `Bundle.main` 解析，读不到运行时选定的 `.lproj`，会出现「切了语言没变」。
- 新增文案必须同时做两件事：写 `t("…")` 调用 + 在 catalog 里加键并补 `en`/`zh-Hans` 两侧；两侧格式符集合必须一致，复数变化的每一档都要有。
- 数字/日期/度量衡走环境 `\.locale`（根视图 `LocalizedRoot` 注入），不要手写格式。
- 以上规则已静态化在 `scripts/check-localization.py`：**改完文案必须跑它**（`scripts/gate.sh` 的第一步就是它，`build.sh` / `build-and-install.sh` 也都会先跑它）。

### 刘海窗口

- `WindowManager` + `NotchWindowController` 把 `NSPanel`（`NotchPanel`）贴在当前屏幕顶部；`NotchGeometry` 是纯几何（命中矩形 + 展开尺寸），`NotchViewModel` 持有 closed/open 状态、打开原因、内容类型（会话列表 / 聊天 / 设置）与动画。
- 有真实刘海的屏按 `deviceNotchRect` 定位；无刘海屏（外接显示器）改为与菜单栏等高，高度也可在设置里固定（`NotchHeightSelector`）。
- 关闭态只画左侧标记 + 右侧计数；**计数颜色与标记同源**（`headerAgent?.brandColor`），状态由标记动效与琥珀色审批指示表达 —— 不要用颜色编码状态。
- 悬停/点击靠 `EventMonitors` 的全局鼠标监听 + `NotchGeometry` 命中判定；`PassThroughHostingView` 保证非交互区域不吞事件。

### 集成安装面（AgentIsland 唯一会写入的 Agent 侧文件）

| Agent | 写入位置 |
|---|---|
| Claude Code | `~/.agent-island/hooks/agent-island-state.py` + `~/.claude/settings.json` 里的 hook 条目 |
| omp / pi | `<agent 目录>/extensions/agent-island-state.ts` |
| OpenCode | `~/.config/opencode/plugins/agent-island-state.js` |
| Codex | `$CODEX_HOME/hooks.json`（另在 `config.toml` 的 `[features]` 下设 `hooks = true`） |
| Gemini CLI | `~/.gemini/settings.json` 的 `hooks` 键 |
| Cursor | `~/.cursor/hooks.json` |
| Copilot | `~/.copilot/hooks/agent-island.json` |
| Qoder / Factory / CodeBuddy | `~/.qoder/settings.json` / `~/.factory/settings.json` / `~/.codebuddy/settings.json` 的 `hooks` 键 |
| Kimi Code CLI | `~/.kimi-code/config.toml`（不存在则回退 `~/.kimi/config.toml`）的 `[[hooks]]` 块 |
| Cline | `~/Documents/Cline/Hooks/<EventName>` 每事件一个可执行文件 |
| Grok CLI | `$GROK_HOME/hooks/agent-island.json` |
| Trae | `~/.trae/hooks.json` |
| Trae CLI | `~/.trae/traecli.yaml` 里的托管 YAML 块 |
| DeepSeek Harness | **不写**：事件由外部 dsh 插件直接写 socket |

除 Claude 之外的工具都引用**同一份**脚本（`~/.agent-island/hooks/agent-island-state.py`）：一份实现、一处升级。单个 Agent 卸载只摘自己的条目，脚本本身保留（别的工具还在用）。

停用某个 Agent 时对应集成必须删干净，包括改名前的旧脚本名 `claude-island-state.py`（`HookInstaller.legacyHookScriptNames`），否则旧脚本会继续往废弃 socket 发状态。

除集成文件外，应用还会**读** OpenCode 自己的库 `~/.local/share/opencode/opencode.db`（会话列表与用量统计都读它，走 `OpenCodeDatabase.openReadOnly`）。那个库是 WAL 模式，wal-index（`-shm`）不存在时纯只读连接连 prepare 都会失败，所以打开方式是「读写 + `PRAGMA query_only = 1`」：SQLite 因此会在它的目录里留下 `-shm` 与空的 `-wal`（与 OpenCode 自己运行时留下的相同），**数据本身绝不会被我们改**（`OpenCodeDatabaseTests` 钉住了这条）。

### 更新与发布

- Sparkle：`Info.plist` 的 `SUFeedURL` 指向 GitHub Pages（`gh-pages` 分支根目录的 `appcast.xml`），`SUPublicEDKey` 是本仓库自有 EdDSA 公钥；私钥在 `.sparkle-keys/`（gitignore，**绝不提交、也不要贴进日志或提交信息**）。`NotchUserDriver` 把更新提示做在刘海内。
- 发版前必须 bump `CURRENT_PROJECT_VERSION`（appcast 里的 `sparkle:version` 就是它）：build 号不变，已装用户收不到更新提示。
- 发布验收要独立复核：release 附件字节与本地 DMG 一致（`shasum`）、appcast 的 `length`/`edSignature` 与产物一致、`sign_update --verify` 通过。

### 各 Agent 接入的事实来源与证据等级

新接入的 13 个 Agent 里，本机装着的只有 Codex（`codex`）与 Qoder（`qodercli`），其余
（Gemini / Cursor / Copilot / Factory / CodeBuddy / Kimi / Cline / Grok / Trae / Trae CLI /
DSH）**没有本机样本**。所以这一块的证据分三档，动这些地方之前先认清自己手里是哪一档：

| 档位 | 含义 | 涉及 |
|---|---|---|
| 本机实测 | 用真机记录与配置逐字核对过字段 | Codex（`~/.codex/sessions/**` 真记录 + `hooks.json` + `config.toml` 的 `[features] hooks`）、Qoder（真记录，Claude 格式，项目目录编码与 Claude 一致）、CodeBuddy（真记录，外壳不同且编码少一个前导短横线） |
| 上游源码 | 逐条照 CodeIsland 的实现与其行号，但本机无法复跑 | 各工具的配置路径/格式/事件表、Cursor 与 Copilot 的记录字段、Kimi 两代索引、Cline 的 VSCode 存储、Grok 的 `$GROK_HOME` 布局、Trae/Trae CLI 的布局 |
| 合成载荷 | 只有矩阵脚本造的信封能证明 | 事件名归一与按工具回写的形状（`scripts/verify-agent-hooks.sh`，25 个 case / 283 条断言） |

**未验证清单**（装上真机后应优先复核，改这块前先看这里）：

1. Gemini：事件里的 `session_id` 是否等于记录首行的 `sessionId`。不等的话状态正常但聊天历史为空；`GeminiAgentProvider.transcriptFile` 已同时按文件名前缀与首行 `sessionId` 兜底，仍需真机确认。
2. Gemini / Kimi / Cline / Grok 的工具调用字段：本批**故意**不抽（没有可核对的字段名，猜错会把统计放大），因此它们在统计页上不出现。
3. Trae CLI 的 `permission_request` 回写形状（按 Claude 信封写，与上游一致但未真机验证）；Trae / Trae CLI 没有可解析记录，只有实时事件。
4. Copilot 的两代记录布局（`jb/<id>/partition-*.jsonl` 当前 + `session-state/<id>/events.jsonl` 旧版）：本机只见到前者。
5. DSH：记录是 zstd 压缩（系统无 zstd API，不解析），事件依赖外部 dsh 插件直接写 socket——本应用不装它的集成。

**首次启动的足迹**：新 Agent 默认启用，因此更新后第一次启动会为**每个配置目录存在的工具**写 hook 条目（本机实测 7 个），每个被改写的文件旁留 `<文件名>.agent-island-backup`，写入动作是 notice 级日志。关掉某个 Agent 只摘它的条目，共用脚本保留。

## 约束

- **注释一律中文**：新增文件、被改动代码的注释（含 `///` 文档注释与 `// MARK:` 标题）。文件头保留既有「文件路径 + 中文简述」注释块风格。
- 并发：跨隔离域使用的类型/协议/值类型显式 `nonisolated`（工程默认 `MainActor` 隔离，漏标会出隔离错误或整树告警）；共享可变状态用 actor 或 `@Observable`；UI 相关协议与视图代码留在主 actor。
- 日志用 `os.Logger`，subsystem 统一 `com.celestial.AgentIsland`，category 取组件名（`Session`/`Hooks`/`Integration`/`Discovery`/`OpenCode`/`Window`/`ProcessExecutor`…）。新代码不用 `print`（`AppDelegate` 里几处是遗留，别跟着写）。
- 资源命名：`.ts` 会被 Xcode 判成源码而不进 Resources，所以随包资源叫 `agent-island-pi-extension.ts.txt`，安装时再写成 `agent-island-state.ts`。
- 偏好域跟着 bundle id（`com.celestial.AgentIsland`）。改名/换 id 时必须保留并扩展 `AppSettings.migrateLegacyDefaultsIfNeeded()`、`HookInstaller.legacyHookScriptNames` 这类迁移入口 —— 它们是兼容层，不是待清理的残留。
- 版面常量集中在 `Core/NotchGeometry.swift` / `Core/NotchMenuLayout.swift` / `UI/Components/SettingsKit.swift` / `UI/Components/AppTheme.swift`（`AppPalette` 调色 + `AppRadius` 圆角），Agent 品牌色在 `UI/Components/AgentPalette.swift`，不要散落魔法数字；关闭态与展开态的尺寸是对齐像素调出来的，改动要有截图取证。

## 已知坑

- 本机 Xcode 在 `/Applications/Xcode.app` 且许可已接受，直接用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。只有 CommandLineTools 的机器上 `xcodebuild` 会报未接受许可，此时用 `swiftc -typecheck -swift-version 5 -default-isolation MainActor`（`-default-isolation MainActor` 必需，缺它会报一堆幻影隔离错误）兜底。
- 本机 OMP 配置开启了写文件格式化：用编辑工具直接改 Swift 文件会被整文件重排（4 空格 ↔ 2 空格），外科手术式改动请用 python 精确替换后核对 `git diff --stat`。
- 想验证刘海 UI 行为，可往 `/tmp/agent-island.sock` 灌一条合成事件（字段为 snake_case，如 `{"session_id":"x","cwd":"/tmp","event":"SessionStart","status":"running"}`）驱动真实运行中的应用，再截图取帧。
- 共享工作树里常有多会话并行：易冲突文件是 `Localizable.xcstrings`、`UI/Views/NotchMenuPages.swift`、`README*.md`。
- 配置文件型 hook 的条目里，除 Claude 系（stdin 自带 `hook_event_name`）外都要带 `--event <原生事件名>`：Gemini / Cursor / Copilot 的 stdin 不带事件名，漏掉这个参数事件名会退化成工具名、相位全错。Trae CLI 是例外——它的托管项是「单一命令 + matchers 列出全部事件」，按事件分命令反而写不进去。
- Codex 只在 `$CODEX_HOME/config.toml` 的 `[features] hooks = true` 时才触发 hook（安装器会补这一行），并且要用户在 Codex 里跑一次 `/hooks` 审核信任本应用的 hook；没审核时 Codex **静默不跑**，看起来就像「没支持 Codex」。
- Kimi 的 `hooks` 在 TOML 里是 `[[hooks]]` 数组表，与旧的标量 `hooks = …` 互斥：安装时把标量行注释掉、卸载时再放回去（不能删——那是用户的内容）。
- 单个 Agent 卸载**不要**删 `~/.agent-island/hooks/agent-island-state.py`：它是所有配置文件型 Agent 共用的脚本，删掉会让其余工具的配置指向不存在的文件。
- **路径归一不是一个可选优化**：`FileManager` 的目录遍历返回的是 `realpath` 展开后的路径（macOS 下 `/var/…` → `/private/var/…`），而 `URL.resolvingSymlinksInPath()` / `standardizedFileURL` **不会**展开 `/var`、`/tmp`、`/etc` 这几个系统软链。provider 里 `hasPrefix(自己的根)` 的判定因此会与遍历结果对不上，记录被静默跳过（表现：工具在跑，面板里一个会话都没有）。统一走 `AgentProviderRoot.canonical`（POSIX `realpath`），用例夹具建目录后也要过它一次。

<delegation_rules>
何时委托子代理 vs 直接处理：

- 新增 Agent、改事件流/状态机、跨层重构 -> 先 planner 出文件级方案，再 executor 实现
- 单文件 UI 调整、文案、设置项、README -> 直接处理
- 编译失败、运行期崩溃、socket/解析异常 -> troubleshooter
- 实现完成后的独立审查 -> code-reviewer（审查者不参与编写，保持视角分离）
- 探索陌生子系统（记录格式、socket 协议、窗口行为）-> scout 只读侦察，再动手
</delegation_rules>

<model_routing>
- haiku / sonic：找文件、改配置、机械替换
- sonnet：常规 SwiftUI 视图、Provider/schema 实现、脚本改动、代码审查
- opus：并发与隔离设计、事件流/状态机改动、跨 Agent 抽象、发版链路
</model_routing>

<verification>
声称完成前必须确认：

- 编译改动 -> `./scripts/gate.sh`（唯一入口）：BUILD SUCCEEDED + 编译诊断 0 条 + 本地化守卫 0 错误 0 警告；脚本不达标自己就 exit 非 0，只看到 BUILD SUCCEEDED 不算过
- 纯逻辑改动 -> `./scripts/gate.sh --with-tests`（跑的是 `xcodebuild test -only-testing:AgentIslandTests`）
- 文案/本地化改动 -> `python3 scripts/check-localization.py --strict`，0 错误 0 警告（gate.sh 的第一步就是它）
- 刘海可见行为（关闭态形态、动效、计数、面板高度）-> 装到 /Applications 上实机观察 + 截图取证（没有测试 target，纯逻辑覆盖不到）
- 集成安装/卸载改动 -> 确认 Agent 侧文件确实写入/删除，且未破坏用户既有配置（`~/.claude/settings.json` 等）
- 发布 -> build 号已 bump、release 附件与本地产物字节一致、appcast 签名校验通过
- 没跑过对应命令前，不得声称「应该能编译 / 应该没问题」
</verification>

<execution_protocols>
- 范围不明确 -> 先读该层现有实现（`Services/`、`UI/`）再给方案
- 2 个以上互不依赖的任务 -> 并行 subagent；共享文件（catalog、`NotchMenuPages.swift`）由单一写者独占
- 工作树常被多个会话同时修改：提交只用显式 pathspec（`git commit -- <文件>`），不要 `git add -A` / `git add .`，不要把别人未提交的改动卷进自己的提交
- 耗时的构建/发布脚本 -> 后台跑并落日志文件，再从日志取判据
- 结束前确认：门禁 0 诊断、守卫通过、实机证据到手
</execution_protocols>

## 行为准则

1. **先想再写**：不臆测；有歧义先读代码或提问；暴露权衡，必要时反驳。
2. **简洁优先**：用最少的代码解决问题，不做投机性抽象、不加未被要求的开关。
3. **外科手术式改动**：只动与任务相关的代码；触碰到的代码按本文件规范写，不复制坏模式；自己造成的孤儿（未用变量/导入）要清掉，别人的死代码只提出不动手。
4. **目标驱动**：「让它能编译」不算成功标准 —— 写成可验证判据（门禁 0 诊断、守卫通过、截图里看到什么），然后循环到通过。
5. **并行提速**：可拆即拆，但子任务必须有清晰的文件边界；并行结束后统一跑一次门禁。
6. **及时提交**：每个有意义的单元就 commit；提交前检查只包含自己的文件；完成后派独立审查者复核，循环到无严重问题。
7. **交付前多维度审查**：功能完整性、代码质量、安全（socket/权限/集成写文件）、兼容与回归（改名遗留、偏好迁移）。任一维度有缺陷即未完成。
8. **消融验证**：「说得通」不等于「有必要」——怀疑某个开关/参数有用时，删掉重跑对比，用证据决定去留。
9. **独立判断先行**：派发并行 subagent 前自己先形成判断；对齐时以证据为准，不因结论来自某个 Agent 或听起来合理就放行。