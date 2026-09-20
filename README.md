<div align="center">
  <img src="AgentIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">AgentIsland</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code, Oh My Pi, Pi and OpenCode CLI sessions.
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

**English** | [简体中文](README.zh-CN.md)

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Multi-Agent Sessions** — Monitors Claude Code, Oh My Pi (`omp`), Pi and OpenCode sessions side by side, each tagged with its own badge
- **Live Session Monitoring** — Track multiple sessions per agent in real-time
- **Permission Approvals** — Approve or deny Claude Code tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Per-agent integrations install automatically on first launch

## Requirements

- macOS 15.6+
- At least one supported CLI: [Claude Code](https://claude.com/claude-code), `omp` (Oh My Pi), `pi`, or [OpenCode](https://opencode.ai)

## Supported Agents

| Agent | Session records | Live integration | Approve from notch |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `hooks/agent-island-state.py` + `settings.json` | yes |
| Oh My Pi (`omp`) | `~/.omp/agent/sessions/**/*.jsonl` | `~/.omp/agent/extensions/agent-island-state.ts` | no (status only) |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | `~/.pi/agent/extensions/agent-island-state.ts` | no (status only) |
| OpenCode | `~/.local/share/opencode/opencode.db` | `~/.config/opencode/plugins/agent-island-state.js` | no (status only) |

Agents can be enabled or disabled individually from the notch menu; integrations are installed
for the enabled agents and removed when one is switched off. Agents without an installed
integration still show up: their sessions are discovered by scanning the record directory (or
database) and their status is inferred from the transcript.

## Install

Download the latest release or build from source:

```bash
xcodebuild -scheme AgentIsland -configuration Release build
```

## How It Works

AgentIsland installs a small integration per agent that reports session state over a Unix socket
(`/tmp/agent-island.sock`). The app listens for those events, parses the agent's own session
records for conversation history, and displays everything in the notch overlay.

For Claude Code the integration is a hook script in `~/.claude/hooks/`; for `omp`/`pi` it is a
TypeScript extension; for OpenCode it is a plugin. The integrations are the only agent-side files
AgentIsland writes, and each is removed when its agent is disabled in the notch menu.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to
switch to the terminal. Other agents keep their own approval UI; the notch only shows that they are
waiting.

## License

Apache 2.0
