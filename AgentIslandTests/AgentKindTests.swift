//
//  AgentKindTests.swift
//  AgentIslandTests
//
//  受支持的 Agent 是一个数据表，漏填某一列不会编译报错，只会在界面上留一块空白：
//  这里用表驱动用例把「每个 case 都必须具备什么」钉死。新增一个 Agent 时，
//  这些断言是唯一会主动提醒你的地方。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("Agent 表完整性")
struct AgentKindTests {
    @Test("rawValue 唯一、非空，且不能含冒号（会话主键按第一个冒号切分）")
    func rawValuesAreUniqueAndKeySafe() {
        var seen = Set<String>()
        for kind in AgentKind.allCases {
            #expect(!kind.rawValue.isEmpty)
            #expect(!kind.rawValue.contains(":"), "\(kind.rawValue) 含冒号，会破坏 SessionKey 的解析")
            #expect(seen.insert(kind.rawValue).inserted, "\(kind.rawValue) 重复")
            // 集成侧用同一个字符串当 --source，落库与信封也用它，必须能被 AgentKind 还原。
            #expect(AgentKind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test("每个 Agent 都有产品名与紧凑标签")
    func namesArePresent() {
        for kind in AgentKind.allCases {
            #expect(!kind.displayName.isEmpty, "\(kind.rawValue) 缺 displayName")
            #expect(!kind.shortName.isEmpty, "\(kind.rawValue) 缺 shortName")
        }
    }

    @Test("只有扩展宿主（Cline）没有 CLI 可执行名")
    func binaryNamesMatchHosting() {
        for kind in AgentKind.allCases where kind != .cline {
            #expect(!kind.binaryName.isEmpty, "\(kind.rawValue) 缺 binaryName")
        }
        #expect(AgentKind.cline.binaryName.isEmpty)
    }

    @Test("审批能力自洽：能回传决定就必须有一个等待应答的请求事件")
    func approvalCapabilityIsConsistent() {
        for kind in AgentKind.allCases {
            let approval = kind.approval
            if approval.canDecideRemotely {
                #expect(approval.waitsForDecision, "\(kind.rawValue) 能回传决定却不等待应答")
                #expect(
                    ["PermissionRequest", "ToolApproval"].contains(approval.requestEvent),
                    "\(kind.rawValue) 的请求事件名不在已知集合里：\(approval.requestEvent)")
            } else {
                #expect(approval.requestEvent.isEmpty, "\(kind.rawValue) 不能回传决定却带了请求事件")
            }
        }
    }

    @Test("需要装集成的 Agent：有 hookSpec 的、以及走脚本/扩展/插件的四个")
    func requiresIntegrationMatchesAccessPath() {
        let scriptOrPluginAgents: Set<AgentKind> = [.claudeCode, .ohMyPi, .pi, .opencode]
        for kind in AgentKind.allCases {
            let expected = kind.hookSpec != nil || scriptOrPluginAgents.contains(kind)
            #expect(
                kind.requiresIntegrationInstall == expected,
                "\(kind.rawValue) 的 requiresIntegrationInstall 与接入方式（hookSpec）不一致")
        }
        // DSH 是插件运行时：事件由外部插件直接写 socket，本应用没有可装的集成。
        #expect(AgentKind.deepSeekHarness.hookSpec == nil)
        #expect(!AgentKind.deepSeekHarness.requiresIntegrationInstall)
    }

    @Test("hookSpec 只在配置文件型接入的 Agent 上出现")
    func hookSpecCoversConfigFileAgentsOnly() {
        let expected: Set<AgentKind> = [
            .codex, .gemini, .cursor, .copilot, .qoder, .factory, .codeBuddy, .kimi, .cline,
            .grok, .trae, .traeCli, .hermes,
        ]
        let actual = Set(AgentKind.allCases.filter { $0.hookSpec != nil })
        #expect(actual == expected)
    }

