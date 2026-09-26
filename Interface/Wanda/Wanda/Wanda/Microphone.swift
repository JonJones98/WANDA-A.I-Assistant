//
//  Microphone.swift
//  Wanda
//

import AVFoundation

/// The app's one connection to the microphone. The wake word listener and dictation take
/// turns receiving its audio instead of each opening the device, which fails with
/// "device busy" (error 35) when one starts before the other has fully let go.
///
/// Only the most recent `attach` receives audio. The engine keeps running briefly after
/// the last `detach`, so handing the mic from one feature to the other doesn't restart it.
@MainActor
final class Microphone {
    typealias Consumer = (AVAudioPCMBuffer) -> Void

    /// Identifies one `attach`; `detach` with a stale token does nothing.
    struct Token: Equatable {
        fileprivate let id: Int
    }

    private var engine = AVAudioEngine()
    private let box = ConsumerBox()
    private var currentToken: Token?
    private var nextID = 0
    private var idleStop: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var recentRestarts: [ContinuousClock.Instant] = []

    init() {
        observeConfigurationChanges()
    }

    /// Bluetooth headsets (e.g. AirPods) switch modes when the mic turns on, which can
    /// stop the engine. Restart it if someone is still listening.
    private func observeConfigurationChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAfterConfigurationChange() }
        }
    }

    /// Sends microphone audio to `consumer` (replacing any previous consumer), starting
    /// the microphone if needed.
    func attach(_ consumer: @escaping Consumer) throws -> Token {
        idleStop?.cancel()
        idleStop = nil
        nextID += 1
        let token = Token(id: nextID)
        currentToken = token
        box.consumer = consumer
        if !engine.isRunning {
            do {
                try startEngine()
            } catch {
                box.consumer = nil
                currentToken = nil
                throw error
            }
        }
        return token
    }

    /// Stops sending audio for `token`; the microphone turns off shortly after unless
    /// someone else attaches.
    func detach(_ token: Token?) {
        guard let token, token == currentToken else { return }
        currentToken = nil
        box.consumer = nil
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.currentToken == nil else { return }
            self.stopEngine()
        }
    }

    struct NoInputDevice: LocalizedError {
        var errorDescription: String? { "No microphone is available right now." }
    }

    private func startEngine() throws {
        var format = engine.inputNode.outputFormat(forBus: 0)
        if !Self.isUsable(format) {
            // An engine made while no mic was connected can stay tied to that state; a new
            // one picks up whatever input device is the default now (e.g. reconnected AirPods).
            engine.inputNode.removeTap(onBus: 0)
            engine = AVAudioEngine()
            observeConfigurationChanges()
            format = engine.inputNode.outputFormat(forBus: 0)
        }
        // With no input device, or while a Bluetooth headset switches modes, the input
        // reports 0 channels at 0 Hz; installing a tap with that format crashes.
        guard Self.isUsable(format) else { throw NoInputDevice() }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let box = self.box
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.consumer?(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func restartAfterConfigurationChange() {
        guard currentToken != nil, !engine.isRunning else { return }
        // Guard against a restart loop if every start triggers another change.
        let now = ContinuousClock.now
        recentRestarts = recentRestarts.filter { now - $0 < .seconds(10) } + [now]
        guard recentRestarts.count <= 3 else { return }
        try? startEngine()
    }
}

/// Holds the current consumer; the audio tap reads it on a background thread.
private final class ConsumerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Microphone.Consumer?

    var consumer: Microphone.Consumer? {
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
