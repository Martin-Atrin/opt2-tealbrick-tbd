import Foundation

/// Deterministic post-processing for dictated text: filler removal, vocabulary, snippets,
/// spoken punctuation and whitespace.
public struct TBDTextPipeline: Sendable {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let expandedSnippetIDs: Set<String>
    }

    public init() {}

    /// `mode == .raw` returns the input untouched (v1: Raw skips the whole pipeline). Spoken punctuation can be
    /// switched off on its own; it never runs in Raw.
    public func process(_ text: String, customWords: [TBDCustomWord] = [], snippets: [TBDSnippet] = [],
                        removeFillers: Bool = true, mode: TBDProcessingMode = .clean, spokenPunctuation: Bool = true) -> Result {
        guard mode == .clean else { return Result(text: text, expandedSnippetIDs: []) }
        guard !text.isEmpty else { return Result(text: "", expandedSnippetIDs: []) }
        var result = removeFillers ? Self.removeFillers(text) : text
        result = Self.applyCustomWords(result, words: customWords)
        let expanded = Self.expandSnippets(result, snippets: snippets)
        result = spokenPunctuation ? Self.spokenPunctuation(expanded.text) : expanded.text
        return Result(text: Self.cleanWhitespace(result), expandedSnippetIDs: expanded.ids)
    }

    // MARK: Steps

    private static let fillerRegex = try! NSRegularExpression(pattern: "\\b(?:um+|uh+|erm|hmm+)\\b[,.]?", options: .caseInsensitive)

    static func removeFillers(_ text: String) -> String {
        var result = replace(fillerRegex, in: text, with: "")
        result = replace(try! NSRegularExpression(pattern: ",\\s*,+"), in: result, with: ",")
        result = replace(try! NSRegularExpression(pattern: "([.!?])[ \\t]+,[ \\t]*"), in: result, with: "$1 ")
        result = replace(try! NSRegularExpression(pattern: "^\\s*[,.]\\s*", options: .anchorsMatchLines), in: result, with: "")
        return result
    }

    /// Whole-word, case-insensitive replacements in order. A blank replacement re-cases the word itself.
    static func applyCustomWords(_ text: String, words: [TBDCustomWord]) -> String {
        words.filter(\.isEnabled).reduce(text) { result, word in
            let source = word.word.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty,
                  let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: source))\\b",
                                                       options: .caseInsensitive) else { return result }
            let target = word.replacement?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? source
            return replace(regex, in: result, with: NSRegularExpression.escapedTemplate(for: target))
        }
    }

    /// Longest trigger first so "my address" wins over "address".
    static func expandSnippets(_ text: String, snippets: [TBDSnippet]) -> (text: String, ids: Set<String>) {
        var result = text
        var ids = Set<String>()
        for snippet in snippets.filter({ $0.isEnabled && $0.action == nil && !$0.trigger.isEmpty }).sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: snippet.trigger).replacingOccurrences(of: " ", with: "\\s+"))\\b[.!?]?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            guard regex.firstMatch(in: result, range: range) != nil else { continue }
            ids.insert(snippet.id)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion))
        }
        return (result, ids)
    }

    private static let spoken: [(String, String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"), ("question mark", "?"), ("exclamation mark", "!"),
        ("exclamation point", "!"), ("full stop", "."), ("open parenthesis", "("), ("close parenthesis", ")"),
    ]

    /// Explicit spoken commands only ("new line", "question mark"); bare words like "period" are left alone.
    static func spokenPunctuation(_ text: String) -> String {
        spoken.reduce(text) { result, pair in
            guard let regex = try? NSRegularExpression(pattern: "[,.]?\\s*\\b\(pair.0)\\b[,.]?", options: .caseInsensitive) else { return result }
            let template = pair.1.hasPrefix("\n") || pair.1 == "(" ? " \(pair.1)" : pair.1
            return replace(regex, in: result, with: NSRegularExpression.escapedTemplate(for: template))
        }
    }

    static func cleanWhitespace(_ text: String) -> String {
        var result = replace(try! NSRegularExpression(pattern: "[ \\t]{2,}"), in: text, with: " ")
        result = replace(try! NSRegularExpression(pattern: " *(\n+) *"), in: result, with: "$1")
        result = replace(try! NSRegularExpression(pattern: "[ \\t]+([.!?,;:)])"), in: result, with: "$1")
        result = replace(try! NSRegularExpression(pattern: "\\( +"), in: result, with: "(")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, first.isLowercase { result = first.uppercased() + result.dropFirst() }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
