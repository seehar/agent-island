//
//  AgentConfigInstaller.swift
//  AgentIsland
//
//  「配置文件型」Agent 的安装 / 卸载 / 状态查询：按 `AgentHooks.swift` 的
//  `AgentKind.hookSpec` 把一条指向 `~/.agent-island/hooks/agent-island-state.py` 的命令
//  写进该工具自己的配置文件。
//
//  为什么集中在一处：新增一个工具应当是 `AgentHooks.swift` 里的一行数据（事件表 + 格式），
//  而不是散落各处的分支；这里只按 `AgentHookFormat` 分派写入器，工具差异全部来自那张表。
//  claude / omp / pi / opencode / DSH 的集成不走配置文件（脚本、扩展、插件、外部插件），
//  它们的 `hookSpec` 为 nil，本类型一律不动。
//
//  安全口径（与 `HookInstaller` / `HookSettingsMerger` 同款）：
//    - 读不懂的 JSON 放弃写入（返回 false）：宁可这次装不上，也不清空用户的配置；
//    - 写前把上一版留成 `<文件名>.agent-island-backup`；
//    - 原子替换；内容没有变化就一个字节都不写（不刷新时间戳，重复安装字节相同）；
//    - 卸载只删自己的条目，别人的条目与其它键都留着；
//    - 但「原本不存在、由我们创建的配置文件」在摘完我们的条目后已无内容（只剩我们种下的
//      `version: 1`、或空白 / 空容器键）时整份删掉 —— 安装与卸载一一对应，不给用户留下
//      我们造出来的空壳文件。判据是**备份文件是否存在**（`write` 只为原本已存在的文件落
//      备份），不是推测。
//
//  两种写入口径（别混）：
//    - JSON 事件表（claude / nested / flat / traeIDE / copilot）是**整体重写**：
//      落盘用 `.prettyPrinted + .sortedKeys`，因此键序与空白会变（内容不变）；
//    - kimi / traecli / cline 是**行手术**：注释、键序、行尾风格与尾部空白都原样保留，
//      因此「卸载后逐字节还原」对这三种成立。
//
//  存在性闸门：`requiresExistingRoot` 为真时，该工具自己的目录不存在就**跳过**（返回 true）
//  —— 用户没装这个工具，凭空替他造一个 `~/.gemini/` 是越界。
//
//  用户指定目录（「智能体」页的目录选择器，见 `AgentRootOverride.userOverride`）：每个 Agent
//  的配置根都可以被用户改到别处。优先级与环境变量的口径**逐字一致**：
//  **环境变量 > 用户指定目录 > 自动检测**。指定目录替换的是**该工具自己的根**
//  （`~/.gemini`、`$CODEX_HOME`、`~/Documents/Cline`…），因此带 `rootEnvVar` 的工具与 kimi
//  的 `configPath`（`hooks.json` / `config.toml`）原样使用，其余的要摘掉根那一层
//  （`.gemini/settings.json` → `settings.json`，`Documents/Cline/Hooks` → `Hooks`）。
//  存在性闸门的判据也换成该目录本身：用户指到一个不存在的目录 ⇒ 那个根上没有这个工具，
//  跳过而不是凭空造目录。
//
//  没有闸门降级：配置文件型 Agent 与 Claude 一致 —— 脚本等刘海决定，应用不在（socket
//  连不上）时脚本不输出任何内容、由工具自己弹原生审批。因此这里**不读**
//  `AppSettings.isApprovalGateEnabled`，也没有「只上报版」配置。
//

import Foundation
import os.log

