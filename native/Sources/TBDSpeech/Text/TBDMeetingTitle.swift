import Foundation
import TBDModels

// Automatic meeting titles (v1 `MeetingTitleGenerator` and the `autoGenerateMeetingTitles` setting).
// Pure rules live here so every limit has an exact-value test; the meeting controller only wires them.
//
// Order (same as v1): the title is made when the final transcript is ready and BEFORE the "transcript saved"
// announcement, so auto-save to a folder, the ready notice and Knowledge see the final title.

public extension TBDListeningPreferences {
    /// v1 `autoGenerateMeetingTitles` (default on). Needs a model on the Analysis route to do anything.
    static let autoGenerateMeetingTitlesKey = "tbd.listening.autoGenerateMeetingTitles"

    var autoGenerateMeetingTitles: Bool {
        get { defaults.object(forKey: Self.autoGenerateMeetingTitlesKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoGenerateMeetingTitlesKey) }
    }
}

public enum TBDMeetingTitle {
    public static let minimumTranscriptWords = 12
    public static let maximumPromptTranscriptCharacters = 24_000
    public static let minimumTitleWords = 2
    public static let maximumTitleWords = 8
    public static let maximumTitleCharacters = 70
    /// Reply budget: a title is a few words, with room for models that spend tokens thinking first.
    public static let maximumReplyTokens = 256

    public static let systemPrompt = """
    Generate a concise title for this meeting transcript.

    Rules:
    - Return only the title. Do not include quotes, markdown, JSON, or explanation.
    - Use 2 to 8 words.
    - Name the concrete topic of the meeting.
    - Do not use generic titles like "Meeting", "Discussion", "Transcript", or a date/time.
    - If the transcript does not have enough context for a useful topic title, return NO_TITLE.
    """

    /// The model call: the rules as system prompt, the (shortened) transcript as the user message.
    public static func request(transcript: String) -> TBDCompletionRequest {
        TBDCompletionRequest(task: .analysis,
                             messages: [TBDChatMessage(.system, systemPrompt),
                                        TBDChatMessage(.user, "Transcript:\n" + truncatedForPrompt(normalizedWhitespace(transcript)))],
                             maxTokens: maximumReplyTokens)
    }

    /// A generated title for the transcript, or nil when none should replace `currentTitle`: the current title
    /// is not a fallback, the transcript is too short, the model failed, or its answer is not a usable title.
    /// Cancellation is passed on; every other model error means "no title" (the fallback stays).
    public static func generate(transcript: String, currentTitle: String, complete: TBDCompleter = TBDCompleters.live) async throws -> String? {
        guard shouldReplaceFallback(currentTitle) else { return nil }
        let text = normalizedWhitespace(transcript)
        guard hasEnoughContext(text) else { return nil }
        do {
            return validated(from: try await complete(request(transcript: text)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// True for the titles TBD makes itself when nothing better is known: "Meeting" and "Meeting <date and time>".
    /// A title the person set, or a calendar event title, is never replaced.
    public static func shouldReplaceFallback(_ title: String) -> Bool {
        let normalized = normalizedWhitespace(title)
        guard normalized.localizedCaseInsensitiveCompare("Meeting") != .orderedSame else { return true }
        guard normalized.lowercased().hasPrefix("meeting ") else { return false }
        // The fallback ("Meeting Jun 17, 2026 at 09:59") always has a month name AND a clock time, so those (and
        // slash dates) are matched. A bare year is deliberately not: "Meeting 2026 Budget Planning" is a real title.
        let fallbackDatePattern = #"(?i)\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"#
        return normalized.range(of: fallbackDatePattern, options: .regularExpression) != nil
    }

    /// Cleans the model's answer and checks it: one line, 2 to 8 words, at most 70 characters, not generic,
    /// no date or time, not the NO_TITLE answer.
    public static func validated(from rawTitle: String) -> String? {
        let lines = rawTitle.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }

        var title = lines[0]
            .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = stripWrappingQuotes(from: title)
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:;!?")))
        title = normalizedWhitespace(title)

        guard !title.isEmpty, title.count <= maximumTitleCharacters else { return nil }
        let words = title.split(whereSeparator: \.isWhitespace)
        guard words.count >= minimumTitleWords, words.count <= maximumTitleWords else { return nil }

        let lowercased = title.lowercased()
        guard !genericTitles.contains(lowercased), !lowercased.contains("not enough context") else { return nil }
        let dateLikePattern = #"(?i)\b20\d{2}\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"#
        guard title.range(of: dateLikePattern, options: .regularExpression) == nil else { return nil }
        return title
    }

    static let genericTitles: Set<String> = [
        "meeting", "meeting notes", "meeting discussion", "discussion", "transcript", "transcription", "summary",
        "conversation", "call", "audio transcript", "no_title", "no title", "not enough context",
    ]

    public static func hasEnoughContext(_ transcript: String) -> Bool {
        transcript.split(whereSeparator: \.isWhitespace).count >= minimumTranscriptWords
    }

    /// Long transcripts keep their start and end (12,000 characters each) with `[...]` between.
    public static func truncatedForPrompt(_ transcript: String) -> String {
        guard transcript.count > maximumPromptTranscriptCharacters else { return transcript }
        let half = maximumPromptTranscriptCharacters / 2
        return "\(transcript.prefix(half))\n\n[...]\n\n\(transcript.suffix(half))"
    }

    static func normalizedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func stripWrappingQuotes(from text: String) -> String {
        var result = text
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs where result.first == open && result.last == close && result.count >= 2 {
                result.removeFirst()
                result.removeLast()
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return result
    }
}

public extension TBDListeningDatabase {
    /// Gives a meeting its generated title, unless the stored title is no longer a fallback (the person renamed
    /// it meanwhile). Returns whether the title changed.
    @discardableResult
    func applyGeneratedMeetingTitle(_ title: String, to id: String) throws -> Bool {
        try writer.write { db in
            guard let stored = try String.fetchOne(db, sql: "SELECT title FROM transcription WHERE id = ? AND sourceKind = 'meeting'", arguments: [id]),
                  TBDMeetingTitle.shouldReplaceFallback(stored) else { return false }
            try db.execute(sql: "UPDATE transcription SET title = ?, updatedAt = ? WHERE id = ?", arguments: [title, Date(), id])
            return true
        }
    }
}
