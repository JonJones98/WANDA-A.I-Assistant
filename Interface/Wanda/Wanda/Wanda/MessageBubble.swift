//
//  MessageBubble.swift
//  Wanda
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.sender == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 3) {
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if message.isLocal {
                    Label("On your Mac", systemImage: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                        .help("Answered locally, without using the AI")
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }

    private var background: Color {
        switch message.sender {
        case .user: return Color("UserBubble")
        case .wanda: return Color("WandaBubble")
        case .error: return Color.red.opacity(0.18)
        }
    }
}

struct TypingIndicator: View {
    var body: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let active = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(dot == active ? 1 : 0.35)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color("WandaBubble"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Wanda is typing")
            Spacer()
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        MessageBubble(message: ChatMessage(text: "Hello! How can I help you today?", sender: .wanda))
        MessageBubble(message: ChatMessage(text: "Open Safari", sender: .user))
        MessageBubble(message: ChatMessage(text: WandaAPIError.serverUnreachable.localizedDescription, sender: .error))
        TypingIndicator()
    }
    .padding()
    .frame(width: 400)
}
