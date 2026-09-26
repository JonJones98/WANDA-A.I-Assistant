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

    /// Incremented on every detection, so views can react with `onChange`.
    @Published private(set) var wakeCount = 0
    @Published private(set) var isListening = false
    /// Why listening can't start right now (e.g. no microphone connected), or nil.
    @Published private(set) var problem: String?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? resume() : pause()
        }
    }

    var onWake: (() -> Void)?

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
    }

    /// Starts (or restarts) listening if enabled.
    func resume() {
        isPaused = false
        guard isEnabled, !isListening else { return }
        Task { await start() }
    }

    /// Stops listening until `resume()`, e.g. while dictation is using the mic.
    func pause() {
        isPaused = true
        stop()
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
            token = try microphone.attach { buffer in box.request?.append(buffer) }
        } catch {
            problem = "No microphone is available, so Wanda can't hear “Hey Wanda”. Connect AirPods or a microphone; Wanda will pick it up automatically."
            // The mic may be disconnected or mid-switch (AirPods changing modes); retry.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.isPaused else { return }
                self.resume()
            }
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
        request.contextualStrings = ["Wanda", "Hey Wanda", "Hi Wanda"]
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
                Task { @MainActor in
                    guard let self, self.session == currentSession, self.isListening else { return }
                    if let text, WakePhrase.matches(text) {
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

enum WakePhrase {
    /// "Hey/Hi/Hello/OK Wanda", including common mishearings of "Wanda".
    private static let pattern = #"\b(hey|hi|hay|hello|ok|okay)\s+(wanda|wander|wonda|juanda|rwanda)\b"#

    /// Removes a leading "Hey Wanda," from dictated text.
    static func strip(from text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*(hey|hi|hay|hello|ok|okay)[\s,]+(wanda|wander|wonda|juanda)\b[\s,.!?]*"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
    }

    static func matches(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
            .replacingOccurrences(of: #"[^a-z\s]"#, with: " ", options: .regularExpression)
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }
}
