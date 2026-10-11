import Foundation

/// Stable JSON shapes for `tbd-listen` and the JSON export. Keys are sorted; dates are ISO 8601.
/// Add fields only; never rename or remove them (agents depend on this contract).
public enum TBDListenJSON {
    public static let schemaVersion = 1

    public struct Segment: Codable, Equatable {
        public let start: Int, end: Int, speaker: String?, text: String
    }

    public struct Word: Codable, Equatable {
        public let start: Int, end: Int, speaker: String?, text: String, confidence: Double
    }

    public struct Item: Codable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public let status: String
        public let createdAt: Date
        public let durationMs: Int
        public let language: String?
        public let engine: String?
        public let preview: String

        public init(_ t: TBDTranscription) {
            id = t.id; title = t.title; kind = t.sourceKind.rawValue; status = t.status.rawValue; createdAt = t.createdAt
            durationMs = t.durationMs; language = t.language; engine = t.engine
            preview = String(t.text.prefix(200))
        }
    }

    public struct Summary: Codable, Equatable {
        public let kind: String, prompt: String, content: String, createdAt: Date
    }

    public struct Detail: Codable, Equatable {
        public let schemaVersion: Int
        public let id: String
        public let title: String
        public let kind: String
        public let status: String
        public let createdAt: Date
        public let durationMs: Int
        public let language: String?
        public let engine: String?
        public let sourcePath: String?
        public let sourceURL: String?
        public let text: String
        public let rawText: String
        public let cleanText: String?
        public let speakers: [TBDSpeaker]
        public let segments: [Segment]
        public let words: [Word]
        public let audioPaths: [String]
        public let summaries: [Summary]
        public let error: String?

        public init(_ t: TBDTranscription, summaries: [TBDSummary] = []) {
            schemaVersion = TBDListenJSON.schemaVersion
            id = t.id; title = t.title; kind = t.sourceKind.rawValue; status = t.status.rawValue; createdAt = t.createdAt
            durationMs = t.durationMs; language = t.language; engine = t.engine; sourcePath = t.sourcePath; sourceURL = t.sourceURL
            text = t.text; rawText = t.rawText; cleanText = t.cleanText; speakers = t.speakers
            segments = TBDExport.displaySegments(t).map { Segment(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text) }
            words = t.words.map { Word(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text, confidence: $0.confidence) }
            audioPaths = t.audioPaths
            self.summaries = summaries.map { Summary(kind: $0.kind.rawValue, prompt: $0.prompt, content: $0.content, createdAt: $0.createdAt) }
            error = t.errorMessage
        }
    }

    public struct Dictation: Codable, Equatable {
        public let id: String
        public let createdAt: Date
        public let durationMs: Int
        public let text: String
        public let rawText: String
        public let targetApp: String?
        public let wordCount: Int

        public init(_ d: TBDDictation) {
            id = d.id; createdAt = d.createdAt; durationMs = d.durationMs; text = d.text; rawText = d.rawText
            targetApp = d.targetApp; wordCount = d.wordCount
        }
    }

    /// Result of `tbd-listen transcribe --json`.
    public struct TranscribeResult: Codable, Equatable {
        public let schemaVersion: Int
        public let id: String?
        public let file: String
        public let text: String
        public let durationMs: Int
        public let language: String?
        public let engine: String
        public let speakers: [TBDSpeaker]
        public let segments: [Segment]
        public let words: [Word]

        public init(file: String, transcription: TBDTranscription) {
            schemaVersion = TBDListenJSON.schemaVersion
            id = transcription.id; self.file = file; text = transcription.text; durationMs = transcription.durationMs
            language = transcription.language; engine = transcription.engine ?? ""; speakers = transcription.speakers
            segments = TBDExport.displaySegments(transcription).map { Segment(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text) }
            words = transcription.words.map { Word(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text, confidence: $0.confidence) }
        }
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
