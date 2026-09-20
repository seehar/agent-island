//
//  AgentBadge.swift
//  ClaudeIsland
//
//  会话行与聊天标题旁的 Agent 归属角标。只有用户启用了多个 Agent 时才需要
//  区分，因此调用点自行判断是否渲染（见 `AgentRegistry.enabled.count > 1`）。
//  Agent 名是产品名，不做本地化。
//

import SwiftUI

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: agent.symbolName)
                .font(.system(size: 9, weight: .medium))
            Text(agent.shortName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.5))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
        )
        .fixedSize()
    }
}