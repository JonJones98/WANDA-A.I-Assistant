//
//  ChatStore.swift
//  Wanda
//

import Foundation

/// One saved chat.
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    /// The server's ID for this chat, so the AI keeps its context; empty until the AI
    /// first replies.
    var serverChatID: String
    let createdAt: Date
    var updatedAt: Date

    /// A title from the first thing the user said, so naming a chat costs no AI tokens.
    static func title(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.sender == .user })?.text else { return "New chat" }
        let singleLine = WakePhrase.strip(from: first)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !singleLine.isEmpty else { return "New chat" }
        return singleLine.count > 40 ? String(singleLine.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : singleLine
    }
}

/// Saves chats on this Mac as JSON in Application Support, so history works even when
/// the server's database doesn't.
@MainActor
final class ChatStore: ObservableObject {
    /// Newest first.
    @Published private(set) var conversations: [Conversation] = []

    private let fileURL: URL

    nonisolated static let defaultFileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wanda/conversations.json")

    init(fileURL: URL = ChatStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    func conversation(_ id: UUID?) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// Inserts or replaces a chat and moves it to the top.
    func save(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        write()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = trimmed
        write()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        write()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        conversations = ((try? decoder.decode([Conversation].self, from: data)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(conversations) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
