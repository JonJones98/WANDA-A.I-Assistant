//
//  WandaAPIClient.swift
//  Wanda
//

import Foundation

enum WandaAPIError: LocalizedError, Equatable {
    case serverUnreachable
    case serverFailed(String)
    case badStatus(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "I can't reach my server. Make sure it's running (uvicorn main:app --reload in the server folder)."
        case .serverFailed(let reason):
            return "I couldn't start my server. \(reason)"
        case .badStatus(let code):
            return "My server returned an error (HTTP \(code)). Check the server logs for details."
        case .unexpectedResponse:
            return "My server sent a reply I couldn't read."
        }
    }
}

struct ChatReply: Decodable {
    let chatID: String
    let response: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case response
    }
}

/// A Kokoro text-to-speech voice offered by the server.
struct KokoroVoice: Decodable, Equatable {
    let id: String
    let name: String
    let language: String
    let languageName: String
    let gender: String
    let recommended: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, language, gender, recommended
        case languageName = "language_name"
    }
}

struct WandaAPIClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8000")!

    var baseURL = WandaAPIClient.defaultBaseURL
    var session = URLSession.shared

    enum AppAction: String {
        case open
        case close
    }

    // MARK: Requests

    /// `context` describes the Mac's current state (time, music, app in use) for this
    /// question only; the server doesn't save it in the chat history.
    func chatRequest(message: String, chatID: String, context: String = "") throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("genAI/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_input": message, "chat_id": chatID, "context": context])
        return request
    }

    func appRequest(_ action: AppAction, app: String) -> URLRequest {
        URLRequest(url: url(path: action.rawValue, query: ["app": app]))
    }

    func speechRequest(text: String, voice: String, speed: Float) throws -> URLRequest {
        struct Body: Encodable { let text: String; let voice: String; let speed: Float }
        var request = URLRequest(url: baseURL.appendingPathComponent("tts/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(text: text, voice: voice, speed: speed))
        return request
    }

    func deleteHistoryRequest(chatID: String) -> URLRequest {
        var request = URLRequest(url: url(path: "db/chat_history/delete", query: ["id": chatID]))
        request.httpMethod = "DELETE"
        return request
    }

    // MARK: Calls

    func chat(message: String, chatID: String, context: String = "") async throws -> ChatReply {
        try decode(ChatReply.self, from: try await send(chatRequest(message: message, chatID: chatID, context: context)))
    }

    func runAppAction(_ action: AppAction, app: String) async throws -> String {
        struct Reply: Decodable { let response: String }
        return try decode(Reply.self, from: try await send(appRequest(action, app: app))).response
    }

    /// Deletes the server's copy of a chat.
    func deleteHistory(chatID: String) async throws {
        _ = try await send(deleteHistoryRequest(chatID: chatID))
    }

    func kokoroVoices() async throws -> [KokoroVoice] {
        struct Reply: Decodable { let voices: [KokoroVoice] }
        let request = URLRequest(url: baseURL.appendingPathComponent("tts/voices"))
        return try decode(Reply.self, from: try await send(request)).voices
    }

    /// WAV audio of `text` spoken by a Kokoro voice.
    func speech(text: String, voice: String, speed: Float) async throws -> Data {
        try await send(speechRequest(text: text, voice: voice, speed: speed))
    }

    // MARK: Helpers

    private func url(path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, but servers decode it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WandaAPIError.serverUnreachable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WandaAPIError.badStatus(http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WandaAPIError.unexpectedResponse
        }
    }
}
