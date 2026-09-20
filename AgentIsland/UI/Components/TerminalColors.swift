//
//  TerminalColors.swift
//  AgentIsland
//
//  终端风格的 Agent 相位配色。其余语义色（成功/危险状态、卡片与浮层底色、
//  文字层级等）已提升为 AppPalette，见 UI/Components/AppTheme.swift；
//  本文件只保留仍在使用的相位色。
//

import SwiftUI

struct TerminalColors {
    static let green = Color(red: 0.4, green: 0.75, blue: 0.45)
    static let amber = Color(red: 1.0, green: 0.7, blue: 0.0)
    static let cyan = Color(red: 0.0, green: 0.8, blue: 0.8)
    static let magenta = Color(red: 0.8, green: 0.4, blue: 0.8)
    static let dim = Color.white.opacity(0.4)
    /// 应用级「处理中」强调色 #d97857（沿用 Claude 橙）。用于不归属于某个 Agent 的
    /// 场合，例如关闭态计数的取色；各 Agent 自己的配色见 AgentPalette。
    static let prompt = Color(red: 0.85, green: 0.47, blue: 0.34)
}
