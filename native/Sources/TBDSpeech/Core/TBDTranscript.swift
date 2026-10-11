import Foundation

/// A recognised word with millisecond timing.
public struct TBDWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Int
    public var end: Int
    public var confidence: Double
    public var speaker: String?
    public init(text: String, start: Int, end: Int, confidence: Double = 1, speaker: String? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence; self.speaker = speaker
    }
}

/// A display segment (sentence or speaker turn).
public struct TBDSegment: Codable, Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var text: String
    public var speaker: String?
    public init(start: Int, end: Int, text: String, speaker: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker
    }
}

public struct TBDSpeaker: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// Engine output for one audio input.
public struct TBDTranscript: Sendable, Equatable {
    public var text: String
    public var words: [TBDWord]
    public var language: String?
    public var engine: String
    public var durationMs: Int
    public init(text: String, words: [TBDWord] = [], language: String? = nil, engine: String, durationMs: Int = 0) {
        self.text = text; self.words = words; self.language = language; self.engine = engine; self.durationMs = durationMs
    }
}

public enum TBDSpeechError: Error, LocalizedError, Equatable {
    case modelNotDownloaded(String)
    case engineFailed(String)
    case audioUnreadable(String)
    case microphoneDenied
    case microphoneUnavailable(String)
    case dropped
    case busy(String)
    case toolMissing(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name): return "\(name) is not downloaded. Download it in Settings → Listening → Engine."
        case .engineFailed(let message): return "Transcription failed: \(message)"
        case .audioUnreadable(let message): return "The audio could not be read: \(message)"
        case .microphoneDenied: return "Microphone permission is required."
        case .microphoneUnavailable(let message): return "The microphone could not start: \(message)"
        case .dropped: return "The speech job was dropped because the queue was full."
        case .busy(let what): return "\(what) is already in progress."
        case .toolMissing(let tool): return "\(tool) was not found on your PATH."
        }
    }
}

extension TBDTranscript {
    /// Text with a trailing tidy-up; engines sometimes emit leading spaces.
    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
