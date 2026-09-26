//
//  ChatMessage.swift
//  Wanda
//

import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Sender: String, Codable {
        case user
        case wanda
        case error
    }

    let id: UUID
    let text: String
    let sender: Sender
    /// nil for messages restored from chat history, which the server stores without times.
    let date: Date?
    /// True when Wanda answered on the Mac without calling the AI.
    let isLocal: Bool

    init(id: UUID = UUID(), text: String, sender: Sender, date: Date? = Date(), isLocal: Bool = false) {
        self.id = id
        self.text = text
        self.sender = sender
        self.date = date
        self.isLocal = isLocal
    }
}
