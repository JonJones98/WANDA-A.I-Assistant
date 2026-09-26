//
//  Microphone.swift
//  Wanda
//

import AVFoundation
import CoreAudio

/// The app's one connection to the microphone. The wake word listener and dictation take
/// turns receiving its audio instead of each opening the device, which fails with
/// "device busy" (error 35) when one starts before the other has fully let go.
///
/// Only the most recent `attach` receives audio. The engine keeps running briefly after
/// the last `detach`, so handing the mic from one feature to the other doesn't restart it.
///
/// All audio engine calls run as plain main-queue work, never inside a Swift task: some
/// of them (notably with no input device) let other queued work run in the middle of the
/// call, and if that happens inside a task it corrupts Swift concurrency — afterwards
/// every `await` in the app stops resuming and Wanda stops answering.
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
    private var idleStop: DispatchWorkItem?
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
            DispatchQueue.main.async { self?.restartAfterConfigurationChange() }
        }
    }

    /// Sends microphone audio to `consumer` (replacing any previous consumer), starting
    /// the microphone if needed.
    func attach(_ consumer: @escaping Consumer) async throws -> Token {
        try await withCheckedThrowingContinuation { continuation in
            // Leave the current task before touching the audio engine (see type docs).
            DispatchQueue.main.async {
                do {
                    continuation.resume(returning: try self.attachNow(consumer))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func attachNow(_ consumer: @escaping Consumer) throws -> Token {
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
        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.currentToken == nil else { return }
            self.stopEngine()
        }
        idleStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: stop)
    }

    struct NoInputDevice: LocalizedError {
        var errorDescription: String? { "No microphone is available right now." }
    }

    private func startEngine() throws {
        // Ask Core Audio first: with no microphone at all (e.g. AirPods disconnected on a
        // Mac mini) there's no point creating audio engines every retry.
        guard Self.hasInputDevice() else { throw NoInputDevice() }
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

    /// True if the Mac's default input device exists and has input channels.
    nonisolated static func hasInputDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioDevicePropertyStreams
        address.mScope = kAudioDevicePropertyScopeInput
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &streamsSize) == noErr else { return false }
        return streamsSize > 0
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
