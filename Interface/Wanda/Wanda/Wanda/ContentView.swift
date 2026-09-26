//
//  ContentView.swift
//  Wanda
//
//  Created by Jonathan Jones on 12/6/24.
//

import SwiftUI

struct ContentView: View {
    // Owned by `Assistant`, which keeps them running while the window is hidden.
    @ObservedObject private var viewModel: ChatViewModel
    @ObservedObject private var speech: SpeechRecognizer
    @ObservedObject private var wakeWord: WakeWordListener
    @State private var showsVoiceSettings = false

    private let bottomID = "bottom"

    init(assistant: Assistant) {
        viewModel = assistant.chat
        speech = assistant.speech
        wakeWord = assistant.wakeWord
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if speech.isRecording {
                ListeningPanel(transcript: speech.transcript)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            if let error = speech.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            ChatInputBar(
                text: $viewModel.draft,
                isRecording: speech.isRecording,
                canSend: viewModel.canSend,
                onToggleMic: { Task { await speech.toggle() } },
                onSend: send
            )
            .padding(10)
        }
        .frame(width: 400, height: 520)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("AppIcon")
            Text("Wanda")
                .font(.headline)
            ServerStatusDot(server: viewModel.server)
            if let problem = wakeWord.problem {
                Image(systemName: "mic.slash")
                    .foregroundStyle(.orange)
                    .help(problem)
                    .accessibilityLabel(problem)
            }
            Spacer()
            Button {
                showsVoiceSettings.toggle()
            } label: {
                Image(systemName: viewModel.readRepliesAloud ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .help("Voice settings")
            .accessibilityIdentifier("voiceSettingsButton")
            .popover(isPresented: $showsVoiceSettings, arrowEdge: .bottom) {
                VoiceSettingsView(
                    settings: viewModel.voiceSettings,
                    readRepliesAloud: $viewModel.readRepliesAloud,
                    wakeWordEnabled: $wakeWord.isEnabled,
                    onPreview: viewModel.previewVoice
                )
            }
            Button(action: viewModel.newChat) {
                Image(systemName: "square.and.pencil")
            }
            .disabled(viewModel.isWaiting)
            .help("New chat")
            Button {
                NSApp.keyWindow?.orderOut(nil)
            } label: {
                Image(systemName: "minus.circle")
            }
            .help("Hide Wanda (click the menu bar icon to bring it back)")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Wanda")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .help("Drag to move")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        if let date = message.date, showsTimestamp(at: index) {
                            Text(date, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        MessageBubble(message: message)
                    }
                    if viewModel.isWaiting {
                        TypingIndicator()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(12)
            }
            .onChange(of: viewModel.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.isWaiting) { _ in scrollToBottom(proxy) }
        }
    }

    private func send() {
        guard viewModel.canSend else { return }
        speech.cancel()
        viewModel.send()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    /// Show the time above the first message and after a gap of 5+ minutes.
    private func showsTimestamp(at index: Int) -> Bool {
        guard let date = viewModel.messages[index].date else { return false }
        guard index > 0, let previous = viewModel.messages[index - 1].date else { return true }
        return date.timeIntervalSince(previous) > 5 * 60
    }
}

/// Shows what Wanda is hearing. Dictation sends itself on a pause or a second mic tap.
private struct ListeningPanel: View {
    let transcript: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.red)
            Text(transcript.isEmpty ? "Listening… speak now" : transcript)
                .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("listeningPanel")
    }
}

/// Green when the server is running, yellow while it starts, red if it failed
/// (click to try again).
private struct ServerStatusDot: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        Button {
            Task { await server.ensureRunning() }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .buttonStyle(.plain)
        .disabled(server.status == .running || server.status == .starting)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("serverStatus")
    }

    private var color: Color {
        switch server.status {
        case .running: return .green
        case .starting, .unknown: return .yellow
        case .failed: return .red
        }
    }

    private var helpText: String {
        switch server.status {
        case .running: return "Server running"
        case .starting, .unknown: return "Starting server…"
        case .failed(let reason): return "Server not running. \(reason) Click to try again."
        }
    }
}

#Preview {
    ContentView(assistant: Assistant(server: ServerManager(), microphone: Microphone()))
}
