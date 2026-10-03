//
//  MessageBubble.swift
//  Wanda
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    /// Set on the reply Wanda is reading aloud: the bubble then glows with her voice.
    var voice: WandaVoice?

    private var isUser: Bool { message.sender == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if message.sender == .wanda {
                        Text(ReplyFormatter.display(message.text))
                    } else {
                        Text(message.text)
                    }
                }
                    .textSelection(.enabled)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .background {
                        if let voice {
                            SpeakingGlow(voice: voice, cornerRadius: 14)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: voice != nil)
                if message.isLocal {
                    Label("On your Mac", systemImage: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                        .help("Answered locally, without using the AI")
                }
            }
            // Keep long messages readable when the window is wide.
            .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)
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

/// A swirling multicolor glow behind the reply Wanda is reading aloud, like her logo in
/// the mini view: it brightens and spreads with the loudness of her voice and pulses on
/// every word.
struct SpeakingGlow: View {
    @ObservedObject var voice: WandaVoice
    let cornerRadius: CGFloat

    @State private var bounce: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !voice.isSpeaking)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let energy = CGFloat(voice.level)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let gradient = AngularGradient(
                colors: [.purple, .blue, .cyan, .pink, .purple],
                center: .center,
                angle: .degrees(time * 120)
            )
            // Sits behind the bubble, so only the glow spilling past its edges shows. The
            // gradient is drawn square, then stretched to the bubble, so its colors circle
            // the edges at an even pace like the logo's glow instead of racing along the
            // long sides of a wide bubble.
            GeometryReader { geometry in
                Rectangle()
                    .fill(gradient)
                    .frame(width: 100, height: 100)
                    .scaleEffect(x: geometry.size.width / 100, y: geometry.size.height / 100)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(shape)
            }
                .blur(radius: 8 + energy * 10 + bounce * 3)
                .opacity(0.5 + energy * 0.5)
                .scaleEffect(1 + energy * 0.03 + bounce * 0.02)
        }
        .allowsHitTesting(false)
        .onChange(of: voice.wordCount) { _ in
            withAnimation(.spring(response: 0.12, dampingFraction: 0.5)) { bounce = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.25)) { bounce = 0 }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Three dots that pulse in turn while Wanda is thinking.
struct TypingDots: View {
    var body: some View {
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
        .accessibilityLabel("Wanda is typing")
    }
}

struct TypingIndicator: View {
    var body: some View {
        HStack {
            TypingDots()
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
