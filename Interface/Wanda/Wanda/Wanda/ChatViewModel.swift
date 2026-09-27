//
//  ChatViewModel.swift
//  Wanda
//

import AppKit

@MainActor
final class ChatViewModel: ObservableObject {
    private static let lastConversationKey = "WandaLastConversation"
    private static let readAloudKey = "WandaReadRepliesAloud"
    private static let showsDemoBarKey = "WandaShowsDemoBar"
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

    /// Set while the demo conversation plays (see `startDemo`).
    @Published private(set) var demo: DemoState?
    /// Show the demo's status bar (and stop button). Off for screen recordings; Esc still
    /// stops the demo.
    @Published var showsDemoBar: Bool {
        didSet { defaults.set(showsDemoBar, forKey: Self.showsDemoBarKey) }
    }

    let voiceSettings: VoiceSettings
    let server: ServerManager
    let store: ChatStore
    private let api: WandaAPIClient
    let voice: WandaVoice
    private let local = LocalAssistant()
    private let defaults: UserDefaults
    private var hasStarted = false
    private var demoTask: Task<Void, Never>?
    private var conversationBeforeDemo: UUID?
    /// Apps the demo opened (for arranging), the music player among them, and whether the
    /// demo started the music (paused when the demo ends).
    private var demoApps: [NSRunningApplication] = []
    private var demoPlayer: MediaPlayer?
    private var demoStartedMusic = false
    private var wasMinimalBeforeDemo = false

    /// Switches the window between the mini (true) and full (false) views.
    var showMinimalView: ((Bool) -> Void)?
    /// Whether the window is in the mini view.
    var isMinimalView: (() -> Bool)?

    /// What the chat shows: a greeting until the conversation has started.
    var displayMessages: [ChatMessage] {
        messages.contains { $0.sender != .error } ? messages : [Self.greeting] + messages
    }

    /// True while the open chat is waiting for its reply (shows the typing indicator).
    var isWaiting: Bool {
        pendingConversationID != nil && pendingConversationID == currentConversationID
    }

    var canSend: Bool {
        (pendingConversationID == nil || demo != nil) && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        self.showsDemoBar = defaults.object(forKey: Self.showsDemoBarKey) as? Bool ?? true
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
        endDemo(restoringChat: false)
        voice.stop()
        currentConversationID = id
        messages = conversation.messages
        defaults.set(id.uuidString, forKey: Self.lastConversationKey)
    }

