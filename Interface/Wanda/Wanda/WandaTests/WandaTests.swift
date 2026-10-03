//
//  WandaTests.swift
//  WandaTests
//
//  Created by Jonathan Jones on 12/6/24.
//

import XCTest
@testable import Wanda

final class CommandParserTests: XCTestCase {
    func testOpenIsCaseInsensitiveAndKeepsAppName() {
        XCTAssertEqual(CommandParser.parse("Open Safari"), .open(app: "Safari"))
        XCTAssertEqual(CommandParser.parse("open visual studio code"), .open(app: "visual studio code"))
    }

    func testCloseAndQuit() {
        XCTAssertEqual(CommandParser.parse("close Spotify"), .close(app: "Spotify"))
        XCTAssertEqual(CommandParser.parse("Quit Spotify"), .close(app: "Spotify"))
    }

    func testCommandWordLaterInSentenceIsChat() {
        let text = "can you help me open up about stress"
        XCTAssertEqual(CommandParser.parse(text), .chat(text))
    }

    func testCommandWordAloneIsChat() {
        XCTAssertEqual(CommandParser.parse("open"), .chat("open"))
    }

    func testWordStartingWithCommandIsChat() {
        XCTAssertEqual(CommandParser.parse("opener ideas please"), .chat("opener ideas please"))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(CommandParser.parse("  open   Safari  "), .open(app: "Safari"))
    }
}

final class WandaAPIClientTests: XCTestCase {
    private let client = WandaAPIClient()

    func testAppRequestEncodesSpacesAndSpecialCharacters() {
        let url = client.appRequest(.open, app: "Tom & Jerry+Friends").url!
        XCTAssertEqual(url.path, "/open")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items, [URLQueryItem(name: "app", value: "Tom & Jerry+Friends")])
        XCTAssertTrue(url.absoluteString.contains("%26"))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testChatRequestIsJSONPost() throws {
        let request = try client.chatRequest(message: "Tom & Jerry = 1+1?", chatID: "abc")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/genAI/chat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
        XCTAssertEqual(body, ["user_input": "Tom & Jerry = 1+1?", "chat_id": "abc", "context": ""])
    }

    func testUnreachableServerThrowsFriendlyError() async {
        // Port 9 (discard) is closed on a normal Mac, so the connection is refused.
        let offline = WandaAPIClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        do {
            _ = try await offline.chat(message: "hi", chatID: "")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? WandaAPIError, .serverUnreachable)
        }
    }
}

@MainActor
final class VoiceSettingsTests: XCTestCase {
    /// Points at a closed port so tests never depend on a running Wanda server.
    private let offlineAPI = WandaAPIClient(baseURL: URL(string: "http://127.0.0.1:9")!)

    private func option(_ name: String, _ quality: VoiceOption.Quality, _ language: String = "en-US") -> VoiceOption {
        VoiceOption(id: "\(name)-\(language)", name: name, language: language, quality: quality)
    }

    private func kokoro(_ id: String, recommended: Bool, language: String = "en-us") -> VoiceOption {
        VoiceOption(kokoro: KokoroVoice(id: id, name: id, language: language, languageName: "English",
                                        gender: "female", recommended: recommended))
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testPreferredPicksBestUSEnglishVoice() {
        let voices = [
            option("Samantha", .standard),
            option("Zoe", .premium),
            option("Ava", .enhanced),
            option("Amélie", .premium, "fr-CA"),
        ]
        XCTAssertEqual(VoiceOption.preferred(from: voices)?.name, "Zoe")
    }

    func testPreferredBreaksTiesTowardAva() {
        let voices = [option("Zoe", .premium), option("Ava (Premium)", .premium)]
        XCTAssertEqual(VoiceOption.preferred(from: voices)?.name, "Ava (Premium)")
    }

    func testPreferredFallsBackToAnyLanguage() {
        let voices = [option("Amélie", .standard, "fr-CA")]
        XCTAssertEqual(VoiceOption.preferred(from: voices)?.name, "Amélie")
    }

    func testPreferredDefaultsToNova() {
        let voices = [option("Zoe", .premium), kokoro("af_heart", recommended: true), kokoro("af_nova", recommended: false)]
        XCTAssertEqual(VoiceOption.preferred(from: voices)?.id, "kokoro:af_nova")
    }

    func testPreferredFallsBackToRecommendedKokoroVoiceWithoutNova() {
        let voices = [option("Zoe", .premium), kokoro("af_sky", recommended: false), kokoro("af_heart", recommended: true)]
        XCTAssertEqual(VoiceOption.preferred(from: voices)?.id, "kokoro:af_heart")
    }

    func testKokoroName() {
        XCTAssertEqual(VoiceOption.kokoroName(from: "kokoro:af_heart"), "af_heart")
        XCTAssertNil(VoiceOption.kokoroName(from: "com.apple.voice.premium.en-US.Zoe"))
        XCTAssertNil(VoiceOption.kokoroName(from: nil))
    }

    func testSettingsPersist() {
        let defaults = freshDefaults("VoiceSettingsTests")
        let settings = VoiceSettings(api: offlineAPI, defaults: defaults)
        settings.choose("kokoro:bf_emma")
        settings.rate = 0.6
        settings.pitch = 1.2

        let reloaded = VoiceSettings(api: offlineAPI, defaults: defaults)
        XCTAssertEqual(reloaded.voiceID, "kokoro:bf_emma")
        XCTAssertEqual(reloaded.kokoroVoiceName, "bf_emma")
        XCTAssertEqual(reloaded.rate, 0.6)
        XCTAssertEqual(reloaded.kokoroSpeed, 1.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.pitch, 1.2)

        reloaded.resetSpeedAndPitch()
        XCTAssertEqual(reloaded.rate, 0.5)
        XCTAssertEqual(reloaded.kokoroSpeed, 1.0)
        XCTAssertEqual(reloaded.pitch, 1.0)
    }

    func testLoadVoicesReplacesMissingVoiceWhenServerIsDown() async {
        let settings = VoiceSettings(api: offlineAPI, defaults: freshDefaults("VoiceSettingsLoad"))
        settings.choose("kokoro:af_heart")
        await settings.loadVoices()
        XCTAssertTrue(settings.kokoroUnavailable)
        if settings.appleVoicesTimedOut {
            XCTAssertEqual(settings.voices, [])
        } else {
            XCTAssertNotNil(settings.selectedVoice, "a voice that isn't available should be replaced")
            XCTAssertEqual(settings.selectedVoice?.engine, .apple)
        }
    }

    func testAppleTimeoutReportsInsteadOfHanging() async {
        let settings = VoiceSettings(api: offlineAPI, defaults: freshDefaults("VoiceLoadTimeout"))
        let start = Date()
        await settings.loadVoices(appleTimeout: .zero)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertNotNil(settings.voices)
    }
}

final class SpeechTextTests: XCTestCase {
    func testCleanRemovesMarkdown() {
        let text = "**Sure!** Here's how:\n- Open *Safari*\n- Visit [Apple](https://apple.com)\n## Done\nUse `git status`."
        XCTAssertEqual(SpeechText.clean(text), "Sure! Here's how: Open Safari. Visit Apple. Done. Use git status.")
    }

