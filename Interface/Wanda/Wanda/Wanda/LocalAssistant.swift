//
//  LocalAssistant.swift
//  Wanda
//

import AppKit

/// Answers `LocalIntent`s from the Mac itself (clock, Spotify/Music, running apps, disk,
/// volume) without calling the AI, and describes what's happening on the Mac as context
/// for questions that do go to the AI.
@MainActor
final class LocalAssistant {
    private let ownBundleID = Bundle.main.bundleIdentifier
    /// The last app the user was in other than Wanda (Wanda is in front while being asked).
    private(set) var lastActiveApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != ownBundleID {
            lastActiveApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, let app, app.bundleIdentifier != self.ownBundleID else { return }
                self.lastActiveApp = app
            }
        }
    }

    /// The answer if `text` is something Wanda can handle locally, otherwise nil.
    func answer(_ text: String) async -> String? {
        guard let intent = LocalIntentParser.parse(text) else { return nil }
        return await answer(intent)
    }

    func answer(_ intent: LocalIntent) async -> String {
        switch intent {
        case .time:
            return "It's \(Date().formatted(date: .omitted, time: .shortened))."
        case .date:
            return "Today is \(Date().formatted(date: .complete, time: .omitted))."
        case .nowPlaying:
            return await nowPlayingAnswer()
        case .media(let command):
            return await control(command)
        case .activeApp:
            guard let name = lastActiveApp?.localizedName else { return "I'm not sure which app you were using." }
            return "You were last using \(name)."
        case .openApps:
            let names = openAppNames()
            guard !names.isEmpty else { return "No other apps are open." }
            return "You have \(names.count) app\(names.count == 1 ? "" : "s") open: \(ListFormatter.localizedString(byJoining: names))."
        case .diskSpace:
            return diskSpaceAnswer()
        case .volume:
            guard let volume = await SystemVolume.get() else { return "I couldn't read the volume." }
            return volume.muted ? "The sound is muted (volume \(volume.level)%)." : "The volume is at \(volume.level)%."
        case .setVolume(let level):
            await SystemVolume.set(level)
            return "Volume set to \(level)%."
        case .changeVolume(let delta):
            guard let current = await SystemVolume.get() else { return "I couldn't read the volume." }
            let level = min(max(current.level + delta, 0), 100)
            await SystemVolume.set(level)
            return "Volume \(delta > 0 ? "up" : "down") to \(level)%."
        case .mute(let muted):
            await SystemVolume.setMuted(muted)
            return muted ? "Muted." : "Unmuted."
        }
    }

    /// A few lines about the Mac's current state, sent with AI questions so answers can
    /// refer to "this song" or the current time. Kept short to save tokens.
    func context() async -> String {
        var lines = ["Local time: \(Date().formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier))"]
        if let track = await MediaPlayer.nowPlaying() {
            lines.append("Now playing in \(track.app): \"\(track.title)\" by \(track.artist)" + (track.isPlaying ? "" : " (paused)"))
        }
        if let app = lastActiveApp?.localizedName {
            lines.append("App in use: \(app)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Answers

    private func nowPlayingAnswer() async -> String {
        let players = MediaPlayer.running()
        guard !players.isEmpty else { return "Spotify and Music aren't open." }
        guard let track = await MediaPlayer.nowPlaying() else {
            if await MediaPlayer.lacksPermission(players[0]) {
                return MediaPlayer.permissionHint(players[0])
            }
            return "Nothing is playing right now."
        }
        let album = track.album.isEmpty ? "" : ", from \(track.album)"
        return track.isPlaying
            ? "\(track.app) is playing \"\(track.title)\" by \(track.artist)\(album)."
            : "\(track.app) is paused on \"\(track.title)\" by \(track.artist)."
    }

    private func control(_ command: LocalIntent.MediaCommand) async -> String {
        // Control whichever player is active; prefer one that's playing.
        let players = MediaPlayer.running()
        guard !players.isEmpty else { return "Spotify and Music aren't open." }
        let playing = await MediaPlayer.nowPlaying()
        let player = players.first { $0.name == playing?.app } ?? players[0]
        guard await player.send(command) else {
            return await MediaPlayer.lacksPermission(player)
                ? MediaPlayer.permissionHint(player)
                : "\(player.name) didn't respond."
        }
        switch command {
        case .play: return "Playing \(player.name)."
        case .pause: return "Paused \(player.name)."
        case .next, .previous:
            try? await Task.sleep(for: .milliseconds(600))
            if let track = await player.nowPlaying() {
                return "Now playing \"\(track.title)\" by \(track.artist)."
            }
            return command == .next ? "Skipped to the next song." : "Went back a song."
        }
    }

    private func openAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != ownBundleID }
            .compactMap(\.localizedName)
            .sorted()
    }

    private func diskSpaceAnswer() -> String {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return "I couldn't read the disk space." }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return "You have \(format(free)) free of \(format(Int64(total)))."
    }
}

