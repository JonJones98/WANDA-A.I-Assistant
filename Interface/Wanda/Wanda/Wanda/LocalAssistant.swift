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
    private lazy var weather = WeatherService()

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
        // "Forecast for bitcoin" isn't a place: let the AI have it.
        if case .weather(let query) = intent { return await weatherAnswer(query) }
        // "Open Spotify and play jazz" isn't two apps: let the server and AI have it.
        if case .openAndArrange(let names) = intent, names.contains(where: { WindowArranger.findApp($0) == nil }) {
            return nil
        }
        return await answer(intent)
    }

    /// Wanda's built-in abilities that don't use the AI, with example phrases.
    /// Shown by "list tools"; keep in sync with `LocalIntentParser` and `CommandParser`.
    static let tools: [(name: String, examples: String)] = [
        ("Time and date", "“what time is it”, “what’s today’s date”"),
        ("Music (Spotify or Apple Music)", "“what’s playing”, “pause”, “play”, “next song”, “previous song”"),
        ("Open and close apps", "“open Safari”, “close Spotify”"),
        ("Open and arrange apps", "“open Safari, Notes and Spotify”, “arrange my windows”"),
        ("Apps in use", "“what app am I using”, “what apps are open”"),
        ("Weather", "“what’s the weather”, “forecast for tomorrow”, “will it rain this week”, “weather in Chicago”"),
        ("Disk space", "“how much disk space do I have left”"),
        ("Volume", "“what’s the volume”, “set volume to 40”, “turn it up”, “mute”"),
        ("Mini and full view", "“switch to mini view”, “full view”"),
        ("Documents (the AI writes them)", "“write a packing list for a beach trip and save it”, “create a document about…”"),
        ("Save an answer", "“save that to Documents”"),
        ("Demo", "“start demo” plays a sample conversation"),
        ("This list", "“list tools”"),
    ]

    func answer(_ intent: LocalIntent) async -> String {
        switch intent {
        case .tools:
            let lines = Self.tools.map { "• \($0.name): \($0.examples)" }
            return (["Here’s what I can do on your Mac without AI:"] + lines
                + ["Say “Hey Wanda” to start talking. Anything else goes to the AI."])
                .joined(separator: "\n")
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
        case .weather(let query):
            return await weatherAnswer(query) ?? "I couldn't find \(query.place ?? "that place")."
        case .openAndArrange(let names):
            return await openAndArrange(names)
        case .arrangeWindows:
            guard WindowArranger.isAllowed else { return accessibilityHint(opened: nil) }
            let apps = WindowArranger.visibleApps()
            guard !apps.isEmpty else { return "There are no windows to arrange." }
            let count = WindowArranger.arrange(apps)
            return count == 0 ? "I couldn't move those windows." : "Arranged \(count) window\(count == 1 ? "" : "s") to fit your screen."
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

    private func openAndArrange(_ names: [String]) async -> String {
        let urls = names.compactMap(WindowArranger.findApp)
        let apps = await WindowArranger.open(urls)
        let appNames = ListFormatter.localizedString(byJoining: apps.compactMap(\.localizedName))
        guard !apps.isEmpty else { return "I couldn't open those apps." }
        guard WindowArranger.isAllowed else { return accessibilityHint(opened: appNames) }
        let count = WindowArranger.arrange(apps)
        let how = count == 2 ? "side by side" : "to fit your screen"
        return count == 0 ? "Opened \(appNames), but I couldn't move their windows." : "Opened \(appNames) and arranged them \(how)."
    }

    /// Asks macOS to show the Accessibility prompt and explains what to do.
    private func accessibilityHint(opened: String?) -> String {
        WindowArranger.requestPermission()
        let prefix = opened.map { "Opened \($0). " } ?? ""
        return prefix + "To arrange windows, allow Wanda in System Settings → Privacy & Security → Accessibility, then say “arrange my windows”."
    }

    /// nil if the place named in the question couldn't be found.
    private func weatherAnswer(_ query: WeatherQuery) async -> String? {
        do {
            return try await weather.answer(query)
        } catch WeatherService.Failure.placeNotFound {
            return nil
        } catch {
            return "I couldn't reach the weather service. Check your internet connection."
        }
    }

    private func openAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != ownBundleID }
            .compactMap(\.localizedName)
            .sorted()
    }

    private func diskSpaceAnswer() -> String {
        guard let disk = Self.diskUsage() else { return "I couldn't read the disk space." }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return "You have \(format(disk.free)) free of \(format(disk.total))."
    }

    /// Free and total bytes on the startup disk.
    static func diskUsage() -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
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

    /// Starts music: resumes the current track, or if there isn't one, plays a relaxed
    /// playlist in Spotify. Returns true if the player reports it's playing.
    func startPlaying() async -> Bool {
        guard await send(.play) else { return false }
        try? await Task.sleep(for: .seconds(1))
        if await nowPlaying()?.isPlaying == true { return true }
        guard name == "Spotify" else { return false }
        // Nothing queued: Spotify's "Peaceful Piano" playlist.
        _ = await AppleScript.run(#"tell application "Spotify" to play track "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO""#)
        try? await Task.sleep(for: .seconds(1.5))
        return await nowPlaying()?.isPlaying == true
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

    /// Like `run`, but waits on the calling thread. Only for when async isn't possible.
    static func runBlocking(_ source: String, timeout: TimeInterval) -> Result {
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