    func testCleanKeepsUnderscoresInWords() {
        XCTAssertEqual(SpeechText.clean("Rename file_name.txt"), "Rename file_name.txt")
    }

    func testSentencesJoinShortOnes() {
        let chunks = SpeechText.sentences("Sure! TCP guarantees delivery and ordering. UDP is faster but doesn't. Hope that helps!")
        XCTAssertEqual(chunks, [
            "Sure! TCP guarantees delivery and ordering.",
            "UDP is faster but doesn't.",
            "Hope that helps!",
        ])
    }

    func testSentencesOfShortText() {
        XCTAssertEqual(SpeechText.sentences("Opening Safari"), ["Opening Safari"])
    }

    func testSpeechRequestBody() throws {
        let request = try WandaAPIClient().speechRequest(text: "Hi & bye", voice: "af_heart", speed: 1.2)
        XCTAssertEqual(request.url?.path, "/tts/speak")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["text"] as? String, "Hi & bye")
        XCTAssertEqual(body["voice"] as? String, "af_heart")
        XCTAssertEqual((body["speed"] as? Double) ?? 0, 1.2, accuracy: 0.001)
    }
}

@MainActor
final class ServerManagerTests: XCTestCase {
    /// The real server's virtualenv Python, so fake servers can import FastAPI and uvicorn.
    /// Built without resolving symlinks: `wandaenv/bin/python` is a symlink, and following
    /// it would run the system Python outside the virtualenv.
    private let venvPython = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WandaTests
        .deletingLastPathComponent()   // wanda
        .deletingLastPathComponent()   // Wanda
        .deletingLastPathComponent()   // Interface
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("server/wandaenv/bin/python")

    /// Tests log here so they never overwrite the real server log.
    private let testLog = FileManager.default.temporaryDirectory.appendingPathComponent("wanda-test-server.log")

    private func makeServer(_ mainPy: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanda-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try mainPy.write(to: directory.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private let healthyServer = """
    from fastapi import FastAPI
    app = FastAPI()
    @app.get("/")
    def root():
        return {"message": "Welcome to Wanda Voice AI Assistant!"}
    """

    func testStartsServerReusesItAndStopsIt() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let directory = try makeServer(healthyServer)
        let url = URL(string: "http://127.0.0.1:8767")!
        let manager = ServerManager(baseURL: url, serverDirectory: directory, pythonURL: venvPython, logURL: testLog)

        let started = await manager.ensureRunning()
        XCTAssertTrue(started)
        XCTAssertEqual(manager.status, .running)

        // A second manager (like a relaunched app) finds it running and doesn't own it.
        let other = ServerManager(baseURL: url, serverDirectory: directory, pythonURL: venvPython, logURL: testLog)
        let reused = await other.ensureRunning()
        XCTAssertTrue(reused)
        other.stopIfLaunched()
        let stillUp = await manager.isHealthy()
        XCTAssertTrue(stillUp, "a server Wanda didn't start must be left running")

        manager.stopIfLaunched()
        try await Task.sleep(for: .seconds(1))
        let afterStop = await manager.isHealthy()
        XCTAssertFalse(afterStop)
    }

    private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testQuitStopsServerWandaDidNotStart() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let directory = try makeServer(healthyServer)
        let url = URL(string: "http://127.0.0.1:8771")!
        let starter = ServerManager(baseURL: url, serverDirectory: directory, pythonURL: venvPython, logURL: testLog)
        let started = await starter.ensureRunning()
        XCTAssertTrue(started)

        // A fresh Wanda (e.g. after a relaunch) didn't start it, but quitting stops it anyway.
        let wanda = ServerManager(baseURL: url, serverDirectory: directory, pythonURL: venvPython, logURL: testLog)
        XCTAssertFalse(ServerManager.serverProcessIDs(port: 8771, directory: directory).isEmpty)
        wanda.stopServer()
        let stillUp = await wanda.isHealthy()
        XCTAssertFalse(stillUp)
        XCTAssertTrue(ServerManager.serverProcessIDs(port: 8771, directory: directory).isEmpty)
    }

    func testQuitLeavesOtherFoldersServersAlone() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let otherProject = try makeServer(healthyServer)
        let url = URL(string: "http://127.0.0.1:8772")!
        let other = ServerManager(baseURL: url, serverDirectory: otherProject, pythonURL: venvPython, logURL: testLog)
        let started = await other.ensureRunning()
        XCTAssertTrue(started)

