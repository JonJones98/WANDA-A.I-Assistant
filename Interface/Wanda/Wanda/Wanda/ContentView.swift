//
//  ContentView.swift
//  Wanda
//
//  Created by Jonathan Jones on 12/6/24.
//

import SwiftUI

struct ContentView: View {
    // Owned by `Assistant` and `AppDelegate`, which keep them running while the window is hidden.
    @ObservedObject private var viewModel: ChatViewModel
    @ObservedObject private var speech: SpeechRecognizer
    @ObservedObject private var wakeWord: WakeWordListener
    @ObservedObject private var headGestures: HeadGestureListener
    @ObservedObject private var layout: WindowLayout
    @State private var showsVoiceSettings = false

    private let bottomID = "bottom"

    init(assistant: Assistant, layout: WindowLayout) {
        viewModel = assistant.chat
        speech = assistant.speech
        wakeWord = assistant.wakeWord
        headGestures = assistant.headGestures
        self.layout = layout
    }

    var body: some View {
        Group {
            switch layout.mode {
            case .normal:
                normalView
            case .minimal:
                minimalView
            }
        }
        .background {
            // Esc stops the demo in either view, even with its bar hidden.
            if viewModel.demo != nil {
                Button("Stop demo", action: viewModel.endDemo)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Normal view

    private var normalView: some View {
        HStack(spacing: 0) {
            if layout.showsSidebar {
                ChatHistorySidebar(
                    store: viewModel.store,
                    currentID: viewModel.currentConversationID,
                    onSelect: viewModel.open,
                    onNewChat: viewModel.newChat,
                    onRename: viewModel.rename,
                    onDelete: viewModel.delete
                )
                .frame(width: WindowLayout.sidebarWidth)
                .transition(.move(edge: .leading))
                Divider()
            }
            chatColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let demo = viewModel.demo, viewModel.showsDemoBar {
                DemoBanner(demo: demo, onReplay: viewModel.startDemo, onStop: viewModel.endDemo,
                           onHide: { viewModel.showsDemoBar = false })
            }
            messageList
            if speech.isRecording || viewModel.demo?.transcript != nil {
                ListeningPanel(transcript: viewModel.demo?.transcript ?? speech.transcript)
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
        .frame(minWidth: WindowLayout.minimumChatSize.width, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { layout.showsSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(layout.showsSidebar ? "Hide chat history" : "Show chat history")
            .accessibilityIdentifier("sidebarButton")
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
                    nameOnlyWhenOpen: $wakeWord.nameOnlyWhenOpen,
                    nickname: $wakeWord.nickname,
                    headGestures: headGestures,
                    showsDemoBar: $viewModel.showsDemoBar,
                    onPreview: viewModel.previewVoice
                )
            }
            Button {
                layout.toggleExpanded()
            } label: {
                Image(systemName: layout.isExpanded
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(layout.isExpanded ? "Smaller window" : "Larger window")
            Button {
                layout.mode = .minimal
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .help("Minimal view")
            .accessibilityIdentifier("minimalModeButton")
            Button(action: viewModel.newChat) {
                Image(systemName: "square.and.pencil")
            }
            .help("New chat")
            Button(action: viewModel.startDemo) {
                Image(systemName: "play.circle")
            }
            .help("Play a demo conversation")
            .accessibilityIdentifier("demoButton")
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
        let messages = viewModel.displayMessages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let date = message.date, showsTimestamp(at: index, in: messages) {
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
            .onChange(of: viewModel.currentConversationID) { _ in
                // Jump (not scroll) to the end of a chat opened from the sidebar.
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    // MARK: Minimal view

    private var minimalView: some View {
        MinimalView(
            chat: viewModel,
            speech: speech,
            onClose: { NSApp.keyWindow?.orderOut(nil) },
            onToggleMic: { Task { await speech.toggle() } },
            onShowFullView: { layout.mode = .normal }
        )
        .frame(width: WindowLayout.minimalWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MinimalHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(MinimalHeightKey.self) { [layout] height in
            Task { @MainActor in layout.minimalHeight = max(56, height) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    private func showsTimestamp(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard let date = messages[index].date else { return false }
        guard index > 0, let previous = messages[index - 1].date else { return true }
        return date.timeIntervalSince(previous) > 5 * 60
    }
}

private struct MinimalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shows what Wanda is hearing. Dictation sends itself on a pause or a second mic tap.
/// Shown while the demo plays: progress, and a way out.
private struct DemoBanner: View {
    let demo: DemoState
    let onReplay: () -> Void
    let onStop: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(Color.accentColor)
            Text(demo.isFinished ? "Demo finished" : "Demo · \(demo.step) of \(demo.total)")
                .font(.callout.weight(.medium))
            Spacer()
            if demo.isFinished {
                Button("Replay", action: onReplay)
            }
            Button(demo.isFinished ? "Done" : "Stop demo", action: onStop)
                .accessibilityIdentifier("stopDemoButton")
            Button(action: onHide) {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .help("Hide this bar for screen recordings (Esc still stops the demo; turn it back on in Voice settings)")
            .accessibilityLabel("Hide demo bar")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }
}

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
    ContentView(assistant: Assistant(server: ServerManager(), microphone: Microphone()), layout: WindowLayout())
}
