//
//  AgentBadge.swift
//  AgentIsland
//
//  会话行与聊天标题旁的 Agent 归属角标。只有用户启用了多个 Agent 时才需要
//  区分，因此调用点自行判断是否渲染（见 `AgentRegistry.enabled.count > 1`）。
//  Agent 名是产品名，不做本地化；配色取该 Agent 的品牌色，让角标与刘海标记同色。
//

import SwiftUI

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 3) {
            AgentLogo(agent: agent, size: 10)
            Text(agent.shortName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(agent.brandColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(agent.brandColor.opacity(0.16))
        )
        .fixedSize()
    }
}