        let wandaFolder = try makeServer(healthyServer)
        ServerManager(baseURL: url, serverDirectory: wandaFolder, pythonURL: venvPython, logURL: testLog).stopServer()
        let stillUp = await other.isHealthy()
        XCTAssertTrue(stillUp, "a server from another folder must not be stopped")
        other.stopServer()
    }

    func testQuitStopsReloadModeServerAndWatcher() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let directory = try makeServer(healthyServer)
        // Started like `uvicorn main:app --reload` in Terminal.
        let terminal = Process()
        terminal.executableURL = venvPython
        terminal.arguments = ["-m", "uvicorn", "main:app", "--reload", "--port", "8773"]
        terminal.currentDirectoryURL = directory
        terminal.standardOutput = FileHandle.nullDevice
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        let wanda = ServerManager(baseURL: URL(string: "http://127.0.0.1:8773")!, serverDirectory: directory, pythonURL: venvPython, logURL: testLog)
        for _ in 0..<100 {
            if await wanda.isHealthy() { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let pids = ServerManager.serverProcessIDs(port: 8773, directory: directory)
        XCTAssertTrue(pids.contains(terminal.processIdentifier), "the --reload watcher is included: \(pids)")

        wanda.stopServer()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(terminal.isRunning, "the watcher is stopped, so it can't restart the server")
        let stillUp = await wanda.isHealthy()
        XCTAssertFalse(stillUp)
    }

    func testConcurrentCallersLaunchOnce() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let directory = try makeServer(healthyServer)
        let manager = ServerManager(baseURL: URL(string: "http://127.0.0.1:8768")!, serverDirectory: directory, pythonURL: venvPython, logURL: testLog)
        async let first = manager.ensureRunning()
        async let second = manager.ensureRunning()
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        manager.stopIfLaunched()
    }

    func testReportsServerThatCrashesOnStartup() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let directory = try makeServer("raise SystemExit('bad config')")
        let manager = ServerManager(baseURL: URL(string: "http://127.0.0.1:8769")!, serverDirectory: directory,
                                    pythonURL: venvPython, startupTimeout: .seconds(20), logURL: testLog)
        let start = Date()
        let started = await manager.ensureRunning()
        XCTAssertFalse(started)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "a crash should be noticed without waiting for the timeout")
        guard case .failed(let reason) = manager.status else { return XCTFail("expected failure, got \(manager.status)") }
        XCTAssertTrue(reason.contains("stopped while starting"), reason)
    }

    func testReportsMissingServerFolder() async {
        let manager = ServerManager(baseURL: URL(string: "http://127.0.0.1:8770")!,
                                    serverDirectory: URL(fileURLWithPath: "/nonexistent/server"))
        let started = await manager.ensureRunning()
        XCTAssertFalse(started)
        guard case .failed(let reason) = manager.status else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("No server found"), reason)
    }

    func testBuildFillsInServerFolder() {
        let directory = ServerManager.configuredServerDirectory
        XCTAssertEqual(directory?.lastPathComponent, "server")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory?.appendingPathComponent("main.py").path ?? ""))
    }
}

final class WakePhraseTests: XCTestCase {
    func testMatchesGreetings() {
        for phrase in ["Hey Wanda", "hi wanda", "Hi, Wanda!", "okay wanda open safari", "so I said hey Wander", "Hello Wanda"] {
            XCTAssertTrue(WakePhrase.matches(phrase), phrase)
        }
    }

    func testIgnoresOtherSpeech() {
        for phrase in ["Wanda", "I wonder", "hey there", "wandering around", "hey wandering minds", "Rwanda is a country"] {
            XCTAssertFalse(WakePhrase.matches(phrase), phrase)
        }
    }
}

final class LocalIntentTests: XCTestCase {
    private func assertIntent(_ expected: LocalIntent?, _ phrases: [String], file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            XCTAssertEqual(LocalIntentParser.parse(phrase), expected, "\"\(phrase)\"", file: file, line: line)
        }
    }

    func testTools() {
        assertIntent(.tools, ["list tools", "List tool", "Hey Wanda, show me your tools", "what tools do you have",
                              "what can you do?", "list commands", "What are your capabilities?", "help"])
        assertIntent(nil, ["help me write an email", "what tools do I need to fix a bike"])
    }

    func testTime() {
        assertIntent(.time, ["What time is it?", "what's the time", "Hey Wanda, what time is it right now?",
                             "Can you tell me the time please", "do you know what time it is", "current time"])
    }

    func testDate() {
        assertIntent(.date, ["What's today's date?", "what day is it", "what is the date today", "What day of the week is it?"])
    }

    func testNowPlaying() {
        assertIntent(.nowPlaying, [
            "What is the name of the song playing on Spotify?", "what song is this", "What's playing?",
            "what am I listening to", "Which song is playing right now", "who is singing this song", "what's this song",
        ])
    }

    func testMediaControls() {
        assertIntent(.media(.pause), ["pause", "Pause the music", "stop spotify"])
        assertIntent(.media(.play), ["play", "resume the music", "Play Spotify"])
        assertIntent(.media(.next), ["next song", "skip", "Skip this track", "play the next song"])
        assertIntent(.media(.previous), ["previous song", "go back a song", "play the previous track"])
    }

    func testAppsDiskAndVolume() {
        assertIntent(.activeApp, ["What app am I using?", "which application is active"])
        assertIntent(.openApps, ["What apps are open?", "which applications are running"])
        assertIntent(.diskSpace, ["How much disk space do I have left?", "how much storage is left", "free disk space"])
        assertIntent(.volume, ["what's the volume"])
        assertIntent(.setVolume(40), ["Set the volume to 40%", "volume 40 percent", "turn volume to 40"])
        assertIntent(.setVolume(100), ["set volume to 250"])
        assertIntent(.changeVolume(by: 10), ["turn it up", "volume up"])
        assertIntent(.changeVolume(by: -10), ["turn the volume down", "quieter"])
        assertIntent(.mute(true), ["mute"])
        assertIntent(.mute(false), ["unmute the sound"])
    }

    /// Questions that sound local but need more than the Mac knows go to the AI.
    func testDetailedQuestionsGoToAI() {
        assertIntent(nil, [
            "What time is it in Tokyo?", "what time does the store close", "How long until Christmas?",
            "What does this song mean?", "Tell me about the artist of this song", "What are the lyrics to this song?",
            "play despacito", "continue the story", "Who is this?",
            "explain what time dilation is", "open Safari",
        ])
    }

    func testWakePhraseIsStrippedFromDictation() {
        XCTAssertEqual(WakePhrase.strip(from: "Hey Wanda, what time is it?"), "what time is it?")
        XCTAssertEqual(WakePhrase.strip(from: "hi wanda open safari"), "open safari")
        XCTAssertEqual(WakePhrase.strip(from: "what did Wanda say"), "what did Wanda say")
    }
}

@MainActor
final class LocalAssistantTests: XCTestCase {
    func testAnswersWithoutTheAI() async {
        let local = LocalAssistant()
        let time = await local.answer("what time is it")
        XCTAssertTrue(time?.hasPrefix("It's ") ?? false, time ?? "nil")
        let date = await local.answer("what's today's date")
        XCTAssertTrue(date?.contains(String(Calendar.current.component(.year, from: Date()))) ?? false, date ?? "nil")
        let disk = await local.answer("how much disk space do I have left")
        XCTAssertTrue(disk?.contains("free of") ?? false, disk ?? "nil")
        let apps = await local.answer("what apps are open")
        XCTAssertNotNil(apps)
        let ai = await local.answer("what time is it in Tokyo")
        XCTAssertNil(ai)
        let tools = await local.answer("list tools") ?? ""
        XCTAssertTrue(tools.hasPrefix("Here’s what I can do on your Mac without AI:"), tools)
        XCTAssertEqual(tools.components(separatedBy: "\n• ").count - 1, LocalAssistant.tools.count)
    }

