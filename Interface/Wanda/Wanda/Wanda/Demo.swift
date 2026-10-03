//
//  Demo.swift
//  Wanda
//

import Foundation

/// A sample conversation that shows what Wanda can do: a morning routine, planning a
/// movie night (Maps, a calendar event with a leave-by alert), the mini view, arranging
/// apps, music (turned down while Wanda speaks), a coding break in VS Code and a Python
/// question. Replies are read aloud. Questions Wanda answers on the Mac get real answers; the
/// AI answers are written here, so the demo costs no tokens and works without the server.
enum DemoScript {
    /// Things the demo does on the Mac, like a user would ask for them.
    enum Action: Equatable {
        case minimalView
        case fullView
        /// Opens these apps (by name) without arranging them.
        case openApps([String])
        /// Fits the demo's apps on screen.
        case arrangeApps
        case playMusic
        /// Searches `tripDestination` in Safari, pins it in Maps, drafts `itinerary` in
        /// TextEdit, then fits all the windows on screen.
        case planTrip
        /// Opens, minimizes and quits apps, by name, then fits the demo's apps on screen
        /// if `arrange` is set.
        case tidyUp(open: [String] = [], minimize: [String] = [], close: [String] = [], arrange: Bool = false)
        /// Minimizes Spotify, then opens `pythonStarter` in VS Code, full screen.
        case startCoding
        /// Saves `itinerary` to the Desktop and closes TextEdit.
        case saveItinerary
        /// Real disk numbers, then AI-style advice on freeing space.
        case storageAdvice
        /// Shows `theater` in Maps and picks the first `showtimes` entry after 6 PM
        /// that's still ahead.
        case findTheater
        /// Adds the chosen showing to the calendar, with the theater's address and an alert
        /// to leave based on the driving time.
        case addMovieEvent
    }

    struct Step {
        /// What the "user" says, after "Hey Wanda".
        let said: String
        /// Starts with "Hey Wanda" (and the chime).
        var wakes = true
        /// Done before answering; the answer then says what happened.
        var action: Action?
        /// nil: answer on the Mac for real.
        var reply: String?
        /// Used if the real local answer fails (e.g. no internet for the weather).
        var fallback: String?
        /// Extra time after the answer, e.g. to hear the music.
        var pauseAfter: Double = 0
        /// What Wanda says instead of reading `reply`, e.g. for a reply with code in it.
        var spoken: String?
    }

    static let steps: [Step] = [
        Step(said: "Run my morning routine."),
        Step(said: "I want to go to the movies today. What's showing?",
             reply: """
             Here are some of today's showings near you:
             1. The Matrix (anniversary re-release)
             2. Inception
             3. Back to the Future
             The Matrix has the most evening showtimes.
             """),
        Step(said: "I want to see The Matrix today. Which is the closest movie theater in South Park, and what's the showtime after 6 PM?",
             wakes: false, action: .findTheater),
        Step(said: "Create a calendar event for the movie with the address, and add an alert to leave the house in time to get there.",
             wakes: false, action: .addMovieEvent),
        Step(said: "Open Spotify and close Maps and Calendar.",
             action: .tidyUp(open: ["Spotify"], close: ["Maps", "Calendar"])),
        Step(said: "Organize my windows.", wakes: false, action: .arrangeApps),
        Step(said: "Play Spotify.", wakes: false, action: .playMusic, pauseAfter: 4),
        Step(said: "Minimize Spotify and open a new Python file in VS Code.",
             action: .startCoding, pauseAfter: codingTime),
        Step(said: "What song is this?"),
        Step(said: "Switch to full view.", wakes: false, action: .fullView),
        Step(said: "How do I write a condition in Python?",
             reply: """
             Start with if, the condition and a colon, then indent the code to run when it's true. Add elif for more checks and else for everything else:

             ```python
             age = 20

             if age >= 18:
                 print("Adult")
             elif age >= 13:
                 print("Teenager")
             else:
                 print("Child")
             ```

             For bigger coding questions, like debugging a project or building a whole feature, use the coding agents in VS Code, such as GitHub Copilot or Claude Code. They can read your files and make the changes for you.
             """,
             spoken: """
             To write a condition in Python, start with the word if, then the condition, and a colon. \
             Indent the lines underneath to run when it's true. Add elif for more checks, and else for everything else. \
             I've put an example on screen. \
             For bigger coding questions, like debugging a project or building a whole feature, use the coding agents in VS Code, \
             such as GitHub Copilot or Claude Code. They can read your files and make the changes for you.
             """),
        Step(said: "Thanks!",
             reply: "You're welcome! Say “Hey Wanda” whenever you need me."),
    ]

    /// Read out by the morning routine instead of your real reminders.
    static let reminders = ["Pick up groceries", "Call the dentist", "Water the plants"]

    /// How long the demo waits while you write some code in VS Code (seconds).
    static let codingTime: Double = 5

    /// The file VS Code opens for the coding part.
    static let pythonStarter = """
    # Wanda demo: write some Python here.

    def main():
        names = ["Ada", "Grace", "Linus"]
        for name in names:
            print("Hello,", name)


    if __name__ == "__main__":
        main()
    """