    func newChat() {
        endDemo(restoringChat: false)
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
        if DemoScript.isRequest(text) {
            startDemo()
            return
        }
        // Typing during the demo ends it and sends in the chat that was open before.
        endDemo()
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

    // MARK: Demo

    /// Plays `DemoScript` in a temporary chat that isn't saved: "Hey Wanda", the words
    /// appearing as they're "heard", the typing indicator, and replies read aloud.
    func startDemo() {
        guard demo == nil || demo?.isFinished == true else { return }
        endDemo()
        voice.stop()
        conversationBeforeDemo = currentConversationID
        wasMinimalBeforeDemo = isMinimalView?() ?? false
        currentConversationID = UUID()
        messages = []
        demo = DemoState(total: DemoScript.steps.count)
        demoTask = Task { await runDemo() }
    }

    /// Stops the demo and goes back to the chat that was open before it.
    func endDemo() {
        endDemo(restoringChat: true)
    }

    private func endDemo(restoringChat: Bool) {
        guard demo != nil else { return }
        demoTask?.cancel()
        demoTask = nil
        demo = nil
        pendingConversationID = nil
        voice.stop()
        if demoStartedMusic, let player = demoPlayer {
            Task { _ = await player.send(.pause) }
        }
        demoPlayer = nil
        demoStartedMusic = false
        demoApps = []
        let previous = conversationBeforeDemo
        conversationBeforeDemo = nil
        guard restoringChat else { return }
        showMinimalView?(wasMinimalBeforeDemo)
        if let previous, store.conversation(previous) != nil {
            open(previous)
        } else {
            newChat()
        }
    }

    private func runDemo() async {
        for (index, step) in DemoScript.steps.enumerated() {
            demo?.step = index + 1
            guard await pause(index == 0 ? 0.6 : 1.0) else { return }

            // "Hey Wanda" (chime), then the question appears word by word as it's "heard".
            let spoken = (step.wakes ? "Hey Wanda, " : "") + step.said
            if step.wakes { NSSound(named: "Tink")?.play() }
            demo?.transcript = ""
            guard await pause(0.4) else { return }
            var heard: [Substring] = []
            for word in spoken.split(separator: " ") {
                heard.append(word)
                demo?.transcript = heard.joined(separator: " ")
                guard await pause(0.22) else { return }
            }
            guard await pause(0.5) else { return }
            demo?.transcript = nil

            // Wanda thinks, answers and reads the answer aloud.
            messages.append(ChatMessage(text: step.said, sender: .user))
            pendingConversationID = currentConversationID
            let started = Date()
            let reply: (text: String, isLocal: Bool)
            if let action = step.action {
                reply = await perform(action)
            } else {
                reply = await demoReply(step)
            }
            guard await pause(max(0, 0.9 - Date().timeIntervalSince(started))) else { return }
            pendingConversationID = nil
            messages.append(ChatMessage(text: reply.text, sender: .wanda, isLocal: reply.isLocal))
            voice.speak(reply.text)
            let giveUp = Date().addingTimeInterval(60)
            while voice.isSpeaking, Date() < giveUp {
                guard await pause(0.15) else { return }
            }
            guard await pause(step.pauseAfter) else { return }
        }
        demo?.isFinished = true
    }

    /// Does a demo action; the answer is AI-style (isLocal false) for the storage advice
    /// and the trip plan.
    private func perform(_ action: DemoScript.Action) async -> (text: String, isLocal: Bool) {
        switch action {
        case .storageAdvice:
            guard let disk = LocalAssistant.diskUsage() else { return ("I couldn't read the disk space.", true) }
            return (DemoScript.storageAdvice(free: disk.free, total: disk.total), false)
        case .planTrip:
            return (await planTrip(), false)
        default:
            return (await performOnMac(action), true)
        }
    }

    private func performOnMac(_ action: DemoScript.Action) async -> String {
        switch action {
        case .minimalView:
            showMinimalView?(true)
            return "Here's the mini view."
        case .fullView:
            showMinimalView?(false)
            return "Here's the full view."
        case .openApps(let names):
            let urls = names.compactMap(WindowArranger.findApp)
            guard !urls.isEmpty else { return "I couldn't find those apps." }
            let apps = await WindowArranger.open(urls)
            NSApp.activate(ignoringOtherApps: true)
            demoApps = apps
            demoPlayer = MediaPlayer.all.first { player in apps.contains { $0.bundleIdentifier == player.bundleID } }
            return "Opened \(ListFormatter.localizedString(byJoining: apps.compactMap(\.localizedName)))."
        case .arrangeApps:
            guard WindowArranger.isAllowed else {
                WindowArranger.requestPermission()
                return "To arrange windows, allow Wanda in System Settings → Privacy & Security → Accessibility."
            }
            let count = WindowArranger.arrange(demoApps)
            return count == 0 ? "I couldn't move those windows." : "Done. Your \(count) windows now fit the screen."
        case .playMusic:
            guard let player = demoPlayer ?? MediaPlayer.running().first else {
                return "Spotify isn't open."
            }
            if await player.nowPlaying()?.isPlaying == true {
                return "\(player.name) is already playing."
            }
            guard await player.startPlaying() else {
                return await MediaPlayer.lacksPermission(player)
                    ? MediaPlayer.permissionHint(player)
                    : "\(player.name) didn't start playing."
            }
            demoStartedMusic = true
            return "Playing \(player.name)."
        case .planTrip, .storageAdvice:
            return ""   // handled in perform(_:)
        case .tidyUp(let minimize, let close):
            var done: [String] = []
            for name in minimize {
                guard let app = WindowArranger.running(named: name) else { continue }
                WindowArranger.minimize(app)
                done.append("minimized \(app.localizedName ?? name)")
            }
            let quitting = close.compactMap(WindowArranger.running(named:))
            quitting.forEach { $0.terminate() }
            let giveUp = Date().addingTimeInterval(5)
            while quitting.contains(where: { !$0.isTerminated }), Date() < giveUp {
                guard await pause(0.2) else { break }
            }
            demoApps.removeAll { $0.isTerminated }
            if !quitting.isEmpty {
                done.append("closed " + ListFormatter.localizedString(byJoining: quitting.compactMap(\.localizedName)))
            }
            NSApp.activate(ignoringOtherApps: true)
            guard !done.isEmpty else { return "Nothing to tidy up." }
            let sentence = done.joined(separator: " and ")
            return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
        case .saveItinerary:
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let saved: DocumentSaver.SavedDocument
            do {
                saved = try DocumentSaver.save(DemoScript.itinerary, name: DemoScript.itineraryFileName, in: desktop)
            } catch {
                return "I couldn't save the itinerary to your Desktop."
            }
            if let textEdit = WindowArranger.running(named: "TextEdit") {
                textEdit.terminate()
                let giveUp = Date().addingTimeInterval(4)
                while !textEdit.isTerminated, Date() < giveUp {
                    guard await pause(0.2) else { break }
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            return "Saved “\(saved.url.lastPathComponent)” to your Desktop and closed it."
        }
    }

    /// Searches the destination in Safari, pins it in Maps, drafts the itinerary in
    /// TextEdit, then fits Safari, Maps, TextEdit and Spotify on screen.
    private func planTrip() async -> String {
        let place = DemoScript.tripDestination
        let workspace = NSWorkspace.shared
        let background = NSWorkspace.OpenConfiguration()
        background.activates = false

        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: "\(place) travel guide")]
        if let safari = WindowArranger.findApp("Safari"), let url = search.url {
            workspace.open([url], withApplicationAt: safari, configuration: background, completionHandler: nil)
        }
        var maps = URLComponents(string: "maps://")!
        maps.queryItems = [URLQueryItem(name: "q", value: place)]
        if let url = maps.url { workspace.open(url) }

        // The draft lives in a temporary folder until "save it to my Desktop".
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("Wanda Demo")
        try? FileManager.default.removeItem(at: drafts)
        if let draft = try? DocumentSaver.save(DemoScript.itinerary, name: DemoScript.itineraryFileName, in: drafts) {
            DocumentSaver.open(draft.url, activates: false)
        }

        // Wait for Safari, Maps and TextEdit, then lay them out with Spotify (if open).
        let needed = ["Safari", "Maps", "TextEdit"]
        let giveUp = Date().addingTimeInterval(8)
        repeat {
            guard await pause(0.4) else { return "" }
        } while needed.contains(where: { WindowArranger.running(named: $0) == nil }) && Date() < giveUp
        guard await pause(1) else { return "" }
        let apps = (needed + ["Spotify"]).compactMap(WindowArranger.running(named:))
        for app in apps where !demoApps.contains(app) { demoApps.append(app) }
        let arranged = WindowArranger.arrange(apps) > 0
        NSApp.activate(ignoringOtherApps: true)
        return """
        I searched \(place) in Safari, pinned it in Maps and drafted a two-day itinerary\(arranged ? ", with your windows laid out side by side" : "").
        Day 1: Alfama, São Jorge Castle, Tram 28 and a fado dinner.
        Day 2: Belém's monastery, tower and custard tarts, then LX Factory and Time Out Market.
        """
    }

    private func demoReply(_ step: DemoScript.Step) async -> (text: String, isLocal: Bool) {
        if let reply = step.reply { return (reply, false) }
        if let answer = await local.answer(step.said), !answer.hasPrefix("I couldn't") {
            return (answer, true)
        }
        return (step.fallback ?? "Sorry, I couldn't get that right now.", true)
    }

    /// Waits, returning false if the demo was stopped meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
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
        if let minimal = ViewCommand.parse(text), let showMinimalView {
            showMinimalView(minimal)
            return (minimal ? "Here's the mini view." : "Here's the full view.", true)
        }
        let document = DocumentRequest.parse(text)
        if document == .saveLastReply {
            return (saveLastReply(), true)
        }
        if document == nil, let answer = await local.answer(text) {
            return (answer, true)
        }
        // Restarts the server if it stopped since launch.
        guard await server.ensureRunning() else {
            if case .failed(let reason) = server.status { throw WandaAPIError.serverFailed(reason) }
            throw WandaAPIError.serverUnreachable
        }
        if case .write(let request) = document {
            return (try await writeDocument(request, in: conversationID), false)
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

    // MARK: Documents

    /// Has the AI write the document (in this chat, so "summarize our conversation"
    /// works), then saves it to Documents and opens it.
    private func writeDocument(_ request: String, in conversationID: UUID) async throws -> String {
        let serverChatID = store.conversation(conversationID)?.serverChatID ?? ""
        let reply = try await api.chat(
            message: DocumentRequest.prompt(for: request), chatID: serverChatID, context: await local.context()
        )
        if reply.chatID != serverChatID, var conversation = store.conversation(conversationID) {
            conversation.serverChatID = reply.chatID
            store.save(conversation)
        }
        do {
            let saved = try DocumentSaver.save(reply.response)
            DocumentSaver.open(saved.url)
            return "I wrote “\(saved.title)” and saved it to Documents as “\(saved.url.lastPathComponent)”."
        } catch {
            return "I wrote it, but couldn't save it to Documents: \(error.localizedDescription)\n\n\(reply.response)"
        }
    }

    /// Saves Wanda's last answer in this chat as a document.
    private func saveLastReply() -> String {
        // The newest message is the request itself; look before it.
        guard let last = messages.dropLast().last(where: { $0.sender == .wanda }) else {
            return "There's no answer to save yet. Ask me something first."
        }
        do {
            let saved = try DocumentSaver.save(last.text)
            DocumentSaver.open(saved.url)
            return "Saved it to Documents as “\(saved.url.lastPathComponent)”."
        } catch {
            return "I couldn't save it to Documents: \(error.localizedDescription)"
        }
    }
}
