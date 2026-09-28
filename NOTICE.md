# Third-party notices

## CodeIsland — pixel mascots

`AgentIsland/UI/Mascots/`（除 `DeepSeekHarnessMascot.swift` 与共享层外）的角色画法、配色与
动作是移植自 **CodeIsland** 的 `Sources/CodeIsland/*View.swift`（Clawd / Dex / Gemini /
Cursor / Trae / Copilot / Qoder / Droid / Buddy / Kimi / Cline / Grok / Hermes / Pi /
OpenCode 等），坐标常量、场景视口与关键帧逐值保留；本仓在此基础上把时间改为显式传参
（`t` 的纯函数）、去掉了非确定性的 `repeatForever` 动画、把睡眠 Z 改为像素绘制，并对起跳幅度
做了「不把身体抛出视口」的截顶（`MascotMotion.alertRiseFactor`）。

```
MIT License

Copyright (c) 2026 wxtsky

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

部分角色的画法在其上游另有出处：Clawd 的像素造型源自 clawd-on-desk 的 SVG 素材
（CodeIsland 已在源码注释中标明）；Grok 的标记几何取自 xAI 公布的
`Grok-feb-2025-logo.svg`。