//
//  ChatInputBar.swift
//  Wanda
//

import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let isRecording: Bool
    let canSend: Bool
    let onToggleMic: () -> Void
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMic) {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Stop listening" : "Speak to Wanda")
            .accessibilityIdentifier("micButton")

            TextField(isRecording ? "Listening…" : "Message Wanda", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onSend)
                .accessibilityIdentifier("messageField")

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .onAppear { isFocused = true }
    }
}