    // The movie night. The theater, address and showtimes are sample values: change them
    // to a real theater near you before recording.
    static let movie = "The Matrix"
    static let theater = "SouthPark Cinemas"
    static let theaterAddress = "4400 Sharon Rd, Charlotte, NC 28211"
    /// Hours and minutes, 24-hour clock.
    static let showtimes = [(hour: 18, minute: 45), (hour: 21, minute: 30)]
    /// Running time plus trailers.
    static let movieLength: TimeInterval = 2.5 * 3600
    /// Extra time before leaving, on top of the drive (parking, tickets, snacks).
    static let leaveBuffer: TimeInterval = 15 * 60

    /// The first showing after 6 PM that starts at least 45 minutes from `now`; if
    /// they've all gone, the first one tomorrow.
    static func nextShowing(after now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let earliest = now.addingTimeInterval(45 * 60)
        for dayOffset in 0...1 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: now)!
            for time in showtimes where time.hour >= 18 {
                let showing = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)!
                if showing >= earliest { return showing }
            }
        }
        return calendar.date(bySettingHour: showtimes[0].hour, minute: showtimes[0].minute, second: 0,
                             of: calendar.date(byAdding: .day, value: 1, to: now)!)!
    }

    static let tripDestination = "Lisbon, Portugal"
    static let itineraryFileName = "Lisbon 2-Day Itinerary"

    static let itinerary = """
    Lisbon, Portugal: 2-Day Itinerary
    Made by Wanda

    DAY 1: Old Lisbon
    Morning     Wander the Alfama district's narrow streets and stop at the Miradouro de Santa Luzia viewpoint.
    Late morning  Visit São Jorge Castle for views over the city and the river.
    Lunch       Grilled sardines or bifana at a small tasca in Alfama.
    Afternoon   Ride historic Tram 28 through Graça and Baixa, then walk Rua Augusta to Praça do Comércio.
    Sunset      Miradouro da Senhora do Monte, the highest viewpoint in the city.
    Dinner      A fado house in Alfama for traditional Portuguese music.

    DAY 2: Belém and the creative side
    Morning     Jerónimos Monastery, then Belém Tower on the waterfront.
    Treat       Pastéis de Belém for the original custard tarts.
    Afternoon   LX Factory: shops, cafés and street art in an old industrial complex.
    Evening     Time Out Market for dinner, then drinks in Bairro Alto.

    TIPS
    • Wear comfortable shoes: Lisbon is built on seven hills.
    • A Lisboa Card covers trams, buses and many museums.
    • Ride Tram 28 early in the morning to avoid the crowds.
    """


    /// The answer to "where can I improve my storage": the real numbers, then advice that
    /// depends on how full the disk is.
    static func storageAdvice(free: Int64, total: Int64) -> String {
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let percentFree = total > 0 ? Int((Double(free) / Double(total) * 100).rounded()) : 0
        let summary = "You have \(format(free)) free of \(format(total)), about \(percentFree)% of your disk."
        let outlook: String
        switch percentFree {
        case ..<10: outlook = "That's very low, and your Mac can slow down when it's this full. I'd free some space soon."
        case 10..<20: outlook = "That's getting low. Freeing a little space will keep things running smoothly."
        default: outlook = "You're in good shape, but here's where you could free up more."
        }
        return [
            summary + " " + outlook,
            "• Empty the Trash and clear out old files in Downloads.",
            "• If you use Xcode, delete old build files in DerivedData; they often take several gigabytes.",
            "• Remove apps you no longer use.",
            "• Open System Settings, General, Storage for Apple's recommendations, like keeping files in iCloud.",
        ].joined(separator: "\n")
    }

    /// "start demo", "demo mode", "show me a demo"…
    static func isRequest(_ text: String) -> Bool {
        let s = LocalIntentParser.normalize(text)
        return s.range(of: #"^((start|run|play|begin|show me|give me)( the| a)? )?demo( mode| conversation)?$"#,
                       options: .regularExpression) != nil
    }
}

/// Progress of a running demo, shown in the chat.
struct DemoState: Equatable {
    var step = 0
    let total: Int
    /// The words "heard" so far while the demo pretends to listen.
    var transcript: String?
    var isFinished = false
}

/// "Switch to mini view" / "full view": true for the mini view, false for the full one.
enum ViewCommand {
    static func parse(_ text: String) -> Bool? {
        let s = LocalIntentParser.normalize(text)
        let view = #"( (view|mode|window|size))?$"#
        if s.range(of: #"^((switch|change|go|swap) (to|into) |(show|open|use) )?(the )?(mini|minimal|small|compact)"# + view,
                   options: .regularExpression) != nil { return true }
        if s.range(of: #"^((switch|change|go|swap) (to|into|back to) |(show|open|use) )?(the )?(full|normal|big|large|chat)"# + view,
                   options: .regularExpression) != nil,
           s.contains(" ") { return false }
        return nil
    }
}
