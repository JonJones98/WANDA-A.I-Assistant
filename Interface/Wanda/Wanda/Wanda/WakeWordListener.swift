//
//  WakeWordListener.swift
//  Wanda
//

import AVFoundation
import Speech

/// Listens in the background for "Hey Wanda" / "Hi Wanda" using on-device speech
/// recognition (audio never leaves the Mac). On a match it stops listening, bumps
/// `wakeCount` and calls `onWake`; the caller starts dictation and calls `resume()`
/// when it's done. Audio comes from the shared `Microphone`, which stays on during the
/// handoff to dictation.
@MainActor
final class WakeWordListener: ObservableObject {
    private static let enabledKey = "WandaWakeWordEnabled"
    private static let nameOnlyKey = "WandaWakeNameOnlyWhenOpen"
    private static let nicknameKey = "WandaWakeNickname"

    /// Incremented on every detection, so views can react with `onChange`.
    @Published private(set) var wakeCount = 0
    @Published private(set) var isListening = false
    /// Why listening can't start right now (e.g. no microphone connected), or nil.
    @Published private(set) var problem: String?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? startIfAllowed() : stop()
        }
    }

    /// With the window open, the bare name ("Wanda" or a nickname) is enough.
    @Published var nameOnlyWhenOpen: Bool {
        didSet { defaults.set(nameOnlyWhenOpen, forKey: Self.nameOnlyKey) }
    }
    /// Extra names Wanda answers to; several can be separated by commas.
    @Published var nickname: String {
        didSet { defaults.set(nickname, forKey: Self.nicknameKey) }
    }

    var phrase: WakePhrase { WakePhrase(nickname: nickname) }

    var onWake: (() -> Void)?
    /// When true, the bare name isn't enough (e.g. while Wanda is speaking, so her own
    /// "I'm Wanda" through the speakers can't wake her).
    var requiresGreeting: () -> Bool = { false }
    private(set) var isWindowVisible = false

    /// Recognition restarts this often so the transcript being searched stays short.
    private let restartInterval: Duration = .seconds(45)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let defaults: UserDefaults
    private let microphone: Microphone
    private let requestBox = RequestBox()
    private var micToken: Microphone.Token?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Task<Void, Never>?
    private var session = 0
    private var isPaused = false

    init(microphone: Microphone, defaults: UserDefaults = .standard) {
        self.microphone = microphone
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        nameOnlyWhenOpen = defaults.object(forKey: Self.nameOnlyKey) as? Bool ?? true
        nickname = defaults.string(forKey: Self.nicknameKey) ?? ""
    }

    /// Starts (or restarts) listening if enabled, e.g. when dictation is done with the mic.
    func resume() {
        isPaused = false
        startIfAllowed()
    }

    /// Stops listening until `resume()`, e.g. while dictation is using the mic.
    func pause() {
        isPaused = true
        stop()
    }

    /// Name-only calling applies only while the window is on screen. Starts a fresh
    /// transcript so a name said earlier doesn't count.
    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        restartRecognition()
    }

    /// Forgets what was heard so far, e.g. after Wanda finishes speaking.
    func restartRecognition() {
        if isListening { beginRecognition() }
    }

    private func startIfAllowed() {
        guard isEnabled, !isPaused, !isListening else { return }
        Task { await start() }
    }

    private func start() async {
        guard await SpeechRecognizer.requestPermissions() else { return }
        // Re-check after the permission prompt: things may have changed while it was up.
        guard isEnabled, !isPaused, !isListening, let recognizer, recognizer.isAvailable else { return }

        // Feeds whichever request is current, so recognition can restart without
        // touching the microphone.
        let box = requestBox
        let token: Microphone.Token
        do {
            token = try await microphone.attach { buffer in box.request?.append(buffer) }
        } catch {
            problem = "No microphone is available, so Wanda can't hear “Hey Wanda”. Connect AirPods or a microphone; Wanda will pick it up automatically."
            // The mic may be disconnected or mid-switch (AirPods changing modes); retry.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.startIfAllowed()
            }
            return
        }
        // Paused or disabled while the mic was starting.
        guard isEnabled, !isPaused, !isListening else {
            microphone.detach(token)
            return
        }
        micToken = token
        problem = nil
        isListening = true
        beginRecognition()
    }

    /// Starts a fresh recognition task on the running audio engine.
    private func beginRecognition(after delay: Duration = .zero) {
        guard isListening, let recognizer else { return }
        session += 1
        let currentSession = session
        task?.cancel()
        requestBox.request?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = phrase.contextualStrings
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        restartTimer?.cancel()
        restartTimer = Task { [weak self, restartInterval] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.session == currentSession else { return }
            self.requestBox.request = request
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let failed = error != nil
                let ended = failed || result?.isFinal == true
                Task { @MainActor [weak self] in
                    guard let self, self.session == currentSession, self.isListening else { return }
                    let nameOnly = self.nameOnlyWhenOpen && self.isWindowVisible && !self.requiresGreeting()
                    if let text, self.phrase.matches(text, nameOnly: nameOnly) {
                        self.detected()
                    } else if ended {
                        // Keep listening; back off briefly after errors to avoid a tight loop.
                        self.beginRecognition(after: failed ? .seconds(1) : .zero)
                    }
                }
            }
            try? await Task.sleep(for: restartInterval)
            guard !Task.isCancelled, self.session == currentSession else { return }
            self.beginRecognition()
        }
    }

    private func detected() {
        stop()
        wakeCount += 1
        onWake?()
    }

    private func stop() {
        session += 1
        restartTimer?.cancel()
        restartTimer = nil
        task?.cancel()
        task = nil
        requestBox.request?.endAudio()
        requestBox.request = nil
        microphone.detach(micToken)
        micToken = nil
        isListening = false
    }
}

