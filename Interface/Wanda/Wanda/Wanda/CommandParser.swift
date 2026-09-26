//
//  CommandParser.swift
//  Wanda
//

import Foundation

enum WandaCommand: Equatable {
    case open(app: String)
    case close(app: String)
    case chat(String)
}

enum CommandParser {
    /// Only the first word can be a command, so "can you open up about X" stays a chat message.
    static func parse(_ text: String) -> WandaCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return .chat(trimmed) }

        let app = parts[1].trimmingCharacters(in: .whitespaces)
        switch parts[0].lowercased() {
        case "open", "launch":
            return .open(app: app)
        case "close", "quit":
            return .close(app: app)
        default:
            return .chat(trimmed)
        }
    }
}