nonisolated enum AgentConfigInstaller {
    private static let logger = Logger(subsystem: "com.celestial.AgentIsland", category: "Integration")

    /// 备份后缀：`<原文件名>.agent-island-backup`（与 `HookInstaller` 同款命名）。
    private static let backupExtension = "agent-island-backup"

    /// Copilot / Trae IDE 的 schema 版本号：我们只在用户自己没设过时种下它，卸载时又按
    /// 「顶层只剩这一个我们种的键」判空 —— 种什么、判什么必须是同一个值，因此放在一处。
    private static let seededVersionKey = "version"
    private static let seededVersionValue = 1

    // MARK: - 安装

    /// 安装该 Agent 的 hook 配置。
    ///
    /// 返回 false 只代表「本该能装好却没装成」（配置文件读不懂、写不进去）；
    /// 「这个工具没装」（存在性闸门）与「这个 Agent 不走配置文件」都算成功（跳过）。
    @discardableResult
    static func install(
        _ kind: AgentKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let spec = kind.hookSpec else { return false }
        guard let location = location(for: kind, spec: spec, home: home) else { return true }
        // 解释器只探一次：`which` 会真起一个进程，而事件表最多有 14 个事件
        let interpreter = HookInstaller.detectPython()

        let installed: Bool
        switch spec.format {
        case .kimi:
            installed = writeKimiTable(
                kind: kind, spec: spec, location: location, home: home, interpreter: interpreter)
        case .traecli:
            installed = writeTraecliTable(
                kind: kind, spec: spec, location: location, home: home, interpreter: interpreter)
        case .cline:
            installed = writeClineFiles(
                kind: kind, spec: spec, location: location, home: home, interpreter: interpreter)
        case .claude, .nested, .flat, .traeIDE, .copilot:
            installed = writeEventTable(
                kind: kind, spec: spec, location: location, home: home, interpreter: interpreter)
        }
        guard installed else { return false }
        return applyPrerequisites(spec, location: location)
    }

    // MARK: - 卸载

    /// 卸载该 Agent 的 hook 配置：只摘自己的条目，别人的内容一个字节都不动。
    ///
    /// 不动 hook 脚本本体：它由 `installHookScript` 统一维护（多个 Agent 共用一份），
    /// 单卸载一个 Agent 就把脚本删掉会让其余 Agent 的配置指向不存在的文件。
    static func uninstall(
        _ kind: AgentKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard let spec = kind.hookSpec else { return }
        guard let location = location(for: kind, spec: spec, home: home) else { return }

        switch spec.format {
        case .kimi:
            removeTextHooks(at: location.configFile) {
                AgentConfigMerger.removingKimiHooks(from: $0)
            }
        case .traecli:
            removeTextHooks(at: location.configFile) {
                AgentConfigMerger.removingTraecliHooks(from: $0)
            }
        case .cline:
            removeClineFiles(spec: spec, location: location)
        case .claude, .nested, .flat, .traeIDE, .copilot:
            removeEventTable(spec: spec, location: location)
        }
    }

    // MARK: - 状态

    /// 该 Agent 的全部事件是否都已指向本应用脚本。
    static func isInstalled(
        _ kind: AgentKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let spec = kind.hookSpec else { return false }
        guard let location = location(for: kind, spec: spec, home: home) else { return false }
        let events = spec.events.map(\.name)

        switch spec.format {
        case .cline:
            // Cline 没有配置结构：判据是每个事件文件都存在且是本应用的脚本
            return spec.events.allSatisfy { event in
                let file = location.configFile.appendingPathComponent(event.name)
                guard let text = textContents(of: file) else { return false }
                return HookInstaller.isOwnHookCommand(text)
            }
        case .kimi:
            guard case let .text(contents) = readText(at: location.configFile) else { return false }
            return AgentConfigMerger.containsAllKimiHooks(events, in: contents)
        case .traecli:
            guard case let .text(contents) = readText(at: location.configFile) else { return false }
            return AgentConfigMerger.containsTraecliHook(in: contents)
        case .claude, .nested, .flat, .traeIDE, .copilot:
            guard case let .dictionary(root) = loadEventTable(at: location.configFile) else {
                return false
            }
            return AgentConfigMerger.containsAllOwnEvents(
                events, in: root, configKey: spec.configKey)
        }
    }

    /// 集成真正落在哪些文件里（该 Agent 自己的文件在前，共用的 hook 脚本在后）；没装成就返回空。
    ///
    /// 两条口径：
    ///   - **逐个文件复核内容**而不是只看路径存在：配置文件是用户与我们共用的，只有真的
    ///     写着我们的脚本才算「我们写过它」；
    ///   - 该 Agent 自己的文件排在前面：设置面板显示的是 `installedFiles.first`
    ///     （`AgentSettingsSection`），而 hook 脚本对 11 个工具是同一份 —— 排在前面会让
    ///     每一行的副标题一模一样，回答不了「这个工具写在哪」。
    ///
    /// 没装成就返回空（而不是返回那份共享脚本）：那会让「未安装」的行上多出一段指向
    /// 别人装的脚本的路径。
    static func installedFiles(
        _ kind: AgentKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        guard let spec = kind.hookSpec else { return [] }
        guard let location = location(for: kind, spec: spec, home: home) else { return [] }

        var files: [URL] = []
        switch spec.format {
        case .cline:
            files.append(contentsOf: spec.events.compactMap { event in
                let file = location.configFile.appendingPathComponent(event.name)
                guard let text = textContents(of: file),
                      HookInstaller.isOwnHookCommand(text) else { return nil }
                return file
            })
        case .kimi:
            if case let .text(contents) = readText(at: location.configFile),
               AgentConfigMerger.containsAnyKimiHook(in: contents) {
                files.append(location.configFile)
            }
        case .traecli:
            if case let .text(contents) = readText(at: location.configFile),
               AgentConfigMerger.containsTraecliHook(in: contents) {
                files.append(location.configFile)
            }
        case .claude, .nested, .flat, .traeIDE, .copilot:
            if case let .dictionary(root) = loadEventTable(at: location.configFile),
               AgentConfigMerger.containsAnyOwnEntry(in: root, configKey: spec.configKey) {
                files.append(location.configFile)
            }
        }
        guard !files.isEmpty else { return [] }

        let script = AgentHookScript.fileURL(home: home)
        if FileManager.default.fileExists(atPath: script.path) { files.append(script) }
        return files
    }

    // MARK: - hook 脚本

    /// 把随包脚本装到 `AgentHookScript` 的唯一落点；已是最新内容则不写。
    ///
    /// 与 `HookInstaller` 同一套纪律：**脚本先落地**。脚本没落地，各工具配置里就会多出一条
    /// 注定失败的命令 —— 每个事件都跑一次、每次都失败。
    @discardableResult
    static func installHookScript(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let bundled = Bundle.main.url(forResource: "agent-island-state", withExtension: "py")
        else {
            logger.error("缺少内置的 hook 脚本资源，跳过配置文件型 Agent 的集成安装")
            return false
        }
        guard let script = try? Data(contentsOf: bundled) else {
            logger.error("内置 hook 脚本读不出来：\(bundled.path, privacy: .public)")
            return false
        }

        let target = AgentHookScript.fileURL(home: home)
        if let existing = try? Data(contentsOf: target), existing == script {
            // 内容已经是最新的：只补权限位，不重写文件（不刷新时间戳）
            setExecutable(target)
            return true
        }
        guard ensureDirectory(AgentHookScript.directory(home: home)) else { return false }
        do {
            try script.write(to: target, options: .atomic)
        } catch {
            logger.error("写入 hook 脚本失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
        setExecutable(target)
        logger.notice("已安装 hook 脚本：\(target.path, privacy: .public)")
        return true
    }

    // MARK: - 写入口（按格式）

    /// JSON 事件表（claude / nested / flat / traeIDE / copilot）：读-改-写。
    private static func writeEventTable(
        kind: AgentKind,
        spec: AgentHookSpec,
        location: Location,
        home: URL,
        interpreter: String
    ) -> Bool {
        let load = loadEventTable(at: location.configFile)
        if let refusal = load.refusalReason {
            logger.error("\(kind.rawValue, privacy: .public) 的配置不可安全写入（\(refusal, privacy: .public)），本次跳过：\(location.configFile.path, privacy: .public)")
            return false
        }

        let entries: [(event: String, entry: [String: Any])] = spec.events.compactMap { event in
            let command = command(
                kind: kind, format: spec.format, event: event.name, home: home,
                interpreter: interpreter)
            guard let entry = AgentConfigMerger.eventTableEntry(
                format: spec.format, command: command, timeout: event.timeout
            ) else { return nil }
            return (event.name, entry)
        }

        var root = AgentConfigMerger.strippingOwnEntries(
            from: load.settings, configKey: spec.configKey)
        root = AgentConfigMerger.appendingOwnEntries(
            entries, to: root, configKey: spec.configKey)
        // Copilot / Trae IDE 的 schema 版本号：用户自己设过就别动（他可能是为工具升级预留的）
        if spec.format == .copilot || spec.format == .traeIDE,
           root[seededVersionKey] == nil {
            root[seededVersionKey] = seededVersionValue
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else {
            logger.error("序列化 \(kind.rawValue, privacy: .public) 的配置失败，本次跳过")
            return false
        }
        return write(data, to: location.configFile)
    }

    /// Kimi：往 `config.toml` 追加 `[[hooks]]` 数组表。
    private static func writeKimiTable(
        kind: AgentKind,
        spec: AgentHookSpec,
        location: Location,
        home: URL,
        interpreter: String
    ) -> Bool {
        guard let existing = existingText(at: location.configFile, kind: kind) else { return false }

        let hooks: [(event: String, command: String, timeout: Int)] = spec.events.map { event in
            (event.name,
             command(
                kind: kind, format: spec.format, event: event.name, home: home,
                interpreter: interpreter),
             event.timeout)
        }
        let merged = AgentConfigMerger.mergingKimiHooks(into: existing, hooks: hooks)
        return write(Data(merged.utf8), to: location.configFile)
    }

    /// TraeCli：`~/.trae/traecli.yaml` 里的托管列表项（行手术，注释与键序都留着）。
    private static func writeTraecliTable(
        kind: AgentKind,
        spec: AgentHookSpec,
        location: Location,
        home: URL,
        interpreter: String
    ) -> Bool {
        guard let existing = existingText(at: location.configFile, kind: kind) else { return false }

        // TraeCli 的托管项是**单一命令 + matchers 列全部事件**，因此不能按事件分命令，
        // 这里不传 `--event`（形状见 AgentHooks.swift 的 `.traecli` 与 CodeIsland
        // `renderManagedTraecliHooksText`，ConfigInstaller.swift:1665-1680）。
        let outcome = AgentConfigMerger.mergingTraecliHooks(
            into: existing,
            command: command(
                kind: kind, format: spec.format, event: nil, home: home, interpreter: interpreter),
            timeout: spec.events.map(\.timeout).max() ?? 5,
            events: spec.events.map(\.name)
        )
        switch outcome {
        case .merged(let text):
            return write(Data(text.utf8), to: location.configFile)
        case .refused(let reason):
            // 行手术保不住这份文件：宁可这次不装，也不写出解析不了的 YAML
            logger.error("traecli.yaml 无法安全行手术（\(reason, privacy: .public)），本次跳过：\(location.configFile.path, privacy: .public)")
            return false
        }
    }

    /// Cline：一个事件一个可执行文件（`~/Documents/Cline/Hooks/<Event>`）。
    private static func writeClineFiles(
        kind: AgentKind,
        spec: AgentHookSpec,
        location: Location,
        home: URL,
        interpreter: String
    ) -> Bool {
        guard ensureDirectory(location.configFile) else { return false }

        var ok = true
        for event in spec.events {
            let file = location.configFile.appendingPathComponent(event.name)
            // 用户自己写的同名 hook 一律不碰：顶掉它，卸载时也会因为「内容里没有我们的脚本」
            // 认不出那是他的，他的 hook 就只剩一个 Cline 不会执行的备份文件。
            if let existing = textContents(of: file), !HookInstaller.isOwnHookCommand(existing) {
                logger.error("Cline 的 \(event.name, privacy: .public) 事件文件已被用户占用，跳过该事件：\(file.path, privacy: .public)")
                ok = false
                continue
            }
            let script = AgentConfigMerger.clineHookScript(
                event: event.name,
                command: command(
                    kind: kind, format: spec.format, event: event.name, home: home,
                    interpreter: interpreter, shellQuoted: true)
            )
            // 事件文件不落备份：备份躺在 hooks 目录里是噪声，还可能被 Cline 当成 hook 扫到
            guard write(Data(script.utf8), to: file, backup: false) else {
                ok = false
                continue
            }
            // Cline 直接执行这个文件：内容没变时也要补权限位（用户可能改过）
            setExecutable(file)
        }
        return ok
    }

    // MARK: - 前置开关

    /// 安装需要一并打开的前置开关（目前只有 Codex 的 `[features] hooks = true`）。
    private static func applyPrerequisites(_ spec: AgentHookSpec, location: Location) -> Bool {
        var ok = true
        for prerequisite in spec.prerequisites {
            switch prerequisite {
            case .codexHooksFeature:
                ok = enableCodexHooks(location: location) && ok
            }
        }
        return ok
    }

    /// 打开 `<codexRoot>/config.toml` 的 `[features] hooks`；已经是 true 就不动文件。
    private static func enableCodexHooks(location: Location) -> Bool {
        let configFile = location.base.appendingPathComponent("config.toml")
        guard let existing = existingText(at: configFile, kind: .codex) else { return false }
        guard let updated = AgentConfigMerger.enablingCodexHooks(in: existing) else { return true }
        return write(Data(updated.utf8), to: configFile)
    }

    // MARK: - 命令字符串

    /// 写进配置的命令：`<python> <hook 脚本> --source <rawValue>`，需要时再补 `--event`。
    ///
    /// `--event` 是给「载荷里读不到原生事件名」的工具兜底：hook 脚本**优先读 stdin 的
    /// `hook_event_name`**，`--event` 只是第二顺位，所以 stdin 自带事件名的工具
    /// （claude 家族 / codex / grok / kimi）补上它是冗余兜底、并不改变解析结果；
    /// 而少数工具的部分事件不带事件名（gemini 的 `BeforeTool` 这类），缺了就会丢事件。
    /// 因此只有 `.claude` 不加（stdin 必然带 `hook_event_name`），其余格式一律加上。
    ///
    /// - Parameter shellQuoted: Cline 的事件文件是 shell 脚本，路径要按 shell 规则引用
    ///   （用户主目录可能含空格）；各 JSON / YAML 配置里原样写路径即可。
    private static func command(
        kind: AgentKind,
        format: AgentHookFormat,
        event: String?,
        home: URL,
        interpreter: String,
        shellQuoted: Bool = false
    ) -> String {
        let script = AgentHookScript.shellPath(home: home)
        var parts = shellQuoted
            ? [AgentConfigMerger.shellSingleQuoted(interpreter),
               AgentConfigMerger.shellSingleQuoted(script)]
            : ["\(interpreter) \(script)"]
        parts.append("--source \(kind.rawValue)")
        if let event, needsEventArgument(format) {
            parts.append("--event \(event)")
        }
        return parts.joined(separator: " ")
    }

    /// 该格式是否需要 `--event`：只有 `.claude` 不用（它的 stdin 自带 `hook_event_name`）。
    ///
    /// 事实来源：CodeIsland `installExternalHooks` 的 nested 分支只给 gemini 补 `--event`
    /// （ConfigInstaller.swift:1550-1552）。我们给 `.claude` 之外的格式一律补上：
    /// 补了不会改变解析结果（stdin 优先），漏了在 gemini 这类事件上会丢事件。
    /// `.traecli` 是唯一例外 —— 它的托管项只有一份命令，见 `writeTraecliTable`。
    private static func needsEventArgument(_ format: AgentHookFormat) -> Bool {
        format != .claude
    }

    // MARK: - 落点

    /// 落点解析的结果。
    private struct Location {
        /// `configPath` 的基准目录（环境变量根目录、用户指定目录、kimi 的择优根目录，
        /// 或 `home`）。
        let base: URL
        /// 配置文件（`.cline` 这里是事件文件所在的目录）。
        let configFile: URL
    }

    /// 解析落点；返回 nil 表示「这个工具没装」—— 此时一个字节都不写。
    ///
    /// 闸门判据是**该工具自己的目录**（`~/.gemini`、`$CODEX_HOME`…）而不是 `home`：
    /// 拿 `home` 判断等于永远为真，会替没装该工具的用户凭空造出 `~/.gemini/`。
    /// 口径与 CodeIsland `installExternalHooks` 的存在性闸门一致
    /// （ConfigInstaller.swift:1463-1516：各工具分支 + 兜底的 `cli.dirPath` 判断）。
    /// 用户指定目录生效时判据就是该目录本身（见 `configBase`）。
    private static func location(
        for kind: AgentKind,
        spec: AgentHookSpec,
        home: URL
    ) -> Location? {
        let base = configBase(for: kind, spec: spec, home: home)
        let configFile = base.url.appendingPathComponent(
            base.fromUserOverride
                ? configPath(for: kind, spec: spec, onUserOverrideRoot: true)
                : spec.configPath
        )

        if spec.requiresExistingRoot {
            // 闸门判据：用户指定目录（就是它本身）> 显式给的 gatePath > 环境变量 / 择优根目录
            // > 配置文件所在的最上层目录
            let gate: URL
            if base.fromUserOverride {
                gate = base.url
            } else if let explicit = spec.gatePath {
                gate = home.appendingPathComponent(explicit)
            } else if spec.rootEnvVar != nil || kind == .kimi {
                gate = base.url
            } else {
                gate = home.appendingPathComponent(toolRootName(relativeToHomeFor: spec))
            }
            guard FileManager.default.fileExists(atPath: gate.path) else { return nil }
        }
        return Location(base: base.url, configFile: configFile)
    }

    /// `configPath` 的基准目录，以及它是不是来自用户指定目录。
    ///
    /// 优先级与 Provider 的读取链路**逐字一致**：环境变量 > 用户指定目录 > 自动检测。
    /// 同一个 Agent 的「写配置」与「推导记录路径」解析成不同目录时，设置行会一边说
    /// 「工具没装」、一边被装进另一个目录。
    ///
    /// `rootEnvVar`（`CODEX_HOME` / `GROK_HOME`）没设时退到 `~/.<rawValue>`：这两个工具的
    /// 默认根目录就是 `~/.codex` / `~/.grok`（CodeIsland `codexHome()` / `grokHome()`，
    /// ConfigInstaller.swift:185-193、244-251）。直接拿 `home` 会把 `hooks.json` 写到用户
    /// 主目录根上，而它们根本不会读那个文件。
    ///
    /// 解析复用 Provider 的 `AgentRootOverride.resolve`（`~` / `~/x` 展开、空白按未设处理）：
    /// 同一个环境变量必须在「写配置」与「推导记录路径」两侧解析成同一个目录，否则设置行会
    /// 一边说「工具没装」一边被装进另一个目录。
    private static func configBase(
        for kind: AgentKind,
        spec: AgentHookSpec,
        home: URL
    ) -> (url: URL, fromUserOverride: Bool) {
        // 「自动检测」下的基准：带 `rootEnvVar` 的工具是 `~/.<rawValue>`，其余以 `home`
        // 为基准（它们的 `configPath` 自带工具目录名，如 `.gemini/settings.json`）。
        let defaultBase =
            spec.rootEnvVar == nil
            ? home
            : AgentProviderRoot.canonical(home.appendingPathComponent("." + kind.rawValue))

        if let name = spec.rootEnvVar, let value = nonEmptyEnvironmentValue(name) {
            return (AgentRootOverride.resolve(value, fallback: defaultBase, home: home), false)
        }
        // 环境变量没设（或空白）时，用户指定目录压过自动检测。
        if let override = AgentRootOverride.userOverride(for: kind) { return (override, true) }
        if kind == .kimi { return (kimiRoot(home: home), false) }
        return (defaultBase, false)
    }

    /// 环境变量的值；空白视作未设置。
    private static func nonEmptyEnvironmentValue(_ name: String) -> String? {
        let raw =
            Foundation.ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// 用户指定目录下 `configPath` 的写法。
    ///
    /// `configPath` 大多相对**用户主目录**写（`.gemini/settings.json`），而用户指定目录替换的
    /// 正是其中的**工具自己的目录**（`~/.gemini`）；不摘掉这一层就会写到
    /// `<指定目录>/.gemini/settings.json`。带 `rootEnvVar` 的工具（`$CODEX_HOME` 下的
    /// `hooks.json` / `hooks/agent-island.json`）与 kimi（根下的 `config.toml`）本来就是相对自己的
    /// 根写的，原样使用。Cline 的根比 `configPath` 的第一段还深一层
    /// （`Documents/Cline` ← `Documents/Cline/Hooks`），判据同样取 `gatePath`。
    private static func configPath(
        for kind: AgentKind,
        spec: AgentHookSpec,
        onUserOverrideRoot: Bool
    ) -> String {
        guard onUserOverrideRoot else { return spec.configPath }
        guard spec.rootEnvVar == nil, kind != .kimi else { return spec.configPath }
        let toolRoot = toolRootName(relativeToHomeFor: spec)
        guard !toolRoot.isEmpty, spec.configPath.hasPrefix(toolRoot + "/") else {
            return spec.configPath
        }
        return String(spec.configPath.dropFirst(toolRoot.count + 1))
    }

    /// 该工具自己的目录（相对用户主目录）：显式 `gatePath` 优先，否则 `configPath` 的最上层。
    private static func toolRootName(relativeToHomeFor spec: AgentHookSpec) -> String {
        spec.gatePath ?? firstComponent(of: spec.configPath)
    }

    /// kimi 的配置根目录：与读记录那一侧共用同一个择优函数，避免「写在这、读在那」。
    private static func kimiRoot(home: URL) -> URL {
        KimiAgentProvider.preferredRoot(home: home)
    }

    /// `configPath` 的最上层目录名（存在性闸门的判据：`~/.gemini` 这类工具自己的目录）。
    private static func firstComponent(of path: String) -> String {
        path.split(separator: "/").first.map(String.init) ?? ""
    }

    // MARK: - 落盘

    /// 原子写入：内容没变化就一个字节都不写；`backup` 为真时先把上一版留成
    /// `<文件名>.agent-island-backup`（Cline 的事件文件不落备份：那个目录会被 Cline 当 hook 扫）。
    ///
    /// **原本不存在的文件不落备份**，因此「没有备份」等价于「这个文件是我们创建的」——
    /// 卸载的对称性判据（`wasCreatedByUs`）就是靠这条，不另存状态。
    @discardableResult
    private static func write(_ data: Data, to file: URL, backup: Bool = true) -> Bool {
        let original = try? Data(contentsOf: file)
        if original == data { return true }
        guard ensureDirectory(file.deletingLastPathComponent()) else { return false }

        if backup, let original {
            let backup = file.appendingPathExtension(backupExtension)
            do {
                try original.write(to: backup, options: .atomic)
            } catch {
                // 备份失败不阻断安装（配置本身还能写），但要在日志里留痕
                logger.error("备份失败（继续写入）：\(backup.path, privacy: .public)")
            }
        }

        do {
            try data.write(to: file, options: .atomic)
            // 首次启动会往**每个检测到的工具**的配置里写条目，所以「改了哪个文件、
            // 备份在哪」必须在日志里看得见（notice 级：debug 不会被持久化）。
            let backupFile = backupURL(for: file)
            let origin = FileManager.default.fileExists(atPath: backupFile.path)
                ? "备份 \(backupFile.path)" : "无备份（文件原本不存在）"
            logger.notice("已写入 \(file.path, privacy: .public)（\(origin, privacy: .public)）")
            return true
        } catch {
            logger.error("写入失败：\(file.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 行手术格式（kimi / traecli）的卸载：读文本 → 摘掉托管块 → 变了才写回。
    ///
    /// 卸载对称性：这个文件原本不存在（无备份）、摘完后只剩空白或我们建出来的空容器键
    /// （traecli 的 `hooks:`）⇒ 整份删掉；用户自己写过任何键、注释或列表项就保留。
    private static func removeTextHooks(at file: URL, _ transform: (String) -> String) {
        guard case let .text(original) = readText(at: file) else { return }
        let updated = transform(original)
        guard updated != original else { return }
        if wasCreatedByUs(file), isEffectivelyEmpty(updated) {
            removeCreatedFile(file, reason: "卸载后已无内容")
            return
        }
        write(Data(updated.utf8), to: file)
    }

    /// 这个文件是不是本应用凭空创建的：判据是**没有**对应的 `<文件名>.agent-island-backup`
    /// —— `write` 只为「原本已存在」的文件落备份，所以「无备份」等价于「我们创建的」，
    /// 不需要另存一份状态（重启、重装后依然成立）。
    private static func wasCreatedByUs(_ file: URL) -> Bool {
        !FileManager.default.fileExists(atPath: backupURL(for: file).path)
    }

    /// 摘掉我们的条目后，顶层是否只剩下我们为写入而种下的键（目前只有 Copilot / Trae IDE 的
    /// `seededVersionKey`）—— 「这个文件卸完已无内容」的判据；用户加过别的键就算有内容。
    private static func holdsOnlySeededKeys(_ root: [String: Any]) -> Bool {
        if root.isEmpty { return true }
        return root.count == 1
            && root[seededVersionKey] as? Int == seededVersionValue
    }

    /// 行手术格式卸载后是否已无内容：只剩空白行，或只剩我们建出来的空容器键（`hooks:`）。
    private static func isEffectivelyEmpty(_ text: String) -> Bool {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .allSatisfy { $0.isEmpty || $0 == "hooks:" }
    }

    /// 删掉我们创建的配置文件；删不掉只记日志（卸载不该因此中断）。
    private static func removeCreatedFile(_ file: URL, reason: String) {
        do {
            try FileManager.default.removeItem(at: file)
            logger.notice("已删除 \(file.path, privacy: .public)（\(reason, privacy: .public)）")
        } catch {
            logger.error("删除失败：\(file.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 备份文件的落点（`<文件名>.agent-island-backup`）。
    private static func backupURL(for file: URL) -> URL {
        file.appendingPathExtension(backupExtension)
    }

    /// 摘掉本应用的事件表条目；没有我们条目的文件原样不动（免得把用户的排版重排一遍）。
    private static func removeEventTable(spec: AgentHookSpec, location: Location) {
        let load = loadEventTable(at: location.configFile)
        if let refusal = load.refusalReason {
            logger.error("卸载时配置不可安全改写（\(refusal, privacy: .public)），跳过清理：\(location.configFile.path, privacy: .public)")
            return
        }
        guard AgentConfigMerger.containsAnyOwnEntry(
            in: load.settings, configKey: spec.configKey) else { return }

        let stripped = AgentConfigMerger.strippingOwnEntries(
            from: load.settings, configKey: spec.configKey)
        // 卸载对称性：文件是我们凭空创建的（无备份）、摘掉我们的条目后又只剩我们种下的键
        // （Copilot / Trae IDE 的 `version: 1`）或什么都不剩 ⇒ 整份删掉；用户后来自己加过
        // 顶层键就说明这文件已经归他，只摘我们的条目、文件留着。
        if wasCreatedByUs(location.configFile), holdsOnlySeededKeys(stripped) {
            removeCreatedFile(location.configFile, reason: "卸载后已无内容")
            return
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: stripped, options: [.prettyPrinted, .sortedKeys]
        ) else {
            logger.error("卸载时序列化失败，跳过清理：\(location.configFile.path, privacy: .public)")
            return
        }
        write(data, to: location.configFile)
    }

    /// 只删本应用写的事件文件：同名文件里不是我们的脚本（用户自己的 hook）一律留着。
    private static func removeClineFiles(spec: AgentHookSpec, location: Location) {
        for event in spec.events {
            let file = location.configFile.appendingPathComponent(event.name)
            guard let text = textContents(of: file),
                  HookInstaller.isOwnHookCommand(text) else { continue }
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.error("删除 Cline 事件文件失败：\(file.path, privacy: .public)")
            }
        }
    }

    // MARK: - 读写辅助

    /// 文本配置的读回结果：「没有这个文件」与「读不出来」必须分开——后者一律不动文件。
    private enum TextLoad {
        case absent
        case text(String)
        case unreadable
    }

    private static func readText(at file: URL) -> TextLoad {
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .text(text)
    }

    private static func textContents(of file: URL) -> String? {
        guard case let .text(contents) = readText(at: file) else { return nil }
        return contents
    }

    /// 读现有文本（不存在按空内容处理）；读不出来时放弃安装并返回 nil。
    private static func existingText(at file: URL, kind: AgentKind) -> String? {
        switch readText(at: file) {
        case .absent:
            return ""
        case .text(let contents):
            return contents
        case .unreadable:
            logger.error("\(kind.rawValue, privacy: .public) 的配置读不出来（IO 或非 UTF-8），本次跳过：\(file.path, privacy: .public)")
            return nil
        }
    }

    /// 读取事件表格式的配置文件（安全口径见 `HookSettingsLoad`）。
    private static func loadEventTable(at file: URL) -> HookSettingsLoad {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return HookSettingsMerger.load(data: nil, fileExists: false)
        }
        return HookSettingsMerger.load(data: try? Data(contentsOf: file), fileExists: true)
    }

    /// 确保目录存在。
    private static func ensureDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            logger.error("创建目录失败：\(directory.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 可执行权限位 `0o755`：hook 脚本与 Cline 的事件文件都要能被直接执行
    /// （与 `HookInstaller` 给脚本设的权限位一致）。
    private static func setExecutable(_ file: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
}
