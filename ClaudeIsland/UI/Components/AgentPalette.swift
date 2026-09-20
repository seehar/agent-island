//
//  AgentPalette.swift
//  ClaudeIsland
//
//  各 Agent 品牌色的唯一出处：刘海标记、转轮、归属角标、会话行与聊天的强调色都取自
//  这里，新增 Agent 时补一行即可。
//  取值不是凭感觉调的，而是各自官方站点/图标资产里实际在用的颜色，每条都注明出处，
//  便于日后对照更新。
//

import SwiftUI

extension AgentKind {
    /// 该 Agent 的品牌主色。凡是此前无论哪个 Agent 都统一套用 Claude 橙的地方，
    /// 现在都改用它。
    nonisolated var brandColor: Color {
        switch self {
        case .claudeCode:
            // Claude 橙 #D97757（Anthropic 品牌色）。本应用原有的强调色就是它，
            // 因此 Claude Code 的外观与改造前保持一致。
            return Color(red: 0.851, green: 0.467, blue: 0.341)
        case .ohMyPi:
            // omp.sh 图标渐变的中间色标 #9B4DFF，两端分别是 #ED4ABF 与 #5AD8E6。
            return Color(red: 0.608, green: 0.302, blue: 1.0)
        case .pi:
            // pi.dev 站点 logo 是 #F09082 / #4D9ABF / #F1BE58 三色。取蓝 #4D9ABF：
            // 面积最大的那只珊瑚色与 Claude 橙的 ΔE2000 只有 9.7，14pt 下几乎分不出来；
            // 黄 #F1BE58 与「待审批」的琥珀色 ΔE 只有 6.8，会与状态色混淆。
            // 蓝色对 Claude / OMP / OpenCode 的 ΔE 分别是 45.6 / 27.1 / 21.5。
            return Color(red: 0.302, green: 0.604, blue: 0.749)
        case .opencode:
            // opencode.ai 的标识本身是白/灰单色（图标为暗底白框），没有彩色品牌色，
            // 取其站点里出现最多的 #8E8B8B 作中性灰。
            return Color(red: 0.557, green: 0.545, blue: 0.545)
        }
    }
}
