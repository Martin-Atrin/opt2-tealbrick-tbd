import Foundation
import TBDModels
import TBDSpeech

/// One "Save to Knowledge" request (WP10). The host sends it to the Chat helper, which calls
/// Knowledge `document_create` as TBD's OWN agent (key connection and local relay), never with the
/// person's token. Source URL and date are not document fields: they live in the body header and
/// the summary.
public struct TBDKnowledgeSaveRequest: Sendable, Equatable {
    public var transcriptId: String
    public var title: String
    public var body: String
    public var summary: String
    public var tags: [String]

    public init(transcriptId: String, title: String, body: String, summary: String, tags: [String]) {
        self.transcriptId = transcriptId; self.title = title; self.body = body; self.summary = summary; self.tags = tags
    }

    /// The argument of the helper channel `studio:knowledgeSave`.
    public var payload: [String: Any] {
        ["transcriptId": transcriptId, "title": title, "body": body, "summary": summary, "tags": tags]
    }
}

public struct TBDKnowledgeSaveResult: Sendable, Equatable {
    public var documentId: String
    public var area: String?

    public init(documentId: String, area: String? = nil) { self.documentId = documentId; self.area = area }

    /// The helper's reply (`{ documentId, area? }`), or nil when it has no document id.
    public init?(payload: Any) {
        guard let object = payload as? [String: Any], let id = object["documentId"] as? String, !id.isEmpty else { return nil }
        self.init(documentId: id, area: object["area"] as? String)
    }
}

/// Set by the host: sends the request to the Chat helper and reports progress
/// ("Waiting for owner approval") through the second argument.
public typealias TBDKnowledgeSaver = @MainActor (TBDKnowledgeSaveRequest, @escaping @MainActor (String) -> Void) async throws -> TBDKnowledgeSaveResult

/// A plain failure message for the person (L3).
public struct TBDKnowledgeError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let signIn = TBDKnowledgeError("Sign in to Teal Brick in TBD first.")
}

/// Builds the Knowledge document for a transcript: a short header block, then the transcript text.
enum TBDKnowledgeDocument {
    static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// `Source:` (links only), `Date:`, `Kind:`, `Duration:` (when known).
    static func header(_ item: TBDTranscription, timeZone: TimeZone = .current) -> [String] {
        var lines: [String] = []
        if let link = item.sourceURL, !link.isEmpty { lines.append("Source: \(link)") }
        lines.append("Date: \(dateText(item.createdAt, timeZone: timeZone))")
        lines.append("Kind: \(item.sourceKind.label)")
        if item.durationMs > 0 { lines.append("Duration: \(TBDExport.clock(item.durationMs))") }
        return lines
    }

    /// One line for the document summary: kind, date, duration, source URL.
    static func summary(_ item: TBDTranscription, timeZone: TimeZone = .current) -> String {
        var parts = [item.sourceKind.label, dateText(item.createdAt, timeZone: timeZone)]
        if item.durationMs > 0 { parts.append(TBDExport.clock(item.durationMs)) }
        if let link = item.sourceURL, !link.isEmpty { parts.append(link) }
        return parts.joined(separator: " · ")
    }

    static func request(for item: TBDTranscription, title: String, tags: [String], timeZone: TimeZone = .current) -> TBDKnowledgeSaveRequest {
        let text = TBDExport.render(item, as: .txt).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = header(item, timeZone: timeZone).joined(separator: "\n") + "\n\n" + text
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return TBDKnowledgeSaveRequest(transcriptId: item.id, title: trimmed.isEmpty ? item.title : trimmed, body: body,
                                       summary: summary(item, timeZone: timeZone), tags: TBDKnowledgeTags.normalize(tags))
    }
}

/// Topic tags: suggested by the "analysis" model route (the one summaries use) when one is assigned,
/// otherwise none. Knowledge allows 20 tags of up to 40 characters.
enum TBDKnowledgeTags {
    static let maxSuggested = 5

    /// Lower case, hyphenated, without `#` or list marks, deduplicated, at most 20 of up to 40 characters.
    static func normalize(_ tags: [String]) -> [String] {
        var out: [String] = []
        for raw in tags {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(?:[#*•-]+|\d+[.)])\s*"#, with: "", options: .regularExpression)
            tag = tag.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
            tag = String(tag.prefix(40))
            if !tag.isEmpty, !out.contains(tag), out.count < 20 { out.append(tag) }
        }
        return out
    }

    /// Tags from a model reply ("planning, budget, q3" or one per line).
    static func parse(_ reply: String) -> [String] {
        Array(normalize(reply.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).map(String.init)).prefix(maxSuggested))
    }

    /// Empty when no model is assigned or the model fails: suggestions are optional.
    static func suggest(_ item: TBDTranscription) async -> [String] {
        guard TBDMeetingAsk.available, !item.text.isEmpty else { return [] }
        do {
            let reply = try await TBDChatClient.forTask(.analysis).complete([
                TBDChatMessage(.system, "Suggest up to \(maxSuggested) short topic tags for this transcript. Return only the tags, lower case, separated by commas."),
                TBDChatMessage(.user, "Title: \(item.title)\n\nTranscript:\n\(String(item.text.prefix(8_000)))"),
            ], temperature: 0)
            return parse(reply)
        } catch {
            return []
        }
    }
}
