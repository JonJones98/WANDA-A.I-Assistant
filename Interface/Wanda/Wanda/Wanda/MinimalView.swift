//
//  MinimalView.swift
//  Wanda
//

import SwiftUI

/// A compact, Siri-style card: what you asked (small, grey) and Wanda's reply (large,
/// in the accent colour). Shows your words live while listening. Hover for the mic and
/// the button back to the full chat.
struct MinimalView: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var speech: SpeechRecognizer
    let onClose: () -> Void
    let onToggleMic: () -> Void
    let onShowFullView: () -> Void

    @State private var isHovering = false

    private var messages: [ChatMessage] { chat.displayMessages }

    /// What's being heard: real dictation, or the demo pretending to listen.
    private var heard: String? {
        speech.isRecording ? speech.transcript : chat.demo?.transcript
    }

    private var lastRequest: String? {
        messages.last { $0.sender == .user }?.text
    }

    /// Wanda's latest reply, unless the user has asked something newer.
    private var lastReply: ChatMessage? {
        guard let last = messages.last, last.sender != .user else { return nil }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heard {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                    Text(heard.isEmpty ? "Listening…" : heard)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(3)
                }
                .frostedPill()
            } else if let lastRequest {
                HStack(spacing: 3) {
                    Text(lastRequest)
                        .lineLimit(2)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary.opacity(0.75))
                .frostedPill()
            }

            if chat.isWaiting {
                TypingDots()
                    .padding(.vertical, 4)
                    .frostedPill()
            } else if heard == nil, let lastReply {
                Text(lastReply.sender == .wanda ? ReplyFormatter.display(lastReply.text) : AttributedString(lastReply.text))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(lastReply.sender == .error ? Color.red : Color.accentColor)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frosted(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 60)   // room for the logo
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(minHeight: 80, alignment: .top)
        .overlay(alignment: .topLeading) {
            // Window-style controls: close always; mic and full view on hover.
            HStack(spacing: 6) {
                iconButton("xmark", help: "Hide Wanda", action: onClose)
                if chat.demo != nil, chat.showsDemoBar {
                    iconButton("stop.fill", help: "Stop demo", action: chat.endDemo)
                }
                if isHovering || speech.isRecording {
                    iconButton(speech.isRecording ? "mic.fill" : "mic",
                               tint: speech.isRecording ? .red : nil,
                               help: speech.isRecording ? "Stop listening" : "Speak to Wanda",
                               action: onToggleMic)
                    iconButton("rectangle.expand.vertical", help: "Full view", action: onShowFullView)
                        .accessibilityIdentifier("fullViewButton")
                }
            }
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            // Logo that glows and moves with Wanda's voice.
            WandaOrb(voice: chat.voice, isListening: heard != nil, size: 28)
                .padding(.top, 2)
                .padding(.trailing, 4)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func iconButton(_ symbol: String, tint: Color? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "xmark" ? 9 : 11, weight: .bold))
                .foregroundStyle(tint ?? Color.primary.opacity(0.7))
                .frame(width: 22, height: 22)
                .frosted(in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private extension View {
    /// A frosted backing that keeps text and icons readable on any desktop: a system
    /// material (light or dark to match) with a faint outline.
    func frosted<S: InsettableShape>(in shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    func frostedPill() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frosted(in: Capsule())
    }
}
