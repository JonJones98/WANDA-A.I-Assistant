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

    case tools
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
    case weather(WeatherQuery)
    /// What's on the calendar today (or tomorrow).
    case schedule(tomorrow: Bool)
    /// Calendar, weather, reminders and a recap of yesterday.
    case morningRoutine
    /// Open several apps and fit their windows on screen.
    case openAndArrange([String])
    case arrangeWindows
}

/// A weather question: when, what about, and where (nil = where the Mac is).
struct WeatherQuery: Equatable {
    enum Day: Equatable {
        case now, today, tomorrow, week
    }

    enum Focus: Equatable {
        case general, temperature, rain, snow
    }

    var day: Day = .now
    var focus: Focus = .general
    var place: String?
}

/// Matches whole phrasings rather than keywords, so a question that only looks local
/// ("what time is it in Tokyo", "what does this song mean") goes to the AI instead of
/// getting a wrong local answer. Unmatched text returns nil.
enum LocalIntentParser {
    static func parse(_ text: String) -> LocalIntent? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }

        // Before normalizing loses the commas between app names.
        if let apps = appsToOpen(text) { return .openAndArrange(apps) }
        if matches(s, arrangePatterns) { return .arrangeWindows }

        if matches(s, toolsPatterns) { return .tools }
        if matches(s, timePatterns) { return .time }
        if matches(s, datePatterns) { return .date }
        if matches(s, nowPlayingPatterns) { return .nowPlaying }
        if let command = mediaCommand(s) { return .media(command) }
        if matches(s, activeAppPatterns) { return .activeApp }
        if matches(s, openAppsPatterns) { return .openApps }
        if matches(s, diskPatterns) { return .diskSpace }
        if let query = weatherQuery(s) { return .weather(query) }
        if matches(s, morningPatterns) { return .morningRoutine }
        if matches(s, schedulePatterns) { return .schedule(tomorrow: s.hasSuffix("tomorrow")) }
        return volumeIntent(s)
    }

    // MARK: Phrasings

    private static let morningPatterns = [
        #"^(run|start|do|play)( my| the)? morning (routine|briefing|brief|rundown)$"#,
        #"^(my )?morning (routine|briefing|brief|rundown)$"#,
        #"^good morning( wanda)?$"#,
        #"^(brief me|start my day|how does my day look|what is my day like)$"#,
    ]

    private static let schedulePatterns = [
        #"^(do|will) i have (anything|something|any (events|meetings|plans|appointments))( scheduled| planned| on| going on)?( for)? (today|tomorrow)$"#,
        #"^(is there|have i got) (anything|something) (scheduled|planned|on)( for)? (today|tomorrow)$"#,
        #"^what (is|do i have) (on|scheduled|planned)( on)?( for)?( my)?( calendar| schedule| agenda)?( for)?( today| tomorrow)?$"#,
        #"^what (is|does) (my|the) (calendar|schedule|agenda|day)( look like)?( for)?( today| tomorrow)?$"#,
        #"^what (meetings|events|appointments|plans) do i have( today| tomorrow)?$"#,
        #"^what do i have( going on| planned| on)?( for)? (today|tomorrow)$"#,
        #"^(check |show me |read )?(my )?(calendar|schedule|agenda)( for)?( today| tomorrow)?$"#,
    ]

    private static let arrangePatterns = [
        #"^(organize|organise|arrange|tile|tidy( up)?|sort( out)?|clean up|fit|lay out|layout|split)( all)?( of)?( my| the)?( open)? (windows|apps|screen|desktop)( to fit)?( on (the|my) screen)?( side by side| in a grid)?$"#,
        #"^(put|place|show) (my |the )?(windows|apps) side by side$"#,
        #"^(make|help) (my |the )?(windows|apps) fit( on)?( the| my)? screen$"#,
    ]

    /// "Open Safari, Notes and Spotify (side by side)": two or more app names after
    /// "open" or "launch". Works on the original text, whose commas separate names.
    static func appsToOpen(_ text: String) -> [String]? {
        var s = text.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        let lead = #"^\s*((hey|hi|ok|okay) )?(wanda[,!.]? *)?((please|can you|could you|would you) )?(open|launch|start up|start)( up)? "#
        guard let range = s.range(of: lead, options: .regularExpression) else { return nil }
        s.removeSubrange(range)
        let trailing = #"( and)? (arrange|organize|organise|tile|fit|put|place|lay out) (them|the windows|their windows|it all|everything)( on (the|my) screen| side by side| in a grid)?$|,? (side by side|in a grid|next to each other|together|for me|please)$"#
        var previous = ""
        while previous != s {
            previous = s
            s = s.replacingOccurrences(of: trailing, with: "", options: .regularExpression)
        }
        let names = s.components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^and "#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        return names.count >= 2 ? names : nil
    }

    private static let player = #"( on (spotify|apple music|music|itunes))?"#

    private static let toolsPatterns = [
        #"^(list|show)( me)?( all)?( of)?( your| the| my)?( built in)? (tool|tools|capabilities|commands|skills|features)$"#,
        #"^(what|which) (tools|capabilities|commands|skills|features) (do you have|can you use|are there|are available)$"#,
        #"^what are your (tools|capabilities|commands|skills|features)$"#,
        #"^what can you do( without ai)?$"#,
        #"^(tools|help)$"#,
    ]

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

    /// "what's the weather", "forecast for tomorrow in Paris", "will it rain this week",
    /// "how cold is it outside", "do I need an umbrella". The day can be anywhere; a place
    /// ("in Chicago") comes last.
    static func weatherQuery(_ s: String) -> WeatherQuery? {
        var query = WeatherQuery()
        var s = " " + s + " "
        let days: [(pattern: String, day: WeatherQuery.Day)] = [
            (#" (for |on )?(the )?(rest of )?(this week|the week|next few days|coming days|week ahead|next 7 days|next seven days|week)( ahead)? "#, .week),
            (#" (for |on )?tomorrow( morning| afternoon| evening| night)? "#, .tomorrow),
            (#" (for |on )?(today|tonight|this (morning|afternoon|evening))( morning| afternoon| evening| night)? "#, .today),
            (#" (right now|now|currently|at the moment|outside|out there|out|around here|here) "#, .now),
        ]
        for (pattern, day) in days {
            guard let range = s.range(of: pattern, options: .regularExpression) else { continue }
            s.replaceSubrange(range, with: " ")
            if day != .now || query.day == .now { query.day = day }
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let place = #"( (in|for|at|near) (?<place>[a-z][a-z ]*))?$"#
        let forms: [(pattern: String, focus: WeatherQuery.Focus)] = [
            (#"^((what|how) is |what will be |what does |how does |give me |get )?(the |today )?(weather|forecast|weather forecast|weather report|temperature|temp)( like| going to be| going to be like| gonna be| gonna be like| look| look like| looking| looking like| be like| be)?"#, .general),
            (#"^how (hot|cold|warm|chilly) (is it|will it be|is it going to be|is it gonna be)"#, .temperature),
            (#"^(is it|will it|is it going to|is it gonna|does it look like it will|does it look like it is going to|should i expect) (rain|be rainy|be raining|raining|storm|be stormy)"#, .rain),
            (#"^do i need (an umbrella|a raincoat)"#, .rain),
            (#"^(any |what is the )?(chance of rain|rain|rain forecast)"#, .rain),
            (#"^(is it|will it|is it going to|is it gonna) (snow|be snowing|snowing|be snowy)"#, .snow),
        ]
        for (pattern, focus) in forms {
            guard let regex = try? NSRegularExpression(pattern: pattern + place),
                  let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            query.focus = focus
            if focus == .general, s.contains("temp") { query.focus = .temperature }
            if let range = Range(match.range(withName: "place"), in: s) {
                let name = String(s[range]).trimmingCharacters(in: .whitespaces)
                if !["here", "my area", "my location", "my city", "town", "the area"].contains(name) {
                    query.place = name
                }
            }
            return query
        }
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
            "today's": "today", "todays": "today", "tomorrow's": "tomorrow", "how's": "how is", "who's": "who is", "that's": "that is",
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
