//
//  Assistant.swift
//  Wanda
//

import AppKit
import Combine

/// Wires the voice pieces together for the life of the app: "Hey Wanda" starts
/// dictation, dictation sends the message, and the wake word listener resumes when the
/// mic is free again. Lives outside the view so it works before the window is ever shown.
@MainActor
final class Assistant {
    let chat: ChatViewModel
    let speech: SpeechRecognizer
    let wakeWord: WakeWordListener
    let musicDucker = MusicDucker()
    let musicPauser = MusicPauser()
    let headGestures = HeadGestureListener()
    /// Called on "Hey Wanda" to bring the window forward.
    var onWake: (() -> Void)?

    private var subscriptions: Set<AnyCancellable> = []

    init(server: ServerManager, microphone: Microphone) {
        chat = ChatViewModel(server: server)
        speech = SpeechRecognizer(microphone: microphone)
        wakeWord = WakeWordListener(microphone: microphone)

        speech.onFinished = { [weak self] text in
            guard let self else { return }
            // Drop "Hey Wanda," / "Wanda," / a nickname from the start of the request.
            let request = self.wakeWord.phrase.strip(from: text)
            // "Pause", "play", "next song": the user is controlling the music themselves.
            if case .media = LocalIntentParser.parse(request) { self.musicPauser.forget() }
            self.chat.sendDictation(request)
        }
        wakeWord.onWake = { [weak self] in self?.handleWake() }
        headGestures.onGesture = { [weak self] in self?.handleHeadGesture() }
        // One wake up mode at a time (see WakeMode); gestures win over older settings.
        if headGestures.isEnabled { wakeWord.isEnabled = false }
        wakeWord.requiresGreeting = { [weak chat] in chat?.voice.isSpeaking ?? false }

        // After Wanda speaks, start a fresh transcript: her reply may have contained "Wanda".
        chat.voice.$isSpeaking
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.wakeWord.restartRecognition() }
            .store(in: &subscriptions)

        // Turn background music down while Wanda speaks.
        chat.voice.$isSpeaking
            .removeDuplicates()
            .sink { [weak self] speaking in self?.musicDucker.speakingChanged(speaking) }
            .store(in: &subscriptions)
        chat.voice.settings.$lowersMusic
            .sink { [weak self] enabled in self?.musicDucker.isEnabled = enabled }
            .store(in: &subscriptions)

        // Before the mic turns on: pause the music, then chime while AirPods can still
        // play it (turning the mic on switches them to call mode and drops the sound).
        speech.willStartListening = { [weak self] in
            guard let self else { return }
            await self.musicPauser.pauseIfPlaying()
            Chime.listening()
            try? await Task.sleep(for: .milliseconds(250))
            // If the mic then fails to start, don't leave the music paused.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.speech.isActive, self.chat.pendingConversationID == nil,
                      !self.chat.voice.isSpeaking else { return }
                self.musicPauser.resumeIfPaused()
            }
        }
        chat.voice.settings.$pausesMusic
            .sink { [weak self] enabled in self?.musicPauser.isEnabled = enabled }
            .store(in: &subscriptions)
        // Resume paused music once Wanda is done: not listening, not waiting for the
        // answer, and not reading it aloud (debounced over the gaps between those).
        Publishers.CombineLatest3(speech.$isActive, chat.$pendingConversationID, chat.voice.$isSpeaking)
            .map { listening, pending, speaking in !listening && pending == nil && !speaking }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .filter { $0 }
            .sink { [weak self] _ in self?.musicPauser.resumeIfPaused() }
            .store(in: &subscriptions)

        // Dictation and the wake word listener share the mic: pause one while the other
        // runs. A chime marks when Wanda starts and stops listening, however it started.
        speech.$isRecording
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isRecording in
                guard let self else { return }
                if isRecording {
                    self.wakeWord.pause()
                } else {
                    Chime.doneListening()
                    self.wakeWord.resume()
                }
            }
            .store(in: &subscriptions)
    }

    /// Whether Wanda's window is on screen (enables calling her by name alone).
    func setWindowVisible(_ visible: Bool) {
        wakeWord.setWindowVisible(visible)
    }

    func start() {
        Task { await chat.start() }
        wakeWord.resume()
    }

    /// A nod or head shake starts listening, or stops it if Wanda is already listening.
    private func handleHeadGesture() {
        if speech.isRecording {
            speech.stop()
        } else {
            handleWake()
        }
    }

    /// "Hey Wanda" was heard: show the window, stop any reply being read, chime, listen.
    private func handleWake() {
        chat.endDemo()
        onWake?()
        chat.stopSpeaking()
        Task {
            await speech.start()
            if !speech.isRecording {
                // Dictation couldn't start (e.g. permissions), so go back to waiting.
                wakeWord.resume()
            }
        }
    }
}

/// Short system sounds for when Wanda starts and stops listening, like Siri's.
enum Chime {
    @MainActor static func listening() { play("Tink", volume: 1) }
    @MainActor static func doneListening() { play("Pop", volume: 0.5) }

    @MainActor private static func play(_ name: String, volume: Float) {
        // A copy each time, so a chime still plays while the previous one is finishing.
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
