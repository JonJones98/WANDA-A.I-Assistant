//
//  ReplyFormatting.swift
//  Wanda
//

import Foundation

/// Turns the chat model's Markdown and LaTeX into something that reads well in a chat
/// bubble (`display`) and sounds natural when read aloud (`MathText.spoken`).
enum ReplyFormatter {
    /// Markdown rendered inline (bold, italics, code, links), with bullets, headings
    /// and math made readable: `\[ A = \pi r^2 \]` becomes "A = πr²" on its own line.
    static func display(_ text: String) -> AttributedString {
        var result = MathText.replacingMath(in: text, block: { "\n" + MathText.unicode($0) + "\n" }, inline: MathText.unicode)
        let rules: [(pattern: String, replacement: String)] = [
            (#"(?m)^[ \t]*```[A-Za-z]*[ \t]*$\n?"#, ""),        // code fences
            (#"(?m)^[ \t]*#{1,6}[ \t]+(.+?)[ \t]*#*$"#, "**$1**"), // headings -> bold
            (#"(?m)^([ \t]*)[-*+][ \t]+"#, "$1• "),              // bullets
            (#"\n{3,}"#, "\n\n"),
        ]
        for rule in rules {
            result = result.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: result, options: options)) ?? AttributedString(result)
    }
}

enum MathText {
    // MARK: Finding math

    /// Replaces LaTeX math — `\[…\]` / `$$…$$` (block) and `\(…\)` (inline) — using the
    /// given converters. Single `$…$` is left alone so prices like "$5" survive.
    static func replacingMath(in text: String, block: (String) -> String, inline: (String) -> String) -> String {
        var result = text
        for pattern in [#"\\\[([\s\S]+?)\\\]"#, #"\$\$([\s\S]+?)\$\$"#] {
            result = replace(pattern, in: result, with: block)
        }
        return replace(#"\\\(([\s\S]+?)\\\)"#, in: result, with: inline)
    }

    // MARK: Display

    /// LaTeX math as plain Unicode: `4\pi r^2` → "4πr²", `\frac{a}{b}` → "a/b".
    static func unicode(_ latex: String) -> String {
        var s = latex
        s = repeatReplacing(#"\\(?:text|mathrm|textbf|mathbf|operatorname)\{([^{}]*)\}"#, in: s) { $0[0] }
        s = repeatReplacing(#"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, in: s) { groups in
            "\(wrapIfComplex(groups[0]))/\(wrapIfComplex(groups[1]))"
        }
        s = repeatReplacing(#"\\sqrt\{([^{}]*)\}"#, in: s) { "√" + wrapIfComplex($0[0]) }
        s = s.replacingOccurrences(of: #"\^\{?\\circ\}?"#, with: "°", options: .regularExpression)
        s = repeatReplacing(#"\^\{([^{}]*)\}"#, in: s) { superscript($0[0]) }
        s = repeatReplacing(#"\^([A-Za-z0-9])"#, in: s) { superscript($0[0]) }
        s = repeatReplacing(#"_\{([^{}]*)\}"#, in: s) { subscripted($0[0]) }
        s = repeatReplacing(#"_([A-Za-z0-9])"#, in: s) { subscripted($0[0]) }
        for (command, symbol) in symbols {
            s = s.replacingOccurrences(of: #"\\\#(command)(?![A-Za-z])"#, with: symbol, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\\(?:left|right)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\[,;:! ]|\\quad|\\qquad"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\([A-Za-z]+)"#, with: "$1", options: .regularExpression) // \sin -> sin
            .replacingOccurrences(of: #"[{}]"#, with: "", options: .regularExpression)
            // LaTeX ignores spaces in math: "π r²" should read "πr²".
            .replacingOccurrences(of: #"([πθαβΔ√])\s+(?=[A-Za-z0-9(])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[0-9A-Za-z)])\s+(?=[πθαβ])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Speech

    /// Text with math read the way a person would say it:
    /// `\[ A = \pi r^2 \]` → "A equals pi r squared.", "≈ 78.54" → "approximately 78.54".
    static func spoken(_ text: String) -> String {
        var s = replacingMath(in: text, block: { " " + spokenMath($0) + ". " }, inline: spokenMath)
        // Unicode math written as plain text (e.g. "A = πr²").
        for (symbol, words) in spokenSymbols {
            s = s.replacingOccurrences(of: symbol, with: " \(words) ")
        }
        return s.replacingOccurrences(of: #"(?<=\S)[ \t]+=[ \t]+(?=\S)"#, with: " equals ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
    }

    private static func spokenMath(_ latex: String) -> String {
        var s = latex
        s = repeatReplacing(#"\\(?:text|mathrm|textbf|mathbf|operatorname)\{([^{}]*)\}"#, in: s) { " \($0[0]) " }
        s = repeatReplacing(#"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, in: s) { " \($0[0]) over \($0[1]) " }
        s = repeatReplacing(#"\\sqrt\{([^{}]*)\}"#, in: s) { " the square root of \($0[0]) " }
        s = s.replacingOccurrences(of: #"\^\{?\\circ\}?"#, with: " degrees", options: .regularExpression)
        s = repeatReplacing(#"\^\{([^{}]*)\}"#, in: s) { spokenPower($0[0]) }
        s = repeatReplacing(#"\^([A-Za-z0-9])"#, in: s) { spokenPower($0[0]) }
        s = repeatReplacing(#"_\{?([^{}\s]+?)\}?(?=\W|$)"#, in: s) { " \($0[0]) " }
        for (command, words) in spokenCommands {
            s = s.replacingOccurrences(of: #"\\\#(command)(?![A-Za-z])"#, with: " \(words) ", options: .regularExpression)
        }
        for (symbol, words) in spokenSymbols + [("=", "equals"), ("+", "plus"), ("-", "minus"), ("/", "over")] {
            s = s.replacingOccurrences(of: symbol, with: " \(words) ")
        }
        s = s.replacingOccurrences(of: #"\\(?:left|right)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\[,;:! ]|\\quad|\\qquad"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\([A-Za-z]+)"#, with: " $1 ", options: .regularExpression)
            .replacingOccurrences(of: #"[{}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Tables

    private static let symbols: [(String, String)] = [
        ("times", "×"), ("cdot", "·"), ("div", "÷"), ("approx", "≈"), ("neq", "≠"), ("ne", "≠"),
        ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"), ("pm", "±"), ("infty", "∞"),
        ("pi", "π"), ("theta", "θ"), ("alpha", "α"), ("beta", "β"), ("Delta", "Δ"), ("sum", "Σ"),
        ("degree", "°"), ("rightarrow", "→"), ("to", "→"),
    ]

    private static let spokenCommands: [(String, String)] = [
        ("times", "times"), ("cdot", "times"), ("div", "divided by"), ("approx", "is approximately"),
        ("neq", "is not equal to"), ("ne", "is not equal to"), ("leq", "is less than or equal to"),
        ("le", "is less than or equal to"), ("geq", "is greater than or equal to"),
        ("ge", "is greater than or equal to"), ("pm", "plus or minus"), ("infty", "infinity"),
        ("pi", "pi"), ("theta", "theta"), ("alpha", "alpha"), ("beta", "beta"), ("Delta", "delta"),
        ("sum", "the sum of"), ("degree", "degrees"), ("rightarrow", "gives"), ("to", "to"),
    ]

    private static let spokenSymbols: [(String, String)] = [
        ("²", "squared"), ("³", "cubed"), ("π", "pi"), ("×", "times"), ("·", "times"), ("÷", "divided by"),
        ("≈", "is approximately"), ("≠", "is not equal to"), ("≤", "is less than or equal to"),
        ("≥", "is greater than or equal to"), ("±", "plus or minus"), ("∞", "infinity"),
        ("√", "the square root of"), ("°", "degrees"), ("→", "gives"), ("−", "minus"),
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋",
    ]

    // MARK: Helpers

    private static func spokenPower(_ exponent: String) -> String {
        switch exponent.trimmingCharacters(in: .whitespaces) {
        case "2": return " squared "
        case "3": return " cubed "
        case let other: return " to the power of \(other) "
        }
    }

    private static func superscript(_ text: String) -> String {
        let mapped = text.compactMap { superscripts[$0] }
        return mapped.count == text.count ? String(mapped) : "^(\(text))"
    }

    private static func subscripted(_ text: String) -> String {
        let mapped = text.compactMap { subscripts[$0] }
        return mapped.count == text.count ? String(mapped) : "_\(text)"
    }

    private static func wrapIfComplex(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^[A-Za-z0-9.πθαβ²³]+$"#, options: .regularExpression) != nil ? trimmed : "(\(trimmed))"
    }

    private static func replace(_ pattern: String, in text: String, with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(whole, with: transform(String(result[inner])))
        }
        return result
    }

    /// Applies a regex replacement until nothing changes, so nested braces resolve from
    /// the inside out.
    private static func repeatReplacing(_ pattern: String, in text: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for _ in 0..<10 {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            guard !matches.isEmpty else { break }
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result) else { continue }
                let groups = (1..<match.numberOfRanges).map { index -> String in
                    Range(match.range(at: index), in: result).map { String(result[$0]) } ?? ""
                }
                result.replaceSubrange(whole, with: transform(groups))
            }
        }
        return result
    }
}
