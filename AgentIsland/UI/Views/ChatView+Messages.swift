//
//  ChatView+Messages.swift
//  AgentIsland
//
//  ChatView 的消息行家族：条目分发、图片 / 用户 / 助手三种文本行。
//
//  自 ChatView.swift 按渲染家族拆出，类型与可见性保持不变（同模块内 internal）。
//

import SwiftUI

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    /// 子 Agent 的 job 名 → 任务描述（`AgentOutputTool` 行显示用）。
    let agentDescriptions: [String: String]

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text)
        case .toolCall(let tool):
            ToolCallView(tool: tool, agentDescriptions: agentDescriptions)
        case .thinking(let text):
            ThinkingView(text: text)
        case .image(let block):
            ImageMessageView(image: block)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - Image Message

struct ImageMessageView: View {
    let image: ImageBlock
    @ObservedObject private var l10n = LocalizationManager.shared

    /// Decoded image cached so base64 isn't re-decoded on every render.
    /// Large inline images (tens of KB) would otherwise thrash during
    /// scrolling or parent re-renders.
    @State private var decoded: NSImage?

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            } else {
                // Decode failed — show a labelled placeholder rather than silently dropping
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .appFont(12)
                    Text(l10n.t("Image (%@)", image.mediaType))
                        .appFont(12)
                }
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                )
            }
        }
        .task(id: image.id) {
            // Decode off the main thread so large images don't hitch scrolling.
            let b64 = image.base64Data
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: b64) else { return nil as NSImage? }
                return NSImage(data: data)
            }.value
            self.decoded = decoded
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.15))
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        // Skip rendering when text is empty — otherwise the dot indicator
        // shows up alone (orphan dot) for tool-only assistant turns.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                // White dot indicator
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

                Spacer(minLength: 60)
            }
        }
    }
}
