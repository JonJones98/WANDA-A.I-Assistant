//
//  WandaOrb.swift
//  Wanda
//

import SwiftUI

/// Wanda's logo with a glow that comes alive with her voice: the glow swells and swirls
/// with the loudness of the speech and the logo bounces on every word. While listening
/// it breathes gently; otherwise it rests.
struct WandaOrb: View {
    @ObservedObject var voice: WandaVoice
    let isListening: Bool
    var size: CGFloat = 30
    /// Puts a frosted circle behind the logo so it stands out on any background; the
    /// glow still shows around it.
    var backed = false

    @State private var bounce: CGFloat = 0

    private var isActive: Bool { voice.isSpeaking || isListening }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let energy = currentEnergy(at: time)
            ZStack {
                // Swirling glow behind the logo.
                Circle()
                    .fill(AngularGradient(
                        colors: [.purple, .blue, .cyan, .pink, .purple],
                        center: .center,
                        angle: .degrees(time * 120)
                    ))
                    .frame(width: size, height: size)
                    .scaleEffect(1.1 + energy * 0.7 + bounce * 0.2)
                    .blur(radius: 5 + energy * 9)
                    .opacity(isActive ? 0.35 + energy * 0.6 : 0)
                if backed {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .frame(width: size + 8, height: size + 8)
                        .scaleEffect(1 + energy * 0.1 + bounce * 0.12)
                }
                Image("AppIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + energy * 0.1 + bounce * 0.12)
                    .shadow(color: .purple.opacity(Double(energy) * 0.6), radius: energy * 8)
            }
            .frame(width: size * 2, height: size * 2)
        }
        .onChange(of: voice.wordCount) { _ in
            withAnimation(.spring(response: 0.12, dampingFraction: 0.5)) { bounce = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.25)) { bounce = 0 }
            }
        }
        .accessibilityLabel(voice.isSpeaking ? "Wanda is speaking" : (isListening ? "Wanda is listening" : "Wanda"))
    }

    /// 0…1: the voice's loudness while speaking, a slow breath while listening.
    private func currentEnergy(at time: TimeInterval) -> CGFloat {
        if voice.isSpeaking {
            return CGFloat(voice.level)
        }
        if isListening {
            return CGFloat((sin(time * 3) + 1) / 2) * 0.35
        }
        return 0
    }
}
