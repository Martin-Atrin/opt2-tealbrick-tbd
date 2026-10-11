import Foundation
import TBDModels

public struct TBDCleanupResult: Sendable, Equatable {
    public let raw: String
    public let text: String
    public let warning: String
}

/// Optional LLM transcript cleanup. Disabled means no model call and no network request.
/// The raw transcript is never discarded: failures fall back to it with a warning.
public enum TBDCleanup {
    public static func apply(raw: String, enabled: Bool, formatter: (String) async throws -> String) async throws -> TBDCleanupResult {
        guard enabled, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TBDCleanupResult(raw: raw, text: raw, warning: "")
        }
        do {
            let text = try await formatter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return TBDCleanupResult(raw: raw, text: raw, warning: "Cleanup returned no text; kept raw transcript.") }
            return TBDCleanupResult(raw: raw, text: text, warning: "")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TBDCleanupResult(raw: raw, text: raw, warning: "Cleanup unavailable; kept raw transcript.")
        }
    }

    /// Formatter backed by the "cleanup" model route.
    public static func modelFormatter(prompt: String = TBDListeningPreferences().cleanupPrompt) -> (String) async throws -> String {
        { text in
            try await TBDChatClient.forTask(.cleanup).complete([
                TBDChatMessage(.system, prompt),
                TBDChatMessage(.user, text),
            ], temperature: 0)
        }
    }
}

/// Model calls for the library (route "analysis") and transforms (route "general").
public enum TBDListeningAI {
    /// Transcripts beyond this many characters are truncated for the model with a note.
    static let contextLimit = 120_000

    static func context(_ transcription: TBDTranscription) -> String {
        let body: String
        if transcription.segments.contains(where: { $0.speaker != nil }) {
            body = transcription.segments.map { segment in
                let who = transcription.speakerLabel(segment.speaker).map { "\($0): " } ?? ""
                return "[\(TBDExport.clock(segment.start))] \(who)\(segment.text)"
            }.joined(separator: "\n")
        } else {
            body = transcription.text
        }
        guard body.count > contextLimit else { return body }
        return String(body.prefix(contextLimit)) + "\n[Transcript truncated]"
    }

    public static func summarize(_ transcription: TBDTranscription, prompt: String) async throws -> String {
        try await TBDChatClient.forTask(.analysis).complete([
            TBDChatMessage(.system, prompt),
            TBDChatMessage(.user, "Title: \(transcription.title)\n\nTranscript:\n\(context(transcription))"),
        ])
    }

    public static func ask(_ question: String, about transcription: TBDTranscription) async throws -> String {
        try await TBDChatClient.forTask(.analysis).complete([
            TBDChatMessage(.system, "Answer questions about the transcript below. Quote timestamps when useful. Say so when the transcript does not contain the answer."),
            TBDChatMessage(.user, "Transcript:\n\(context(transcription))\n\nQuestion: \(question)"),
        ])
    }

    public static func transform(_ text: String, instruction: String) async throws -> String {
        try await TBDChatClient.forTask(.general).complete([
            TBDChatMessage(.system, "\(instruction)\nReturn only the resulting text, with no preamble, quotes or explanation."),
            TBDChatMessage(.user, text),
        ])
    }
}
