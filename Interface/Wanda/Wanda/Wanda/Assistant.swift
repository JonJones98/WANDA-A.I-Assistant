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
    /// Called on "Hey Wanda" to bring the window forward.
    var onWake: (() -> Void)?

    private var subscriptions: Set<AnyCancellable> = []

    init(server: ServerManager, microphone: Microphone) {
        chat = ChatViewModel(server: server)
        speech = SpeechRecognizer(microphone: microphone)
        wakeWord = WakeWordListener(microphone: microphone)

        speech.onFinished = { [weak chat] text in chat?.sendDictation(text) }
        wakeWord.onWake = { [weak self] in self?.handleWake() }

        // Dictation and the wake word listener share the mic: pause one while the other runs.
        speech.$isRecording
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isRecording in
                guard let self else { return }
                if isRecording {
                    self.wakeWord.pause()
                } else {
                    self.wakeWord.resume()
                }
            }
            .store(in: &subscriptions)
    }

    func start() {
        Task { await chat.start() }
        wakeWord.resume()
    }

    /// "Hey Wanda" was heard: show the window, stop any reply being read, chime, listen.
    private func handleWake() {
        onWake?()
        chat.stopSpeaking()
        NSSound(named: "Tink")?.play()
        Task {
            await speech.start()
            if !speech.isRecording {
                // Dictation couldn't start (e.g. permissions), so go back to waiting.
                wakeWord.resume()
            }
        }
    }
}