    @Test("hookSpec 的事件表可用：非空、不重名、阻塞事件预算足够且只有能回传决定的 Agent 才有")
    func hookSpecEventsAreUsable() {
        for kind in AgentKind.allCases {
            guard let spec = kind.hookSpec else { continue }
            #expect(!spec.events.isEmpty, "\(kind.rawValue) 的事件表是空的")
            #expect(!spec.configPath.isEmpty, "\(kind.rawValue) 缺配置路径")

            var names = Set<String>()
            for event in spec.events {
                #expect(names.insert(event.name).inserted, "\(kind.rawValue) 的事件 \(event.name) 重复")
                #expect(event.timeout > 0, "\(kind.rawValue) 的事件 \(event.name) 超时非正数")
            }

            // 阻塞事件（等人在刘海上按按钮）必须有足够长的预算，且只出现在能回传决定的
            // Agent 上——否则卡片会给出一个永远无效的批准按钮。
            for event in spec.events where event.blocking {
                #expect(spec.verdict != .none, "\(kind.rawValue) 的阻塞事件没有回写协议")
                #expect(kind.approval.canDecideRemotely, "\(kind.rawValue) 不回传决定却装了阻塞事件")
                #expect(
                    event.timeout >= 300,
                    "\(kind.rawValue) 的阻塞事件 \(event.name) 只有 \(event.timeout)s，人还没按就超时了")
            }
            if spec.hasBlockingEvent {
                // 阻塞审批走的是 `PermissionRequest` 这条通道（omp/pi/opencode 的
                // ToolApproval 由扩展上报，与配置文件型 hook 无关）。
                #expect(kind.approval.requestEvent == "PermissionRequest")
            } else {
                // 没有阻塞事件的工具不能声称能在刘海上批准。
                #expect(!kind.approval.canDecideRemotely || kind.hookSpec == nil)
            }
        }
    }

    @Test("各工具的决定回写协议与它的原生约定一致")
    func verdictProtocolsMatchToolConventions() {
        #expect(AgentKind.gemini.hookSpec?.verdict == .geminiDecision)
        #expect(AgentKind.gemini.hookSpec?.timeoutsInMilliseconds == true)
        for kind in [AgentKind.codex, .qoder, .traeCli] {
            #expect(kind.hookSpec?.verdict == .claudeEnvelope, "\(kind.rawValue) 不回写 allow/deny")
        }
        for kind in [AgentKind.cursor, .copilot, .kimi, .cline, .trae, .factory, .codeBuddy, .hermes] {
            // 显式写出类型：`.none` 在可选比较里会被推断成 `Optional.none`（编译器会警告）。
            #expect(
                kind.hookSpec?.verdict == AgentVerdictProtocol.none,
                "\(kind.rawValue) 不该回写决定")
        }
        // 只有 Codex 需要额外打开 config.toml 的 [features] hooks 开关。
        let withPrerequisites = AgentKind.allCases.filter { !($0.hookSpec?.prerequisites.isEmpty ?? true) }
        #expect(withPrerequisites == [.codex])
        // 只有这三个工具用环境变量覆盖配置根目录（Codex 的 `CODEX_HOME`、Grok 的
        // `GROK_HOME`、Hermes 的 `HERMES_HOME`——后者是它 config.yaml / state.db /
        // shell-hooks-allowlist 的单一事实源，默认 `~/.hermes`，恰好等于本表
        // `rootEnvVar` 缺省推导出来的 `~/.<rawValue>`）。
        let withRootEnv = AgentKind.allCases.filter { $0.hookSpec?.rootEnvVar != nil }
        #expect(Set(withRootEnv) == [.codex, .grok, .hermes])
    }

    @Test("Claude 系（含 fork）的派生工具名与交互工具名一致，且各 Agent 之间不互相污染")
    func claudeFamilySharesToolVocabulary() {
        let family: Set<AgentKind> = [.claudeCode, .qoder, .factory, .codeBuddy]
        for kind in AgentKind.allCases {
            if family.contains(kind) {
                #expect(kind.isClaudeFamily)
                #expect(kind.subagentToolNames == ["Agent", "Task"])
                #expect(kind.reportsSubagentInnerTools)
                #expect(kind.interactiveToolNames == ["AskUserQuestion"])
            } else {
                #expect(!kind.isClaudeFamily)
                #expect(!kind.reportsSubagentInnerTools)
                #expect(!kind.interactiveToolNames.contains("AskUserQuestion"))
            }
        }
        #expect(AgentKind.ohMyPi.interactiveToolNames == ["ask"])
        #expect(AgentKind.pi.interactiveToolNames == ["ask"])
        #expect(AgentKind.opencode.interactiveToolNames == ["question"])
        // 批准语义的工具名不能被任何一个 Agent 当成提问。
        for kind in AgentKind.allCases {
            for tool in ["bash", "edit", "write", "webfetch"] {
                #expect(!kind.isInteractiveTool(tool))
            }
        }
    }

    @Test("派生工具名并集覆盖全部 Agent，且不含空串")
    func subagentToolNameUnionIsClean() {
        // Hermes 的派生工具是 `delegate_task`（tools/delegate_tool.py 的注册名）。
        #expect(AgentKind.allSubagentToolNames == ["Agent", "Task", "task", "delegate_task"])
        #expect(!AgentKind.allSubagentToolNames.contains(""))
    }
}

@Suite("hook 脚本落点")
struct AgentHookScriptTests {
    @Test("脚本只有一个落点：~/.agent-island/hooks/，且路径与文件名稳定")
    func scriptLocationIsSingleAndStable() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(
            AgentHookScript.fileURL(home: home).path
                == "/Users/example/.agent-island/hooks/agent-island-state.py")
        #expect(AgentHookScript.directory(home: home).path == "/Users/example/.agent-island/hooks")
        // 写进各工具配置里的 shell 路径必须与真实落点一致（否则工具跑的是不存在的脚本）。
        #expect(AgentHookScript.shellPath(home: home) == AgentHookScript.fileURL(home: home).path)
        // 改名前的旧文件名仍要能被安装器识别清理。
        #expect(AgentHookScript.legacyFileNames.contains("claude-island-state.py"))
    }
}
