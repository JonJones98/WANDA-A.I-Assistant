//
//  MusicDucker.swift
//  Wanda
//

import Foundation

/// Turns Spotify and Apple Music down while Wanda speaks and back up when she's done.
/// Only the players' own volume changes, so Wanda's voice and other sounds stay as loud.
///
/// If the user changes a player's volume while it's lowered, their choice is kept. The
/// lowered state is saved, so if Wanda quits or crashes mid-reply the music is turned
/// back up on the next launch.
@MainActor
final class MusicDucker {
    /// Music plays at this fraction of its volume while Wanda speaks.
    static let duckedFraction = 0.3
    /// Wait this long after speech ends before turning music back up, so the gap between
    /// one reply and the next doesn't pump the music up and down.
    static let restoreDelay: TimeInterval = 0.8

    var isEnabled = true {
        didSet { if !isEnabled { scheduleRestore(after: 0) } }
    }

    private let defaults: UserDefaults
    private static let savedKey = "MusicDucker.lowered"
    /// Player name -> [original volume, lowered volume].
    private var lowered: [String: [Int]] {
        get { (defaults.dictionary(forKey: Self.savedKey) as? [String: [Int]]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.savedKey) }
    }
    private var isSpeaking = false
    private var restoreWork: DispatchWorkItem?
    /// Runs one duck or restore at a time, in order.
    private var queue: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Left lowered by a previous run that ended mid-reply.
        if !lowered.isEmpty { enqueue { await self.restore() } }
    }

    func speakingChanged(_ speaking: Bool) {
        isSpeaking = speaking
        if speaking {
            restoreWork?.cancel()
            restoreWork = nil
            guard isEnabled else { return }
            enqueue { await self.duck() }
        } else {
            scheduleRestore(after: Self.restoreDelay)
        }
    }

    /// Turns music back up right away, blocking briefly. For quitting.
    func restoreNow() {
        restoreWork?.cancel()
        for (name, volumes) in lowered where volumes.count == 2 {
            _ = AppleScript.runBlocking(Self.restoreScript(name, original: volumes[0], lowered: volumes[1]), timeout: 1.5)
        }
        lowered = [:]
    }

    private func scheduleRestore(after delay: TimeInterval) {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSpeaking || !self.isEnabled else { return }
            self.enqueue { await self.restore() }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }

    private func duck() async {
        // Speech may have ended while earlier work ran.
        guard isSpeaking, isEnabled else { return }
        let percent = Int(Self.duckedFraction * 100)
        for player in MediaPlayer.running() where lowered[player.name] == nil {
            let script = """
            if application "\(player.name)" is not running then return ""
            tell application "\(player.name)"
                if player state is not playing then return ""
                set original to sound volume
                set sound volume to (original * \(percent) div 100)
                return (original as text) & "||" & (sound volume as text)
            end tell
            """
            guard let output = await AppleScript.run(script, timeout: 2).output else { continue }
            let parts = output.components(separatedBy: "||").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            lowered[player.name] = parts
        }
    }

    private func restore() async {
        for (name, volumes) in lowered where volumes.count == 2 {
            _ = await AppleScript.run(Self.restoreScript(name, original: volumes[0], lowered: volumes[1]), timeout: 3)
        }
        lowered = [:]
    }

    /// Fades back to `original`, unless the user has since changed the volume themselves.
    /// (Players round the volume, so "unchanged" allows a step or two of difference.)
    private static func restoreScript(_ name: String, original: Int, lowered: Int) -> String {
        """
        if application "\(name)" is not running then return ""
        tell application "\(name)"
            set current to sound volume
            set difference to current - \(lowered)
            if difference < 0 then set difference to -difference
            if difference > 2 then return ""
            repeat with step from 1 to 5
                set sound volume to (\(lowered) + (\(original) - \(lowered)) * step div 5)
                delay 0.08
            end repeat
            set sound volume to \(original)
        end tell
        """
    }
}
