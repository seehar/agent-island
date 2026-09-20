<div align="center">
  <img src="AgentIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">AgentIsland</h3>
  <p align="center">
    一款 macOS 菜单栏应用，为 Claude Code、Oh My Pi、Pi 与 OpenCode 的 CLI 会话带来「灵动岛」风格的通知。
    <br />
    <br />
    <a href="https://github.com/seehar/agent-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/seehar/agent-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/seehar/agent-island/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

[English](README.md) | **简体中文**

## 功能特性

- **刘海界面** — 从 MacBook 刘海处展开的动画浮层
- **多 Agent 会话** — 并排监控 Claude Code、Oh My Pi（`omp`）、Pi 与 OpenCode 会话，每个会话都带有各自的标识徽章
- **实时会话监控** — 实时跟踪各 Agent 的多个会话
- **权限审批** — 直接在刘海上批准或拒绝 Claude Code 的工具执行
- **聊天记录** — 支持 Markdown 渲染的完整对话历史
- **自动配置** — 各 Agent 的集成在首次启动时自动安装

## 系统要求

- macOS 15.6+
- 至少安装一款受支持的 CLI：[Claude Code](https://claude.com/claude-code)、`omp`（Oh My Pi）、`pi` 或 [OpenCode](https://opencode.ai)

## 支持的 Agent

| Agent | 会话记录 | 实时集成 | 刘海审批 |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `hooks/agent-island-state.py` + `settings.json` | 支持 |
| Oh My Pi (`omp`) | `~/.omp/agent/sessions/**/*.jsonl` | `~/.omp/agent/extensions/agent-island-state.ts` | 不支持（仅状态） |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | `~/.pi/agent/extensions/agent-island-state.ts` | 不支持（仅状态） |
| OpenCode | `~/.local/share/opencode/opencode.db` | `~/.config/opencode/plugins/agent-island-state.js` | 不支持（仅状态） |

每个 Agent 都可以在刘海菜单中单独启用或停用；集成只为已启用的 Agent 安装，某个 Agent 被关闭时对应的集成会被移除。
未安装集成的 Agent 依然会被列出：应用通过扫描其记录目录（或数据库）发现会话，并从会话记录中推断状态。

## 安装

下载最新发布版本，或从源码构建：

```bash
xcodebuild -scheme AgentIsland -configuration Release build
```

## 工作原理

AgentIsland 会为每个 Agent 安装一个小型集成，通过 Unix socket（`/tmp/agent-island.sock`）上报会话状态。
应用监听这些事件，解析 Agent 自身的会话记录以获取对话历史，并把全部内容展示在刘海浮层中。

对 Claude Code 而言，集成是 `~/.claude/hooks/` 下的一个 hook 脚本；对 `omp`/`pi` 而言是一个 TypeScript 扩展；对 OpenCode 而言是一个插件。
这些集成是 AgentIsland 唯一写入的 Agent 侧文件，且在对应 Agent 于刘海菜单中被停用时都会被移除。

当 Claude 需要运行某个工具的权限时，刘海会展开并提供批准/拒绝按钮——无需切换到终端。
其他 Agent 保留各自的审批界面，刘海只提示它们正在等待。

## 许可证

Apache 2.0