    func testReadsVolumeWithoutChangingIt() async {
        let before = await SystemVolume.get()
        XCTAssertNotNil(before)
        let answer = await LocalAssistant().answer("what's the volume")
        XCTAssertTrue(answer?.contains("\(before?.level ?? -1)%") ?? false, answer ?? "nil")
    }

    func testContextDescribesTheMac() async {
        let context = await LocalAssistant().context()
        XCTAssertTrue(context.hasPrefix("Local time: "), context)
    }
}

@MainActor
final class ChatStoreTests: XCTestCase {
    private func tempStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wanda-chats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func conversation(_ title: String, updated: Date = Date()) -> Conversation {
        Conversation(id: UUID(), title: title, messages: [ChatMessage(text: title, sender: .user)],
                     serverChatID: "", createdAt: updated, updatedAt: updated)
    }

    func testSavesAndReloadsNewestFirst() {
        let url = tempStoreURL()
        let store = ChatStore(fileURL: url)
        let older = conversation("older", updated: Date(timeIntervalSinceNow: -3600))
        let newer = conversation("newer")
        store.save(older)
        store.save(newer)
        XCTAssertEqual(store.conversations.map(\.title), ["newer", "older"])

        let reloaded = ChatStore(fileURL: url)
        XCTAssertEqual(reloaded.conversations.map(\.title), ["newer", "older"])
        XCTAssertEqual(reloaded.conversation(older.id)?.messages.first?.text, "older")
    }

    func testRenameAndDeletePersist() {
        let url = tempStoreURL()
        let store = ChatStore(fileURL: url)
        let first = conversation("first")
        let second = conversation("second")
        store.save(first)
        store.save(second)
        store.rename(first.id, to: "  Trip ideas  ")
        store.rename(second.id, to: "   ")   // blank names are ignored
        store.delete(second.id)

        let reloaded = ChatStore(fileURL: url)
        XCTAssertEqual(reloaded.conversations.map(\.title), ["Trip ideas"])
    }

    func testTitleComesFromFirstUserMessage() {
        let messages = [
            ChatMessage(text: "Hello! How can I help?", sender: .wanda),
            ChatMessage(text: "What is the best way\nto learn Swift concurrency quickly?", sender: .user),
        ]
        XCTAssertEqual(Conversation.title(from: messages), "What is the best way to learn Swift conc…")
        XCTAssertEqual(Conversation.title(from: []), "New chat")
        XCTAssertEqual(Conversation.title(from: [ChatMessage(text: "Hey Wanda, what time is it?", sender: .user)]), "what time is it?")
    }
}

@MainActor
final class ChatHistoryFlowTests: XCTestCase {
    private func makeViewModel() -> (ChatViewModel, ChatStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wanda-flow-\(UUID().uuidString).json")
        let suite = "ChatHistoryFlow-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let store = ChatStore(fileURL: url)
        let offline = ServerManager(baseURL: URL(string: "http://127.0.0.1:9")!, serverDirectory: nil)
        let model = ChatViewModel(server: offline, api: WandaAPIClient(baseURL: URL(string: "http://127.0.0.1:9")!),
                                  store: store, defaults: UserDefaults(suiteName: suite)!)
        return (model, store)
    }

