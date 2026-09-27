//
//  SpeechRecognizer.swift
//  Wanda
//

import AVFoundation
import Speech

/// Live microphone dictation. `transcript` updates as the user speaks. When the user
/// stops (or pauses for `silenceTimeout`), the final text is passed to `onFinished`.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    /// Called once per dictation with the final, non-empty text.
    var onFinished: ((String) -> Void)?
    /// Runs just before the mic turns on (e.g. pause music, play the chime). Things that
    /// should be heard go here: turning the mic on switches AirPods to call mode, which
    /// drops any sound playing at that moment.
    var willStartListening: (() async -> Void)?

    private let silenceTimeout: Duration = .seconds(1.5)
    /// Gives up if nothing is heard at all after the mic turns on.
    private let noSpeechTimeout: Duration = .seconds(8)
    /// How long to wait for the recognizer's final result after the mic stops.
    private let finalResultTimeout: Duration = .seconds(1.5)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let microphone: Microphone
    private var micToken: Microphone.Token?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var finalResultTimer: Task<Void, Never>?
    /// Bumped whenever a dictation ends, so late callbacks from it are ignored.
    private var session = 0
    /// True from a successful start until the text is delivered or discarded.
    @Published private(set) var isActive = false

    init(microphone: Microphone) {
        self.microphone = microphone
    }

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        cancel()
        errorMessage = nil
        guard await Self.requestPermissions() else {
            errorMessage = "Wanda needs microphone and speech recognition access. Turn them on in System Settings > Privacy & Security."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let startingSession = session
        await willStartListening?()
        guard session == startingSession else { return }
        do {
            micToken = try await microphone.attach { buffer in request.append(buffer) }
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        // Cancelled while the mic was starting.
        guard session == startingSession else {
            microphone.detach(micToken)
            micToken = nil
            return
        }

        transcript = ""
        self.request = request
        isRecording = true
        isActive = true
        restartSilenceTimer(after: noSpeechTimeout)
        let currentSession = session
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = error != nil || result?.isFinal == true
            Task { @MainActor [weak self] in
                guard let self, self.session == currentSession else { return }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.restartSilenceTimer(after: self.silenceTimeout)
                }
                if isFinal { self.finish() }
            }
        }
    }

    /// Stops listening, then hands the text to `onFinished` once the final result arrives.
    func stop() {
        guard isRecording else { return }
        stopAudio()
        finalResultTimer = Task { [weak self, finalResultTimeout] in
            try? await Task.sleep(for: finalResultTimeout)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// Stops listening and discards the dictation.
    func cancel() {
        session += 1
        task?.cancel()
        stopAudio()
        finalResultTimer?.cancel()
        task = nil
        transcript = ""
        isActive = false
    }

    private func finish() {
        guard isActive else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        if !text.isEmpty { onFinished?(text) }
    }

    private func stopAudio() {
        silenceTimer?.cancel()
        microphone.detach(micToken)
        micToken = nil
        request?.endAudio()
        request = nil
        isRecording = false
    }

    private func restartSilenceTimer(after timeout: Duration) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Asks for speech recognition and microphone access (only prompts the first time).
    static func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAllowed else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
