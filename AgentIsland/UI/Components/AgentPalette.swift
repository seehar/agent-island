//
//  AgentPalette.swift
//  AgentIsland
//
//  各 Agent 品牌色的唯一出处：刘海标记、转轮、归属角标、会话行与聊天的强调色都取自
//  这里，新增 Agent 时补一行即可。
//  取值不是凭感觉调的，而是各自官方图标资产里实际在用的颜色（本机可从
//  CodeIsland 的 cli-icons/*.png 取到同一批品牌资产），每条都注明出处与最近邻的
//  ΔE2000，便于日后对照更新。
//
//  一个必须说清的事实：18 个品牌里有 7 个是蓝/紫（omp / pi / codex / gemini /
//  codeBuddy / kimi / dsh）、2 个是绿（qoder / trae / traeCli）、5 个是黑白单色的
//  中性灰（opencode / cursor / copilot / cline / grok）、3 个是橙/金（claude /
//  factory / hermes），因此**不可能两两都拉开到 ΔE ≥ 12**。本表的取舍是：品牌色优先（能取到品牌色的
//  就用品牌色），单色品牌取一组按明度展开的中性灰（它们本来没有彩色可言，明度是
//  唯一可用的区分维度），最终最小 ΔE 约 7。标记之间主要靠形状与 shortName 区分，
//  颜色只是辅助；改这里时请连带重算 ΔE，不要把两个相近色的 ΔE 压得更小。
//

import SwiftUI

extension AgentKind {
    /// 该 Agent 的品牌主色。凡是此前无论哪个 Agent 都统一套用 Claude 橙的地方，
    /// 现在都改用它。
    nonisolated var brandColor: Color {
        switch self {
        case .claudeCode:
            // Claude 橙 #D97757（Anthropic 品牌色）。本应用原有的强调色就是它，
            // 因此 Claude Code 的外观与改造前保持一致。（最近邻：Factory ΔE 12）
            return Color(red: 0.851, green: 0.467, blue: 0.341)
        case .ohMyPi:
            // omp.sh 图标渐变的中间色标 #9B4DFF，两端分别是 #ED4ABF 与 #5AD8E6。
            // （最近邻：Gemini ΔE 11）
            return Color(red: 0.608, green: 0.302, blue: 1.0)
        case .pi:
            // pi.dev 站点 logo 是 #F09082 / #4D9ABF / #F1BE58 三色。取蓝 #4D9ABF：
            // 面积最大的那只珊瑚色与 Claude 橙的 ΔE2000 只有 9.7，14pt 下几乎分不出来；
            // 黄 #F1BE58 与「待审批」的琥珀色 ΔE 只有 6.8，会与状态色混淆。
            // （最近邻：Codex ΔE 14）
            return Color(red: 0.302, green: 0.604, blue: 0.749)
        case .opencode:
            // opencode.ai 的标识本身是白/灰单色（图标为暗底白框），没有彩色品牌色，
            // 取其站点里出现最多的 #8E8B8B 作中性灰。（最近邻：Grok ΔE 9）
            return Color(red: 0.557, green: 0.545, blue: 0.545)
        case .codex:
            // Codex 图标（cli-icons/codex.png，蓝紫云 + 提示符）的主色 #7C9CFC。
            return Color(red: 0.486, green: 0.612, blue: 0.988)
        case .gemini:
            // Gemini 四角星渐变里的紫端 #8C74D4（另一端是蓝 #4796E3）。
            // 取紫端是为了与 Codex/OMP 的蓝紫拉开（最近邻 OMP ΔE 11）。
            return Color(red: 0.549, green: 0.455, blue: 0.831)
        case .cursor:
            // Cursor 的标识是黑白立方体，没有彩色品牌色 → 中性灰档（本组 4 个单色
            // 品牌按明度展开，见文件头说明）。L* 41，与 OpenCode 灰 ΔE 17。
            return Color(red: 0.376, green: 0.376, blue: 0.376)
        case .copilot:
            // Copilot 的护目镜标识同样是黑白 → 中性灰档，L* 78。
            return Color(red: 0.761, green: 0.761, blue: 0.761)
        case .qoder:
            // Qoder 图标（cli-icons/qoder.png）的绿 #2CDC5C。与 Trae 的薄荷绿同属
            // 绿系（ΔE 7），两者靠形状区分。
            return Color(red: 0.173, green: 0.863, blue: 0.361)
        case .factory:
            // Factory 图标是单一橙 #FC7414，与 Claude 橙同色系（ΔE 12）——这是品牌
            // 事实，不能为了区分而换色。
            return Color(red: 0.988, green: 0.455, blue: 0.078)
        case .codeBuddy:
            // CodeBuddy 图标（cli-icons/codebuddy.png）的紫 #6C4CFC 与 OMP 的紫
            // ΔE 只有 7，因此取该图标渐变更亮的一端 #B4A4FC（与 Codex ΔE 12）。
            return Color(red: 0.706, green: 0.643, blue: 0.988)
        case .kimi:
            // Kimi 图标（cli-icons/kimi.png）的蓝 #0B62D6（取深端，与 DeepSeek 的
            // 亮蓝拉开到 ΔE 9）。
            return Color(red: 0.043, green: 0.384, blue: 0.839)
        case .cline:
            // Cline 图标是深板岩色（#303040）→ 中性灰档，L* 93。
            return Color(red: 0.925, green: 0.925, blue: 0.925)
        case .grok:
            // Grok / xAI 的标识是黑白斜杠 → 中性灰档，L* 68。
            return Color(red: 0.651, green: 0.651, blue: 0.651)
        case .trae, .traeCli:
            // Trae 图标（cli-icons/trae.png，终端面孔）的薄荷绿 #34F48C；Trae CLI
            // 与它共用同一枚标记（官方的 traecli 没有独立图标）。
            return Color(red: 0.204, green: 0.957, blue: 0.549)
        case .deepSeekHarness:
            // DeepSeek Harness 用 DeepSeek 的官方蓝 #4D6BFE（图标 cli-icons/dsh.png
            // 的渐变主色）。
            return Color(red: 0.302, green: 0.420, blue: 0.996)
        case .hermes:
            // Hermes（Nous Research）的品牌金 #FFD700 —— 出处是它自己站点的
            // `website/src/css/custom.css` 的 `--ifm-color-primary`（深色主题那一档，
            // 源码注释原文「Current gold #FFD700」）；它的 CLI 调色板
            // （hermes_cli/colors.py 之外的界面色）与吉祥物图标的金色描边同源。
            // 取舍：与「待审批」的琥珀色（TerminalColors.amber #FFB300）ΔE 12.4，
            // 高于本表自设的 12 门槛（同一口径下 Pi 的黄色档只有 6.8，因而被弃用）；
            // 本品牌更深的 goldenrod #DAA520 反而只有 ΔE 7.2，更糟，故不采用。
            // （品牌色最近邻：Cline ΔE 30）
            return Color(red: 1.0, green: 0.843, blue: 0.0)
        }
    }
}
