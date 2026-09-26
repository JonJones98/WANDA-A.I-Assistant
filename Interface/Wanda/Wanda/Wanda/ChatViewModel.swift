//
//  ChatViewModel.swift
//  Wanda
//

import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    private static let lastConversationKey = "WandaLastConversation"
    private static let readAloudKey = "WandaReadRepliesAloud"
    static let greeting = ChatMessage(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        text: "Hello! How can I help you today?", sender: .wanda, date: nil
    )

    /// The open chat's messages (errors included; they aren't saved).
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var currentConversationID: UUID?
    @Published var draft = ""
    /// The chat waiting for a reply, if any. One request runs at a time.
    @Published private(set) var pendingConversationID: UUID?
    /// Read every reply aloud, not just replies to dictated messages.
    @Published var readRepliesAloud: Bool {
        didSet {
            defaults.set(readRepliesAloud, forKey: Self.readAloudKey)
            if !readRepliesAloud { voice.stop() }
        }
    }

    let voiceSettings: VoiceSettings
    let server: ServerManager
    let store: ChatStore
    private let api: WandaAPIClient
    let voice: WandaVoice
    private let local = LocalAssistant()
    private let defaults: UserDefaults
    private var hasStarted = false

    /// What the chat shows: a greeting until the conversation has started.
    var displayMessages: [ChatMessage] {
        messages.contains { $0.sender != .error } ? messages : [Self.greeting] + messages
    }

    /// True while the open chat is waiting for its reply (shows the typing indicator).
    var isWaiting: Bool {
        pendingConversationID != nil && pendingConversationID == currentConversationID
    }

    var canSend: Bool {
        pendingConversationID == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        server: ServerManager, api: WandaAPIClient = WandaAPIClient(),
        store: ChatStore? = nil, defaults: UserDefaults = .standard
    ) {
        self.server = server
        self.api = api
        self.store = store ?? ChatStore()
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

    /// Reopens the last chat, then makes sure the server is up and loads voices.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let last = defaults.string(forKey: Self.lastConversationKey).flatMap(UUID.init(uuidString:)),
           store.conversation(last) != nil {
            open(last)
        }

        let serverIsRunning = await server.ensureRunning()
        Task { await voiceSettings.loadVoices() }
        if !serverIsRunning, case .failed(let reason) = server.status {
            messages.append(ChatMessage(text: "I couldn't start my server. \(reason)", sender: .error))
        }
    }

    // MARK: Chats

    func open(_ id: UUID) {
        guard let conversation = store.conversation(id) else { return }
        voice.stop()
        currentConversationID = id
        messages = conversation.messages
        defaults.set(id.uuidString, forKey: Self.lastConversationKey)
    }

    func newChat() {
        voice.stop()
        currentConversationID = nil
        messages = []
        defaults.removeObject(forKey: Self.lastConversationKey)
    }

    func rename(_ id: UUID, to title: String) {
        store.rename(id, to: title)
    }

    func delete(_ id: UUID) {
        let serverChatID = store.conversation(id)?.serverChatID ?? ""
        store.delete(id)
        if currentConversationID == id { newChat() }
        // Also remove the server's copy; failures don't matter (it may be offline).
        if !serverChatID.isEmpty {
            Task { [api] in try? await api.deleteHistory(chatID: serverChatID) }
        }
    }

    // MARK: Sending

    /// Sends dictated text (wake phrase already removed) right away and reads the reply
    /// aloud. If a reply is still pending, the text is left in the input field instead so
    /// it isn't lost.
    func sendDictation(_ text: String) {
        draft = text
        guard pendingConversationID == nil else { return }
        send(speakReply: true)
    }

    /// - Parameter speakReply: read Wanda's answer aloud even if `readRepliesAloud` is off.
    func send(speakReply: Bool = false) {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        voice.stop()

        let conversationID = currentConversationID ?? UUID()
        if currentConversationID == nil {
            currentConversationID = conversationID
            defaults.set(conversationID.uuidString, forKey: Self.lastConversationKey)
        }
        append(ChatMessage(text: text, sender: .user), to: conversationID)
        pendingConversationID = conversationID

        Task {
            defer { pendingConversationID = nil }
            do {
                let reply = try await reply(to: text, in: conversationID)
                append(ChatMessage(text: reply.text, sender: .wanda, isLocal: reply.isLocal), to: conversationID)
                if conversationID == currentConversationID, speakReply || readRepliesAloud {
                    voice.speak(reply.text)
                }
            } catch {
                // Errors are shown but not saved, and only if that chat is still open.
                if conversationID == currentConversationID {
                    messages.append(ChatMessage(text: error.localizedDescription, sender: .error))
                }
            }
        }
    }

    /// Adds a message to a chat and saves it. The chat may no longer be the one on screen
    /// if the user switched while waiting for a reply.
    private func append(_ message: ChatMessage, to conversationID: UUID) {
        if conversationID == currentConversationID {
            messages.append(message)
        }
        let now = Date()
        var conversation = store.conversation(conversationID)
            ?? Conversation(id: conversationID, title: "", messages: [], serverChatID: "", createdAt: now, updatedAt: now)
        conversation.messages.append(message)
        if conversation.title.isEmpty {
            conversation.title = Conversation.title(from: conversation.messages)
        }
        conversation.updatedAt = now
        store.save(conversation)
    }

    /// Answers on the Mac when possible (time, music, apps…); otherwise asks the server,
    /// sending a short description of what's happening on the Mac as context.
    private func reply(to text: String, in conversationID: UUID) async throws -> (text: String, isLocal: Bool) {
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
            let serverChatID = store.conversation(conversationID)?.serverChatID ?? ""
            let reply = try await api.chat(message: message, chatID: serverChatID, context: await local.context())
            if reply.chatID != serverChatID, var conversation = store.conversation(conversationID) {
                conversation.serverChatID = reply.chatID
                store.save(conversation)
            }
            return (reply.response, false)
        }
    }
}