// MARK: - Music players

struct TrackInfo {
    let app: String
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
}

/// Spotify or Apple Music, controlled through AppleScript. Only apps that are already
/// running are touched, so asking never launches a player.
struct MediaPlayer {
    let name: String
    let bundleID: String

    static let all = [
        MediaPlayer(name: "Spotify", bundleID: "com.spotify.client"),
        MediaPlayer(name: "Music", bundleID: "com.apple.Music"),
    ]

    @MainActor
    static func running() -> [MediaPlayer] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return all.filter { ids.contains($0.bundleID) }
    }

    /// The track in the first running player that has one, preferring one that's playing.
    @MainActor
    static func nowPlaying() async -> TrackInfo? {
        var paused: TrackInfo?
        for player in running() {
            guard let track = await player.nowPlaying() else { continue }
            if track.isPlaying { return track }
            paused = paused ?? track
        }
        return paused
    }

    func nowPlaying() async -> TrackInfo? {
        let script = """
        tell application "\(name)"
            if player state is stopped then return "stopped"
            return (player state as text) & "||" & (name of current track) & "||" & (artist of current track) & "||" & (album of current track)
        end tell
        """
        guard let output = await AppleScript.run(script).output else { return nil }
        let parts = output.components(separatedBy: "||")
        guard parts.count == 4 else { return nil }
        return TrackInfo(app: name, title: parts[1], artist: parts[2], album: parts[3], isPlaying: parts[0] == "playing")
    }

    func send(_ command: LocalIntent.MediaCommand) async -> Bool {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        return await AppleScript.run("tell application \"\(name)\" to \(verb)").output != nil
    }

    /// True if macOS blocked Wanda from controlling the player (Automation permission).
    static func lacksPermission(_ player: MediaPlayer) async -> Bool {
        await AppleScript.run("tell application \"\(player.name)\" to get player state").permissionDenied
    }

    static func permissionHint(_ player: MediaPlayer) -> String {
        "I need permission to see \(player.name). Allow it in System Settings → Privacy & Security → Automation → Wanda."
    }
}

// MARK: - System volume

enum SystemVolume {
    static func get() async -> (level: Int, muted: Bool)? {
        let output = await AppleScript.run(
            "set s to get volume settings\nreturn ((output volume of s) as text) & \"||\" & ((output muted of s) as text)"
        ).output
        guard let parts = output?.components(separatedBy: "||"), parts.count == 2, let level = Int(parts[0]) else { return nil }
        return (level, parts[1] == "true")
    }

    static func set(_ level: Int) async {
        _ = await AppleScript.run("set volume output volume \(level)")
    }

    static func setMuted(_ muted: Bool) async {
        _ = await AppleScript.run("set volume \(muted ? "with" : "without") output muted")
    }
}

// MARK: - AppleScript

enum AppleScript {
    struct Result {
        let output: String?
        let permissionDenied: Bool
    }

    /// Runs a script with `osascript` on a background queue, giving up after `timeout` so a
    /// hung app can't stall Wanda.
    static func run(_ source: String, timeout: TimeInterval = 3) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(source, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ source: String, timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Result(output: nil, permissionDenied: false)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return Result(output: nil, permissionDenied: false)
        }
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            // -1743: "Not authorized to send Apple events"
            return Result(output: nil, permissionDenied: errorText.contains("-1743"))
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(output: text, permissionDenied: false)
    }
}
