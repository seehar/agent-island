//
//  ChatView+Indicators.swift
//  AgentIsland
//
//  ChatView 的状态指示家族：处理中、思考、中断提示与「回到最新」胶囊。
//
//  自 ChatView.swift 按渲染家族拆出，类型与可见性保持不变（同模块内 internal）。
//

import Combine
import SwiftUI

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    /// 转轮帧表与强调色都归属当前会话的 Agent
    let agent: AgentKind

    /// 文案配色取该 Agent 的品牌色
    private var color: Color { agent.brandColor }

    /// 每种语言的候选文案数量，init 与 baseText 必须一致。
    private static let variantCount = 2
    private let textIndex: Int

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// 用 turnId 为同一轮对话稳定地挑选文案
    init(turnId: String = "", agent: AgentKind) {
        self.agent = agent
        // 取哈希绝对值再取模（magnitude 避免 abs(Int.min) 溢出崩溃）
        textIndex = Int(turnId.hashValue.magnitude % UInt(Self.variantCount))
    }

    /// 基础文案在每次渲染时解析，以便跟随语言切换
    private var baseText: String {
        textIndex == 0 ? l10n.t("Processing") : l10n.t("Working")
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            AgentSpinner(agent: agent)
                .frame(width: 6)

            Text(baseText + dots)
                .appFont(13)
                .foregroundColor(color)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        // Skip rendering when text is empty — streaming thinking blocks can
        // briefly arrive empty, which otherwise leaves an orphan grey dot.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                    .italic()
                    .appFont(11)
                    .foregroundColor(.gray)
                    .lineLimit(isExpanded ? nil : 1)
                    .multilineTextAlignment(.leading)

                Spacer()

                if canExpand {
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .medium)
                        .foregroundColor(.gray.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canExpand {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    var body: some View {
        HStack {
            Text(l10n.t("Interrupted"))
                .appFont(13)
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - New Messages Indicator

/// 回到最新入口的悬浮胶囊。上翻回看时出现（见 `LatestJumpIndicator`）；
/// `count == 0` 时只剩箭头——没有新消息也必须有入口，否则用户卡在半空。
struct NewMessagesIndicator: View {
    let count: Int
    /// 归属 Agent 的品牌色
    let color: Color
    let onTap: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var isHovering: Bool = false

    /// 无障碍名称：无新消息时胶囊里只有一枚箭头，VoiceOver 只能念出「chevron down」。
    /// catalog 里没有「回到底部」这一条，这里先复用既有的 Show（需要新键时另行上报）。
    private var accessibilityText: String {
        count > 0 ? l10n.t("%lld new messages", count) : l10n.t("Show")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .appFont(10, weight: .bold)

                if count > 0 {
                    Text(l10n.t("%lld new messages", count))
                        .appFont(12, weight: .medium)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(color)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityText))
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
