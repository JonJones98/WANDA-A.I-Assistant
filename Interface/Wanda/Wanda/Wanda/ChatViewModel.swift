//
//  ChatViewModel.swift
//  Wanda
//

import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    private static let chatIDKey = "WandaChatID"
    private static let readAloudKey = "WandaReadRepliesAloud"
    private static let greeting = "Hello! How can I help you today?"

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isWaiting = false
    /// Read every reply aloud, not just replies to dictated messages.
    @Published var readRepliesAloud: Bool {
        didSet {
            defaults.set(readRepliesAloud, forKey: Self.readAloudKey)
            if !readRepliesAloud { voice.stop() }
        }
    }

    let voiceSettings: VoiceSettings
    let server: ServerManager
    private let api: WandaAPIClient
    private let voice: WandaVoice
    private let local = LocalAssistant()
    private let defaults: UserDefaults
    private var hasStarted = false

    /// Server-side conversation ID, kept across launches so history can be restored.
    private var chatID: String {
        get { defaults.string(forKey: Self.chatIDKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.chatIDKey) }
    }

    var canSend: Bool {
        !isWaiting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(server: ServerManager, api: WandaAPIClient = WandaAPIClient(), defaults: UserDefaults = .standard) {
        self.server = server
        self.api = api
        self.defaults = defaults
        self.readRepliesAloud = defaults.bool(forKey: Self.readAloudKey)
        self.voiceSettings = VoiceSettings(api: api, defaults: defaults)
        self.voice = WandaVoice(settings: voiceSettings, api: api)
    }

    func previewVoice() {
        voice.preview()
    }

    func stopSpeaking() {
        voice.stop()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        messages = [ChatMessage(text: Self.greeting, sender: .wanda)]

        // The server may still be starting; voices and history both come from it.
        let serverIsRunning = await server.ensureRunning()
        Task { await voiceSettings.loadVoices() }
        guard serverIsRunning else {
            if case .failed(let reason) = server.status {
                messages.append(ChatMessage(text: "I couldn't start my server. \(reason)", sender: .error))
            }
            return
        }

        if !chatID.isEmpty, let history = try? await api.history(chatID: chatID) {
            let restored: [ChatMessage] = history.compactMap { entry in
                switch entry.role {
                case "user": return ChatMessage(text: entry.content, sender: .user, date: nil)
                case "assistant": return ChatMessage(text: entry.content, sender: .wanda, date: nil)
                default: return nil
                }
            }
            if !restored.isEmpty, messages.count == 1 { messages = restored }
        }
    }

    func newChat() {
        voice.stop()
        chatID = ""
        messages = [ChatMessage(text: Self.greeting, sender: .wanda)]
    }

    /// Sends dictated text right away and reads the reply aloud. If a reply is still
    /// pending, the text is left in the input field instead so it isn't lost.
    func sendDictation(_ text: String) {
        draft = WakePhrase.strip(from: text)
        guard !isWaiting else { return }
        send(speakReply: true)
    }

    /// - Parameter speakReply: read Wanda's answer aloud even if `readRepliesAloud` is off.
    func send(speakReply: Bool = false) {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        voice.stop()
        messages.append(ChatMessage(text: text, sender: .user))
        isWaiting = true

        Task {
            defer { isWaiting = false }
            do {
                let (reply, isLocal) = try await reply(to: text)
                messages.append(ChatMessage(text: reply, sender: .wanda, isLocal: isLocal))
                if speakReply || readRepliesAloud { voice.speak(reply) }
            } catch {
                messages.append(ChatMessage(text: error.localizedDescription, sender: .error))
            }
        }
    }

    /// Answers on the Mac when possible (time, music, apps…); otherwise asks the server,
    /// sending a short description of what's happening on the Mac as context.
    private func reply(to text: String) async throws -> (text: String, isLocal: Bool) {
        if let answer = await local.answer(text) {
            return (answer, true)
        }
        // Restarts the server if it stopped since launch.
        guard await server.ensureRunning() else {
            if case .failed(let reason) = server.status { throw WandaAPIError.serverFailed(reason) }
            throw WandaAPIError.serverUnreachable
        }
        switch CommandParser.parse(text) {
        case .open(let app):
            return (try await api.runAppAction(.open, app: app), false)
        case .close(let app):
            return (try await api.runAppAction(.close, app: app), false)
        case .chat(let message):
            let reply = try await api.chat(message: message, chatID: chatID, context: await local.context())
            chatID = reply.chatID
            return (reply.response, false)
        }
    }
}
