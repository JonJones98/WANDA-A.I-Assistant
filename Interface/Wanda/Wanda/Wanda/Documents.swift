//
//  Documents.swift
//  Wanda
//

import AppKit

/// "Create an itinerary for Paris and save it to Documents", "write a packing list and
/// save it", "make a document about …", or "save that to Documents" (Wanda's last answer).
enum DocumentRequest: Equatable {
    /// Have the AI write this (the whole request, e.g. "a 3-day itinerary for Tokyo").
    case write(String)
    /// Save Wanda's previous answer as it is.
    case saveLastReply

    static func parse(_ text: String) -> DocumentRequest? {
        let s = LocalIntentParser.normalize(text)
        let place = #"( (to|in|into|as|under) (my |the |a |an )?(documents( folder)?|docs|document|doc|file|text file|note))?"#
        if s.range(of: #"^(save|store|keep|put) (that|this|it|your (last )?(answer|reply|response)|the (last )?(answer|reply|response))"# + place + "$",
                   options: .regularExpression) != nil {
            return .saveLastReply
        }
        let verb = #"^(create|write|make|draft|generate|put together|prepare)( me)? "#
        guard s.range(of: verb, options: .regularExpression) != nil else { return nil }
        let savesIt = s.range(of: #" (and )?(save|store|keep|put) (it|that|this|them)?"# + place + "$", options: .regularExpression) != nil
            || s.range(of: #" (save|saved) (to|in|into) (my |the )?(documents|docs)"#, options: .regularExpression) != nil
        let asDocument = s.range(of: verb + #"(a |an |the |my )?(new )?(document|doc|file|text file|note)\b"#, options: .regularExpression) != nil
        return savesIt || asDocument ? .write(text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    /// What the AI is asked, so its answer is the document itself and reads well as plain text.
    static func prompt(for request: String) -> String {
        """
        The user asked: "\(request)"
        Write that document now; it will be saved as a plain text file, not read aloud, so \
        ignore the usual advice to keep replies short and make it complete and genuinely \
        useful, with specific details. Put a short title on \
        the first line. Use headings in capital letters, "•" for bullet points and blank \
        lines between sections. No Markdown symbols (#, *, **), no LaTeX, no tables. Reply \
        with only the document: no introduction, no closing remarks.
        """
    }
}

/// Saves text as a document in Documents and opens it in TextEdit.
enum DocumentSaver {
    struct SavedDocument {
        let url: URL
        let title: String
    }

    /// Saves `text`, named after its first line (or `name`), without replacing an
    /// existing file: "Title.txt", then "Title 2.txt", …
    static func save(
        _ text: String, name: String? = nil,
        in folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    ) throws -> SavedDocument {
        let body = plainText(text)
        let title = name ?? title(of: body)
        let base = fileName(title)
        var url = folder.appendingPathComponent(base + ".txt")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(copy).txt")
            copy += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        return SavedDocument(url: url, title: title)
    }

    /// Opens a saved document in TextEdit (or the default app for text files).
    static func open(_ url: URL, activates: Bool = true) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        if let textEdit = WindowArranger.findApp("TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: configuration, completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Removes Markdown the AI may still use: headings become capitals, bold marks go,
    /// "-" and "*" bullets become "•", and math becomes readable symbols.
    static func plainText(_ text: String) -> String {
        var lines: [String] = []
        let text = MathText.replacingMath(in: text, block: { "\n" + MathText.unicode($0) + "\n" }, inline: MathText.unicode)
        for line in text.components(separatedBy: .newlines) {
            var line = line
            if let heading = line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                line = String(line[heading.upperBound...]).uppercased()
            }
            line = line
                .replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
                .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first line, without a "Title:" label, if it's short enough to be a title.
    static func title(of text: String) -> String {
        let first = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let title = first
            .replacingOccurrences(of: #"^\s*(title|document)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else {
            return "Wanda Document \(Date().formatted(.dateTime.year().month().day()))"
        }
        return title
    }

    /// A title made safe for a file name.
    static func fileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return cleaned.isEmpty ? "Wanda Document" : String(cleaned.prefix(80))
    }
}
