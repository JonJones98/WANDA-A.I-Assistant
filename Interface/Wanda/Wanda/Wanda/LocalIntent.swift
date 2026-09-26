//
//  LocalIntent.swift
//  Wanda
//

import Foundation

/// A question or command Wanda can handle on the Mac without calling the AI.
enum LocalIntent: Equatable {
    enum MediaCommand: Equatable {
        case play, pause, next, previous
    }

    case time
    case date
    case nowPlaying
    case media(MediaCommand)
    case activeApp
    case openApps
    case diskSpace
    case volume
    case setVolume(Int)
    case changeVolume(by: Int)
    case mute(Bool)
}

/// Matches whole phrasings rather than keywords, so a question that only looks local
/// ("what time is it in Tokyo", "what does this song mean") goes to the AI instead of
/// getting a wrong local answer. Unmatched text returns nil.
enum LocalIntentParser {
    static func parse(_ text: String) -> LocalIntent? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }

        if matches(s, timePatterns) { return .time }
        if matches(s, datePatterns) { return .date }
        if matches(s, nowPlayingPatterns) { return .nowPlaying }
        if let command = mediaCommand(s) { return .media(command) }
        if matches(s, activeAppPatterns) { return .activeApp }
        if matches(s, openAppsPatterns) { return .openApps }
        if matches(s, diskPatterns) { return .diskSpace }
        return volumeIntent(s)
    }

    // MARK: Phrasings

    private static let player = #"( on (spotify|apple music|music|itunes))?"#

    private static let timePatterns = [
        #"^(what|what is) (the )?(current )?time( is it| it is)?$"#,
        #"^what time is it$"#,
        #"^(the )?(current )?time$"#,
        #"^do you have the time$"#,
    ]

    private static let datePatterns = [
        #"^what is (the )?(today )?date( today)?$"#,
        #"^what (date|day) is (it|today)$"#,
        #"^what is today$"#,
        #"^what day of the week is (it|today)$"#,
        #"^(today )?(the )?date$"#,
        #"^what is the day$"#,
    ]

    private static let nowPlayingPatterns = [
        #"^(what|which) (song|track|music) is (this|playing|on)"# + player + "$",
        #"^what is (playing|on)"# + player + "$",
        #"^what is (this|the|the current) (song|track)( playing)?"# + player + "$",
        #"^(what|which) (song|track) (am i listening to|is playing)"# + player + "$",
        #"^what am i listening to$"#,
        #"^(what is )?the name of (this|the|the current) (song|track)( (that is )?(playing|on))?"# + player + "$",
        #"^who (is singing|sings|is the artist( of)?)( this)?( song)?$"#,
        #"^who is this (song )?by$"#,
        #"^(song|track) name$"#,
        #"^now playing$"#,
    ]

    private static let activeAppPatterns = [
        #"^(what|which) (app|application|program) am i (using|in|on)$"#,
        #"^(what|which) (app|application|program) is (open|active|in front|focused)$"#,
    ]

    private static let openAppsPatterns = [
        #"^(what|which) (apps|applications|programs) (are|do i have) (open|running)$"#,
        #"^what (apps|applications|programs) do i have$"#,
        #"^what is (open|running)$"#,
        #"^list (my |the )?(open |running )?(apps|applications|programs)$"#,
    ]

    private static let diskPatterns = [
        #"^how much (free )?(disk |storage |hard drive )?(space|storage) (do i have|is (left|free|available))( left| free| available)?( on (my|the) (mac|computer|disk|drive))?$"#,
        #"^how much storage (do i have )?left$"#,
        #"^(free|available) (disk )?space$"#,
        #"^(disk|storage) space$"#,
    ]

    private static func mediaCommand(_ s: String) -> LocalIntent.MediaCommand? {
        let target = #"( the)?( music| song| track| spotify| apple music| playback| it)?"#
        if matches(s, [#"^(pause|stop)"# + target + "$"]) { return .pause }
        if matches(s, [#"^(play|resume|unpause)"# + target + "$", #"^(start|keep) playing$"#]) { return .play }
        if matches(s, [#"^(next|skip)( this| the)?( song| track)?$"#, #"^(play|go to) the next (song|track)$"#]) { return .next }
        if matches(s, [#"^(previous|last)( song| track)$"#, #"^(play|go to) the (previous|last) (song|track)$"#, #"^go back( a| one)? (song|track)$"#]) { return .previous }
        return nil
    }

    private static func volumeIntent(_ s: String) -> LocalIntent? {
        if matches(s, [#"^what is (the|my) volume( level)?$"#, #"^how loud is it$"#]) { return .volume }
        if let level = firstNumber(s, in: [
            #"^(set|change|turn|put) (the )?volume (to |at )?(\d{1,3})( percent)?$"#,
            #"^volume (to )?(\d{1,3})( percent)?$"#,
        ]) {
            return .setVolume(min(max(level, 0), 100))
        }
        if matches(s, [#"^(turn (it|the volume|the sound) up|volume up|louder|increase (the )?volume)$"#]) { return .changeVolume(by: 10) }
        if matches(s, [#"^(turn (it|the volume|the sound) down|volume down|quieter|lower (the )?volume|decrease (the )?volume)$"#]) { return .changeVolume(by: -10) }
        if matches(s, [#"^mute( the)?( sound| volume| audio| computer| mac)?$"#]) { return .mute(true) }
        if matches(s, [#"^unmute( the)?( sound| volume| audio| computer| mac)?$"#]) { return .mute(false) }
        return nil
    }

    // MARK: Helpers

    /// Lowercases, expands contractions, drops punctuation, a leading wake phrase and
    /// polite filler ("can you tell me … please"), so phrasing variants compare equal.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "%", with: " percent")
        let contractions = [
            "what's": "what is", "whats": "what is", "it's": "it is", "i'm": "i am",
            "today's": "today", "todays": "today", "who's": "who is", "that's": "that is",
        ]
        for (short, long) in contractions {
            s = s.replacingOccurrences(of: #"\b\#(short)\b"#, with: long, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let leading = #"^((hey|hi|hello|ok|okay) )?wanda |^(please|can you|could you|would you|will you|do you know|tell me|let me know|i want to know|i would like to know) "#
        let trailing = #" (please|right now|now|for me|currently|at the moment)$"#
        var previous = ""
        while previous != s {
            previous = s
            s = s.replacingOccurrences(of: leading, with: "", options: .regularExpression)
                .replacingOccurrences(of: trailing, with: "", options: .regularExpression)
        }
        return s
    }

    private static func matches(_ s: String, _ patterns: [String]) -> Bool {
        patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    private static func firstNumber(_ s: String, in patterns: [String]) -> Int? {
        for pattern in patterns where s.range(of: pattern, options: .regularExpression) != nil {
            if let digits = s.range(of: #"\d{1,3}"#, options: .regularExpression) {
                return Int(s[digits])
            }
        }
        return nil
    }
}
