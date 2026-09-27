//
//  Demo.swift
//  Wanda
//

import Foundation

/// A sample conversation that shows what Wanda can do: the mini view, opening and
/// arranging apps, music (turned down while Wanda speaks), questions answered on the Mac,
/// planning a trip in Safari and Maps with an itinerary saved to the Desktop, then tidying
/// up. Replies are read aloud. Questions Wanda answers on the Mac get real answers; the
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
        /// Minimizes the first apps and quits the second ones.
        case tidyUp(minimize: [String], close: [String])
        /// Saves `itinerary` to the Desktop and closes TextEdit.
        case saveItinerary
        /// Real disk numbers, then AI-style advice on freeing space.
        case storageAdvice
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
    }

    static let steps: [Step] = [
        Step(said: "Switch to mini view.", action: .minimalView),
        Step(said: "Open Maps and Spotify.", action: .openApps(["Maps", "Spotify"])),
        Step(said: "Organize my windows.", wakes: false, action: .arrangeApps),
        Step(said: "Play Spotify.", wakes: false, action: .playMusic, pauseAfter: 4),
        Step(said: "What song is this?"),
        Step(said: "What time is it?"),
        Step(said: "What's the weather like today?",
             fallback: "Today looks partly cloudy, with a high of 75° and a low of 60°."),
        Step(said: "What's the best travel destination in 2026?",
             reply: """
             Here are three of the most talked-about picks for 2026:
             1. Lisbon, Portugal: sunny hills, historic trams and great food at good prices.
             2. Kyoto, Japan: temples, gardens and quiet traditional streets.
             3. Cape Town, South Africa: mountains, beaches and wine country close by.
             Lisbon comes out on top for its mix of culture, food and value.
             """),
        Step(said: "Search the number one spot in Safari and create an itinerary for a two-day trip.",
             wakes: false, action: .planTrip, pauseAfter: 3),
        Step(said: "Minimize Spotify and close Maps and Safari.",
             action: .tidyUp(minimize: ["Spotify"], close: ["Maps", "Safari"])),
        Step(said: "Save the itinerary to my Desktop and close it.", wakes: false, action: .saveItinerary),
        Step(said: "Switch to full view.", wakes: false, action: .fullView),
        Step(said: "How much storage is available? Based on my stats, where can I improve?",
             action: .storageAdvice),
        Step(said: "Thanks, Wanda!",
             reply: "You're welcome! Say “Hey Wanda” whenever you need me."),
    ]

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
