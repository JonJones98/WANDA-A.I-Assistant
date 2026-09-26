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
        let manager = ServerManager(baseURL: url, serverDirectory: directory, pythonURL: venvPython)

        let started = await manager.ensureRunning()
        XCTAssertTrue(started)
        XCTAssertEqual(manager.status, .running)

        // A second manager (like a relaunched app) finds it running and doesn't own it.
        let other = ServerManager(baseURL: url, serverDirectory: directory, pythonURL: venvPython)
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

    func testConcurrentCallersLaunchOnce() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: venvPython.path), "server venv not set up")
        let directory = try makeServer(healthyServer)
        let manager = ServerManager(baseURL: URL(string: "http://127.0.0.1:8768")!, serverDirectory: directory, pythonURL: venvPython)
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
                                    pythonURL: venvPython, startupTimeout: .seconds(20))
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
            "play despacito", "continue the story", "Who is this?", "What's the weather?",
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