    private func send(_ text: String, with model: ChatViewModel) async {
        model.draft = text
        model.send()
        for _ in 0..<100 where model.pendingConversationID != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testMessagesAreSavedOpenedAndDeleted() async {
        let (model, store) = makeViewModel()
        XCTAssertEqual(model.displayMessages, [ChatViewModel.greeting])

        await send("what time is it", with: model)
        let firstID = try! XCTUnwrap(model.currentConversationID)
        XCTAssertEqual(store.conversation(firstID)?.title, "what time is it")
        XCTAssertEqual(store.conversation(firstID)?.messages.map(\.sender), [.user, .wanda])
        XCTAssertTrue(store.conversation(firstID)?.messages.last?.isLocal ?? false)

        model.newChat()
        XCTAssertNil(model.currentConversationID)
        XCTAssertEqual(model.displayMessages, [ChatViewModel.greeting])
        await send("what's today's date", with: model)
        let secondID = try! XCTUnwrap(model.currentConversationID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(store.conversations.map(\.id), [secondID, firstID])

        model.open(firstID)
        XCTAssertEqual(model.messages.first?.text, "what time is it")

        model.rename(firstID, to: "Clock")
        XCTAssertEqual(store.conversation(firstID)?.title, "Clock")

        model.delete(firstID)
        XCTAssertNil(store.conversation(firstID))
        XCTAssertNil(model.currentConversationID, "deleting the open chat starts a new one")
        XCTAssertEqual(store.conversations.map(\.id), [secondID])
    }
}

@MainActor
final class WindowLayoutTests: XCTestCase {
    func testSizesAndPersistence() {
        let suite = "WindowLayoutTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let layout = WindowLayout(defaults: defaults)
        XCTAssertEqual(layout.mode, .normal)
        XCTAssertEqual(layout.contentSize, WindowLayout.standardSize)

        layout.showsSidebar = true
        XCTAssertEqual(layout.contentSize.width, WindowLayout.standardSize.width + WindowLayout.sidebarWidth)
        layout.toggleExpanded()
        XCTAssertTrue(layout.isExpanded)
        XCTAssertEqual(layout.contentSize.height, WindowLayout.largeSize.height)

        layout.mode = .minimal
        layout.minimalHeight = 150
        XCTAssertEqual(layout.contentSize, CGSize(width: WindowLayout.minimalWidth, height: 150))

        let reloaded = WindowLayout(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .minimal)
        XCTAssertTrue(reloaded.showsSidebar)
        XCTAssertTrue(reloaded.isExpanded)
        reloaded.toggleExpanded()
        XCTAssertEqual(reloaded.chatSize, WindowLayout.standardSize)
    }
}

final class ReplyFormattingTests: XCTestCase {
    private let example = #"""
    The **formula** is:

    \[
    A = \pi r^2
    \]

    where:

    - \( A \) = area
    - \( \pi \) ≈ 3.14159

    \[
    A = \pi \times 5^2 = \pi \times 25 \approx 78.54 \text{ units}^2
    \]
    """#

    func testDisplayTurnsLatexAndMarkdownIntoReadableText() {
        let display = String(ReplyFormatter.display(example).characters)
        XCTAssertTrue(display.contains("A = πr²"), display)
        XCTAssertTrue(display.contains("• A = area"), display)
        XCTAssertTrue(display.contains("• π ≈ 3.14159"), display)
        XCTAssertTrue(display.contains("A = π × 5² = π × 25 ≈ 78.54 units²"), display)
        XCTAssertFalse(display.contains("\\"), display)
        XCTAssertFalse(display.contains("**"), display)
    }

    func testDisplayKeepsBold() {
        let attributed = ReplyFormatter.display("The **formula** is")
        let bold = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
        }
        XCTAssertTrue(bold)
    }

    func testSpeechReadsMathAsWords() {
        let spoken = SpeechText.clean(example)
        XCTAssertTrue(spoken.contains("A equals pi r squared"), spoken)
        XCTAssertTrue(spoken.contains("pi is approximately 3.14159"), spoken)
        XCTAssertTrue(spoken.contains("pi times 5 squared equals pi times 25 is approximately 78.54 units squared"), spoken)
        for symbol in ["\\", "{", "^", "*", "•", "π", "²"] {
            XCTAssertFalse(spoken.contains(symbol), "\(symbol) in: \(spoken)")
        }
    }

    func testMoreMath() {
        let text = #"\( \frac{a+b}{2} \), \( \sqrt{x^2 + 1} \), \( x^{10} \), \( 90^\circ \) and it costs $5"#
        XCTAssertEqual(String(ReplyFormatter.display(text).characters), "(a+b)/2, √(x² + 1), x¹⁰, 90° and it costs $5")
        XCTAssertEqual(SpeechText.clean(text),
                       "a plus b over 2, the square root of x squared plus 1, x to the power of 10, 90 degrees and it costs $5")
    }

    func testPlainUnicodeMathIsSpoken() {
        XCTAssertEqual(SpeechText.clean("A = πr², about 78.5 cm²"), "A equals pi r squared, about 78.5 cm squared")
    }
}

final class NameOnlyWakeTests: XCTestCase {
    private let phrase = WakePhrase(nickname: "Jarvis, Jay-Z")

    func testNicknamesAreCleanedUp() {
        XCTAssertEqual(phrase.nicknames, ["jarvis", "jay z"])
        XCTAssertEqual(WakePhrase(nickname: " , wanda, ").nicknames, [])
        XCTAssertTrue(phrase.contextualStrings.contains("Hey Jarvis"))
    }

    func testGreetingAlwaysWorksForNicknames() {
        for text in ["Hey Jarvis", "hi jarvis what time is it", "Hey Jay Z", "Hey Wanda"] {
            XCTAssertTrue(phrase.matches(text), text)
            XCTAssertTrue(phrase.matches(text, nameOnly: true), text)
        }
    }

    func testBareNameOnlyWhenWindowIsOpen() {
        for text in ["Wanda", "Wanda what time is it", "ok so Wanda open Safari", "Jarvis", "jay z"] {
            XCTAssertFalse(phrase.matches(text), "window hidden: \(text)")
            XCTAssertTrue(phrase.matches(text, nameOnly: true), "window open: \(text)")
        }
    }

    func testSoundAlikesNeedAGreeting() {
        for text in ["I wonder", "let's wander around", "Rwanda is a country", "wandering", "jarvisson"] {
            XCTAssertFalse(phrase.matches(text, nameOnly: true), text)
        }
        XCTAssertTrue(phrase.matches("hey wander", nameOnly: true), "misheard name after a greeting")
    }

    func testStripsNameFromRequest() {
        XCTAssertEqual(phrase.strip(from: "Wanda, what time is it?"), "what time is it?")
        XCTAssertEqual(phrase.strip(from: "Jarvis open Safari"), "open Safari")
        XCTAssertEqual(phrase.strip(from: "Hey Jay Z, play music"), "play music")
        XCTAssertEqual(phrase.strip(from: "wander around the city"), "wander around the city")
        XCTAssertEqual(phrase.strip(from: "what did Wanda say"), "what did Wanda say")
    }

    @MainActor
    func testSettingsPersist() {
        let suite = "NameOnlyWakeTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let listener = WakeWordListener(microphone: Microphone(), defaults: defaults)
        listener.isEnabled = false   // don't open the mic in tests
        XCTAssertTrue(listener.nameOnlyWhenOpen)
        XCTAssertEqual(listener.nickname, "")
        listener.nameOnlyWhenOpen = false
        listener.nickname = "Jarvis"
        let reloaded = WakeWordListener(microphone: Microphone(), defaults: defaults)
        XCTAssertFalse(reloaded.nameOnlyWhenOpen)
        XCTAssertEqual(reloaded.phrase.nicknames, ["jarvis"])
    }
}


@MainActor
final class WakeListenerConcurrencyTests: XCTestCase {
    /// Regression: starting the wake word listener (especially with no microphone
    /// connected) used to corrupt Swift concurrency, so every later `await` hung and
    /// Wanda stopped answering even local questions.
    func testStartingTheListenerDoesNotBreakAsyncWork() async throws {
        let suite = "WakeListenerConcurrencyTests"
        UserDefaults().removePersistentDomain(forName: suite)
        let listener = WakeWordListener(microphone: Microphone(), defaults: UserDefaults(suiteName: suite)!)
        listener.resume()
        try await Task.sleep(for: .seconds(1))
        let answer = await LocalAssistant().answer("what time is it")
        XCTAssertNotNil(answer)
        listener.pause()
        try await Task.sleep(for: .seconds(1.2))   // let the mic's idle stop run
    }
}

final class HeadGestureDetectorTests: XCTestCase {
    /// Feeds angles at 50 Hz and returns how many gestures were detected.
    private func triggers(_ angles: [Double], _ detector: HeadGestureDetector = .nod) -> Int {
        var detector = detector
        return angles.enumerated().filter { detector.add($0.element, at: Double($0.offset) / 50) }.count
    }

    private func rest(_ seconds: Double, at angle: Double = 0) -> [Double] {
        Array(repeating: angle, count: Int(seconds * 50))
    }

    /// Out to `size` radians and back over `seconds`.
    private func swing(_ size: Double = -0.3, _ seconds: Double = 0.4) -> [Double] {
        let count = Int(seconds * 50)
        return (0..<count).map { size * sin(Double($0) / Double(count) * .pi) }
    }

    func testDoubleNodTriggers() {
        XCTAssertEqual(triggers(rest(1) + swing() + rest(0.2) + swing() + rest(1)), 1)
    }

    func testSingleNodDoesNot() {
        XCTAssertEqual(triggers(rest(1) + swing() + rest(2)), 0)
    }

    func testNodsFarApartDoNot() {
        XCTAssertEqual(triggers(rest(1) + swing() + rest(2) + swing() + rest(1)), 0)
    }

    func testLookingDownAndBackDoesNot() {
        // Look down at the keyboard for a few seconds, then back up, twice.
        let lookDown = rest(1) + rest(3, at: -0.4) + rest(3)
        XCTAssertEqual(triggers(lookDown + lookDown), 0)
    }

    func testSlowHeadMovementDoesNot() {
        XCTAssertEqual(triggers(rest(1) + swing(-0.3, 1.5) + swing(-0.3, 1.5) + rest(1)), 0)
    }

    func testCooldownAfterTrigger() {
        let double = swing() + rest(0.2) + swing()
        XCTAssertEqual(triggers(rest(1) + double + rest(0.2) + double + rest(1)), 1)
    }

    func testShakeLeftThenRightTriggers() {
        let shake = swing(0.4, 0.35) + swing(-0.4, 0.35)
        XCTAssertEqual(triggers(rest(1) + shake + rest(1), .shake), 1)
    }

    func testTurningToAnotherScreenDoesNot() {
        // Look at a second screen for a while, then back, twice.
        let glance = rest(1) + rest(3, at: 0.6) + rest(3)
        XCTAssertEqual(triggers(glance + glance, .shake), 0)
    }

    func testDoubleTiltTriggers() {
        let tilt = swing(0.35, 0.5)
        XCTAssertEqual(triggers(rest(1) + tilt + rest(0.2) + tilt + rest(1), .tilt), 1)
    }

    func testSavedEitherMeansAnyGesture() {
        XCTAssertEqual(HeadGestureListener.Gesture(rawValue: "either"), .any)
    }

    func testSmallHeadMovementsDoNotShake() {
        let fidget = swing(0.15, 0.3) + swing(-0.15, 0.3)
        XCTAssertEqual(triggers(rest(1) + fidget + fidget + rest(1), .shake), 0)
    }
}

final class WakeModeTests: XCTestCase {
    func testModeFromSettings() {
        XCTAssertEqual(WakeMode(wakeWordEnabled: true, gesturesEnabled: false, gesture: .nod), .voice)
        XCTAssertEqual(WakeMode(wakeWordEnabled: false, gesturesEnabled: false, gesture: .nod), .off)
        XCTAssertEqual(WakeMode(wakeWordEnabled: false, gesturesEnabled: true, gesture: .shake), .shake)
        XCTAssertEqual(WakeMode(wakeWordEnabled: true, gesturesEnabled: true, gesture: .any), .anyGesture)
    }

    func testEveryModeRoundTrips() {
        for mode in WakeMode.allCases {
            let restored = WakeMode(wakeWordEnabled: mode == .voice,
                                    gesturesEnabled: mode.gesture != nil,
                                    gesture: mode.gesture ?? .any)
            XCTAssertEqual(restored, mode)
        }
    }
}

final class WeatherTests: XCTestCase {
    private func assertWeather(_ expected: WeatherQuery?, _ phrases: [String], file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            let intent = LocalIntentParser.parse(phrase)
            XCTAssertEqual(intent, expected.map(LocalIntent.weather), "\"\(phrase)\"", file: file, line: line)
        }
    }

    func testCurrentWeatherHere() {
        assertWeather(WeatherQuery(), [
            "What's the weather?", "Hey Wanda, what's the weather like outside", "weather",
            "how's the weather right now", "what is the weather like", "weather forecast",
        ])
    }

    func testDays() {
        assertWeather(WeatherQuery(day: .today), ["what's the weather today", "today's weather", "forecast for today"])
        assertWeather(WeatherQuery(day: .tomorrow), ["What's the weather going to be like tomorrow?", "forecast for tomorrow", "tomorrow's weather"])
        assertWeather(WeatherQuery(day: .week), ["what's the forecast this week", "weather for the week", "what's the weather for the next few days"])
    }

    func testPlaces() {
        assertWeather(WeatherQuery(place: "chicago"), ["what's the weather in Chicago", "Weather in Chicago?"])
        assertWeather(WeatherQuery(day: .tomorrow, place: "new york"), [
            "what's the weather tomorrow in New York", "What's the weather in New York tomorrow",
        ])
        assertWeather(WeatherQuery(), ["what's the weather here", "weather in my area"])
    }

    func testRainSnowAndTemperature() {
        assertWeather(WeatherQuery(day: .tomorrow, focus: .rain), ["Will it rain tomorrow?", "is it going to rain tomorrow", "do I need an umbrella tomorrow"])
        assertWeather(WeatherQuery(focus: .rain), ["is it going to rain", "chance of rain"])
        assertWeather(WeatherQuery(day: .week, focus: .rain, place: "seattle"), ["will it rain this week in Seattle"])
        assertWeather(WeatherQuery(day: .today, focus: .snow), ["is it going to snow today"])
        assertWeather(WeatherQuery(focus: .temperature), ["what's the temperature outside", "how cold is it outside", "how hot is it"])
    }

    func testNotWeather() {
        assertWeather(nil, ["what's the weather like on Mars in the book", "how does weather affect mood",
                            "write a poem about rain", "what is the temperature of the sun"])
    }

    private let sample = """
    {"current":{"temperature_2m":71.6,"apparent_temperature":75.2,"weather_code":2,"wind_speed_10m":8,"is_day":1},
     "daily":{"time":["2026-09-26","2026-09-27","2026-09-28"],"weather_code":[2,61,0],
              "temperature_2m_max":[78.4,70.1,80],"temperature_2m_min":[60.2,55,58],
              "precipitation_probability_max":[10,80,null],"snowfall_sum":[0,0,0]}}
    """

    private func answer(_ query: WeatherQuery) throws -> String {
        let forecast = try JSONDecoder().decode(Forecast.self, from: Data(sample.utf8))
        return WeatherFormatter.answer(query, place: "Chicago", isHere: true, forecast: forecast)
    }

    func testAnswers() throws {
        XCTAssertEqual(try answer(WeatherQuery()),
                       "Right now in Chicago it's 72° and partly cloudy, feeling like 75°. Today: partly cloudy, high of 78°, low of 60°.")
        XCTAssertEqual(try answer(WeatherQuery(day: .tomorrow)),
                       "Tomorrow in Chicago: light rain, high of 70°, low of 55°, 80% chance of rain.")
        XCTAssertEqual(try answer(WeatherQuery(day: .tomorrow, focus: .rain)),
                       "Yes, probably. There's a 80% chance of rain tomorrow in Chicago.")
        XCTAssertEqual(try answer(WeatherQuery(day: .week, focus: .rain)), "Rain is likely in Chicago tomorrow.")
        XCTAssertTrue(try answer(WeatherQuery(day: .week)).hasPrefix("This week in Chicago:\nToday: partly cloudy, high 78°, low 60°\nTomorrow: light rain"))
    }

    func testDegreesAreSpoken() {
        XCTAssertEqual(SpeechText.clean("It's 72° and sunny, high of 78°F."), "It's 72 degrees and sunny, high of 78 degrees.")
    }
}

final class DemoTests: XCTestCase {
    func testDemoRequests() {
        for phrase in ["start demo", "Demo", "demo mode", "Hey Wanda, show me a demo", "run the demo please"] {
            XCTAssertTrue(DemoScript.isRequest(phrase), phrase)
        }
        for phrase in ["demo of how photosynthesis works", "what is a demo", "start the music"] {
            XCTAssertFalse(DemoScript.isRequest(phrase), phrase)
        }
    }

    /// Steps answered on the Mac must really be local questions, or the demo would show a
    /// fallback instead of a live answer.
    func testLocalStepsAreLocalQuestions() {
        for step in DemoScript.steps where step.reply == nil && step.action == nil {
            XCTAssertNotNil(LocalIntentParser.parse(step.said), step.said)
        }
    }

    /// The built-in apps the demo uses must be found by name.
    func testDemoAppsAreFound() {
        for name in ["Safari", "Maps", "TextEdit"] {
            XCTAssertNotNil(WindowArranger.findApp(name), name)
        }
    }

    /// Safari runs from a hidden system volume, so running apps must be matched by bundle
    /// ID, not by the /Applications path (otherwise the demo never closed Safari).
    func testAppsAreIdentifiedByBundleID() throws {
        let safari = try XCTUnwrap(WindowArranger.findApp("Safari"))
        XCTAssertEqual(Bundle(url: safari)?.bundleIdentifier, "com.apple.Safari")
    }

    func testStorageAdviceDependsOnFreeSpace() {
        let gb: Int64 = 1_000_000_000
        let low = DemoScript.storageAdvice(free: 20 * gb, total: 500 * gb)
        XCTAssertTrue(low.contains("about 4% of your disk"), low)
        XCTAssertTrue(low.contains("very low"), low)
        XCTAssertTrue(DemoScript.storageAdvice(free: 200 * gb, total: 500 * gb).contains("good shape"))
    }
}

final class ViewCommandTests: XCTestCase {
    func testViewCommands() {
        for phrase in ["Switch to mini view", "Hey Wanda, switch to mini view.", "mini mode", "minimal view", "go to the compact view"] {
            XCTAssertEqual(ViewCommand.parse(phrase), true, phrase)
        }
        for phrase in ["full view", "switch back to the full view", "normal mode", "show the chat window"] {
            XCTAssertEqual(ViewCommand.parse(phrase), false, phrase)
        }
        for phrase in ["what is a mini cooper", "chat", "full", "tell me about the view from Everest"] {
            XCTAssertNil(ViewCommand.parse(phrase), phrase)
        }
    }
}

final class WindowArrangerTests: XCTestCase {
    func testOpenSeveralApps() {
        XCTAssertEqual(LocalIntentParser.parse("Open Safari, Notes and Spotify"), .openAndArrange(["safari", "notes", "spotify"]))
        XCTAssertEqual(LocalIntentParser.parse("Hey Wanda, open Safari and Notes side by side."), .openAndArrange(["safari", "notes"]))
        XCTAssertEqual(LocalIntentParser.parse("launch visual studio code & terminal and arrange them"),
                       .openAndArrange(["visual studio code", "terminal"]))
        XCTAssertEqual(LocalIntentParser.parse("can you open mail, calendar, and the notes app"),
                       .openAndArrange(["mail", "calendar", "the notes app"]))
    }

    func testOneAppIsNotArranged() {
        XCTAssertNil(LocalIntentParser.appsToOpen("open Safari"))
        XCTAssertNil(LocalIntentParser.appsToOpen("what apps are open"))
    }

    func testArrangePhrases() {
        for phrase in ["arrange my windows", "Organize my windows", "tile the windows", "tidy up my screen",
                       "put my windows side by side", "fit my windows on the screen", "make my windows fit the screen"] {
            XCTAssertEqual(LocalIntentParser.parse(phrase), .arrangeWindows, phrase)
        }
        XCTAssertNil(LocalIntentParser.parse("how do I organize my closet"))
    }

    func testFindsInstalledApps() {
        XCTAssertNotNil(WindowArranger.findApp("safari"))
        XCTAssertNotNil(WindowArranger.findApp("the notes app"))
        XCTAssertNotNil(WindowArranger.findApp("Settings"))
        XCTAssertNil(WindowArranger.findApp("play jazz"))
    }

    func testLayouts() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let two = WindowArranger.layout(count: 2, in: screen, gap: 0)
        XCTAssertEqual(two, [CGRect(x: 0, y: 0, width: 500, height: 600), CGRect(x: 500, y: 0, width: 500, height: 600)])

        let three = WindowArranger.layout(count: 3, in: screen, gap: 0)
        XCTAssertEqual(three[0], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(three[1], CGRect(x: 500, y: 300, width: 500, height: 300))   // top right
        XCTAssertEqual(three[2], CGRect(x: 500, y: 0, width: 500, height: 300))     // bottom right

        // 5 windows: 3 on top, 2 stretched across the bottom; nothing overlaps or leaves the screen.
        let five = WindowArranger.layout(count: 5, in: screen, gap: 8)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(five[3].width, five[4].width, accuracy: 0.01)
        XCTAssertGreaterThan(five[3].width, five[0].width)
        for (i, a) in five.enumerated() {
            XCTAssertTrue(screen.contains(a), "\(a)")
            for b in five[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) \(b)") }
        }
    }
}

final class DocumentTests: XCTestCase {
    func testWriteRequests() {
        for phrase in ["Create a 3-day itinerary for Tokyo and save it to Documents",
                       "write a packing list for a beach trip and save it",
                       "Hey Wanda, make a document about our meeting notes",
                       "draft a cover letter and save it in my documents folder",
                       "create a new file with my grocery list"] {
            XCTAssertEqual(DocumentRequest.parse(phrase), .write(phrase), phrase)
        }
    }

    func testSaveLastReply() {
        for phrase in ["save that to Documents", "Save this", "save your last answer as a document", "save it to my documents"] {
            XCTAssertEqual(DocumentRequest.parse(phrase), .saveLastReply, phrase)
        }
    }

    func testOrdinaryRequestsAreNotDocuments() {
        for phrase in ["write a poem about rain", "make me laugh", "create a workout plan",
                       "how do I save money", "what's the weather"] {
            XCTAssertNil(DocumentRequest.parse(phrase), phrase)
        }
    }

    func testPlainText() {
        let text = "# Tokyo Trip\n\n## Day 1\n- **Senso-ji** temple\n* [Guide](https://example.com)\nArea: \\(\\pi r^2\\)"
        XCTAssertEqual(DocumentSaver.plainText(text),
                       "Tokyo Trip\n\nDAY 1\n• Senso-ji temple\n• Guide (https://example.com)\nArea: πr²".replacingOccurrences(of: "Tokyo Trip", with: "TOKYO TRIP"))
    }

    func testTitlesAndFileNames() {
        XCTAssertEqual(DocumentSaver.title(of: "Title: Beach Packing List\n• Sunscreen"), "Beach Packing List")
        XCTAssertEqual(DocumentSaver.fileName("Q&A: Plans / Ideas?"), "Q&A- Plans - Ideas")
    }

    func testSaveNeverReplacesAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try DocumentSaver.save("Packing List\n• Hat", in: folder)
        let second = try DocumentSaver.save("Packing List\n• Towel", in: folder)
        XCTAssertEqual(first.url.lastPathComponent, "Packing List.txt")
        XCTAssertEqual(second.url.lastPathComponent, "Packing List 2.txt")
        XCTAssertEqual(try String(contentsOf: first.url), "Packing List\n• Hat\n")
    }
}

final class CalendarTests: XCTestCase {
    func testScheduleQuestions() {
        for phrase in ["Do I have anything scheduled today?", "Hey Wanda, what's on my calendar today",
                       "what do I have today", "What does my day look like?", "what meetings do I have today",
                       "check my calendar"] {
            XCTAssertEqual(LocalIntentParser.parse(phrase), .schedule(tomorrow: false), phrase)
        }
        for phrase in ["what's on my calendar tomorrow", "do I have any meetings tomorrow"] {
            XCTAssertEqual(LocalIntentParser.parse(phrase), .schedule(tomorrow: true), phrase)
        }
        for phrase in ["how do I schedule a meeting", "what is a calendar year"] {
            XCTAssertNil(LocalIntentParser.parse(phrase), phrase)
        }
    }

    func testSummary() {
        let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let items = [CalendarService.Item(title: "Birthday", start: nine, isAllDay: true),
                     CalendarService.Item(title: "Standup", start: nine, isAllDay: false)]
        XCTAssertEqual(CalendarService.summary([], day: "today"), "Your calendar is clear today.")
        XCTAssertEqual(CalendarService.summary(items, day: "today"),
                       "You have 2 things today: Birthday (all day) and Standup at \(nine.formatted(date: .omitted, time: .shortened)).")
    }

    func testNextShowingIsAfterSixAndAhead() {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let showing = DemoScript.nextShowing(after: noon)
        XCTAssertTrue(calendar.isDate(showing, inSameDayAs: noon))
        XCTAssertEqual(calendar.component(.hour, from: showing), 18)

        // At 8:30 PM the 6:45 show has started, so the 9:30 PM one is picked.
        let evening = calendar.date(bySettingHour: 20, minute: 30, second: 0, of: Date())!
        XCTAssertEqual(calendar.component(.hour, from: DemoScript.nextShowing(after: evening)), 21)

        // Too late for either: tomorrow's first show.
        let late = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        XCTAssertTrue(calendar.isDate(DemoScript.nextShowing(after: late),
                                      inSameDayAs: calendar.date(byAdding: .day, value: 1, to: late)!))
    }
}

final class MorningRoutineTests: XCTestCase {
    func testMorningRoutinePhrases() {
        for phrase in ["Run my morning routine.", "Hey Wanda, run morning routine", "good morning",
                       "Good morning Wanda!", "morning briefing", "start my day"] {
            XCTAssertEqual(LocalIntentParser.parse(phrase), .morningRoutine, phrase)
        }
        XCTAssertNil(LocalIntentParser.parse("what is a good morning routine for runners"))
    }

    func testYesterdayRecap() {
        XCTAssertEqual(LocalAssistant.yesterdayRecap(events: [], completed: []),
                       "Yesterday was quiet: nothing on your calendar.")
        XCTAssertEqual(LocalAssistant.yesterdayRecap(events: ["Standup", "Dentist"], completed: ["Buy milk"]),
                       "Yesterday you had Standup and Dentist, and finished one reminder.")
        XCTAssertEqual(LocalAssistant.yesterdayRecap(events: [], completed: ["A", "B"]),
                       "Yesterday you finished 2 reminders.")
    }

    func testCodingAnswerIsSpokenWithoutCode() throws {
        let step = try XCTUnwrap(DemoScript.steps.first { $0.said.contains("conditionals") })
        XCTAssertTrue(step.reply?.contains("elif temperature") == true)
        XCTAssertFalse(step.spoken?.contains("temperature") ?? true)
    }
}