/// Thread-safe holder for the current request; the audio tap runs on a background thread.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}

/// Decides whether speech is calling Wanda. "Hey/Hi/Hello/OK Wanda" (or a nickname)
/// always counts. With `nameOnly` (the window is open), the bare name counts too.
struct WakePhrase: Equatable {
    private static let greetings = "hey|hi|hay|hello|ok|okay"
    /// How the recognizer sometimes hears "Wanda"; trusted only after a greeting, since
    /// words like "wander" are common on their own.
    private static let wandaVariants = ["wanda", "wander", "wonda", "juanda", "rwanda"]

    static let standard = WakePhrase()

    /// Extra names to answer to, lowercased (e.g. ["jarvis"]).
    let nicknames: [String]

    /// `nickname` may list several names separated by commas.
    init(nickname: String = "") {
        nicknames = nickname.lowercased()
            .split(separator: ",")
            .map { Self.normalize(String($0)) }
            .filter { !$0.isEmpty && $0 != "wanda" }
    }

    /// Wanda plus the nicknames, as typed-case words for the speech recognizer's hints.
    var contextualStrings: [String] {
        (["wanda"] + nicknames).flatMap { name in
            let title = name.capitalized
            return [title, "Hey \(title)", "Hi \(title)"]
        }
    }

    func matches(_ transcript: String, nameOnly: Bool = false) -> Bool {
        let text = Self.normalize(transcript)
        let greeted = #"\b(\#(Self.greetings))\s+(\#(Self.alternation(Self.wandaVariants + nicknames)))\b"#
        if text.range(of: greeted, options: .regularExpression) != nil { return true }
        guard nameOnly else { return false }
        let bare = #"\b(\#(Self.alternation(["wanda"] + nicknames)))\b"#
        return text.range(of: bare, options: .regularExpression) != nil
    }

    /// Removes a leading "Hey Wanda," or just "Wanda," (or a nickname) from dictated text.
    func strip(from text: String) -> String {
        let greeted = #"(?:\#(Self.greetings))[\s,]+(?:\#(Self.alternation(Self.wandaVariants + nicknames)))"#
        let bare = #"(?:\#(Self.alternation(["wanda"] + nicknames)))"#
        return text.replacingOccurrences(
            of: #"^\s*(?:\#(greeted)|\#(bare))\b[\s,.!?]*"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
    }

    static func matches(_ transcript: String) -> Bool { standard.matches(transcript) }
    static func strip(from text: String) -> String { standard.strip(from: text) }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Names joined for a regex; multi-word names allow any spacing between words.
    private static func alternation(_ names: [String]) -> String {
        names.map { $0.replacingOccurrences(of: " ", with: #"\s+"#) }.joined(separator: "|")
    }
}
