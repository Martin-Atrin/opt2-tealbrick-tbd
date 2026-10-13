import Foundation
import GRDB

public func tbdNewID() -> String { UUID().uuidString.lowercased() }

/// What produced a dictation record.
public enum TBDDictationKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case dictation, voiceNote, chat

    /// Kind inferred from the target app label older records carry.
    public static func inferred(targetApp: String?) -> TBDDictationKind {
        switch targetApp {
        case "TBD Voice note": .voiceNote
        case "TBD Chat": .chat
        default: .dictation
        }
    }
}

/// How a dictation ended. `cancelled` rows exist only with "Preserve discarded dictations" (nothing was pasted).
public enum TBDDictationStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case completed, cancelled
}

/// A dictation, voice note or chat dictation. Raw text is always kept.
public struct TBDDictation: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictation"
    public var id: String
    public var createdAt: Date
    public var durationMs: Int
    public var rawText: String
    public var cleanText: String?
    /// App the text was pasted into, or "TBD Voice note" / "TBD Chat".
    public var targetApp: String?
    public var audioPath: String?
    public var engine: String?
    public var wordCount: Int
    public var kind: TBDDictationKind
    public var status: TBDDictationStatus = .completed

    public init(id: String = tbdNewID(), createdAt: Date = Date(), durationMs: Int, rawText: String, cleanText: String? = nil,
                targetApp: String? = nil, audioPath: String? = nil, engine: String? = nil, kind: TBDDictationKind? = nil) {
        self.id = id; self.createdAt = createdAt; self.durationMs = durationMs; self.rawText = rawText
        self.cleanText = cleanText; self.targetApp = targetApp; self.audioPath = audioPath; self.engine = engine
        self.kind = kind ?? .inferred(targetApp: targetApp)
        let shown = cleanText ?? rawText
        wordCount = shown.split(whereSeparator: \.isWhitespace).count
    }

    public var text: String { cleanText ?? rawText }
}

public enum TBDSourceKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case file, url, meeting, voiceNote
    public var label: String {
        switch self {
        case .file: "File"
        case .url: "Link"
        case .meeting: "Meeting"
        case .voiceNote: "Voice note"
        }
    }
}

public enum TBDTranscriptionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case processing, completed, failed, cancelled
}

/// A library item: transcribed file, link, meeting or voice note.
public struct TBDTranscription: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcription"
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var sourceKind: TBDSourceKind
    public var sourcePath: String?
    public var sourceURL: String?
    public var durationMs: Int
    public var language: String?
    public var engine: String?
    public var status: TBDTranscriptionStatus
    public var errorMessage: String?
    public var rawText: String
    public var cleanText: String?
    public var segments: [TBDSegment]
    public var words: [TBDWord]
    public var speakers: [TBDSpeaker]
    public var audioPaths: [String]
    /// When the retention clock for kept audio started (imports start it at import time, not at the
    /// recording date). Nil means `createdAt`.
    public var audioRetentionStartedAt: Date?
    /// The person's own meeting notes (plain text, `[M:SS]` stamps where they typed /now).
    public var userNotes: String?

    public init(id: String = tbdNewID(), title: String, sourceKind: TBDSourceKind, sourcePath: String? = nil, sourceURL: String? = nil,
                status: TBDTranscriptionStatus = .processing) {
        self.id = id; createdAt = Date(); updatedAt = createdAt; self.title = title; self.sourceKind = sourceKind
        self.sourcePath = sourcePath; self.sourceURL = sourceURL; durationMs = 0; self.status = status
        rawText = ""; segments = []; words = []; speakers = []; audioPaths = []
    }

    public var text: String { cleanText ?? rawText }

    public func speakerLabel(_ id: String?) -> String? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }?.label ?? id
    }
}

/// Vocabulary replacement applied after recognition ("chat gpt" → "ChatGPT").
public struct TBDCustomWord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "customWord"
    public var id: String
    public var word: String
    public var replacement: String?
    public var isEnabled: Bool
    public var createdAt: Date
    public init(id: String = tbdNewID(), word: String, replacement: String? = nil, isEnabled: Bool = true) {
        self.id = id; self.word = word; self.replacement = replacement; self.isEnabled = isEnabled; createdAt = Date()
    }
}

/// A key press a snippet can simulate after the paste instead of inserting text. Raw values are the v1 names.
public enum TBDKeyAction: String, Codable, Sendable, CaseIterable, Equatable {
    case returnKey = "return"
    public var label: String { "Return" }
}

/// Text expansion: saying the trigger inserts the expansion.
public struct TBDSnippet: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "snippet"
    public var id: String
    public var trigger: String
    public var expansion: String
    public var isEnabled: Bool
    public var useCount: Int
    public var createdAt: Date
    /// Key press this snippet simulates. Such snippets never expand to text (v1: `action != nil`).
    public var action: TBDKeyAction?
    public init(id: String = tbdNewID(), trigger: String, expansion: String, isEnabled: Bool = true, action: TBDKeyAction? = nil) {
        self.id = id; self.trigger = trigger; self.expansion = expansion; self.isEnabled = isEnabled; useCount = 0; createdAt = Date()
        self.action = action
    }
}

/// An AI result attached to a transcription: a summary or a question with its answer.
public struct TBDSummary: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, Sendable { case summary, qa }
    public static let databaseTableName = "summary"
    public var id: String
    public var transcriptionId: String
    public var kind: Kind
    public var prompt: String
    public var content: String
    public var createdAt: Date
    /// Library prompt (and its version) that produced this summary; nil for older summaries.
    public var promptId: String?
    public var promptVersionId: String?
    public var promptName: String?
    /// One-off instructions added for this run.
    public var extraInstructions: String?
    public init(id: String = tbdNewID(), transcriptionId: String, kind: Kind, prompt: String, content: String,
                promptId: String? = nil, promptVersionId: String? = nil, promptName: String? = nil, extraInstructions: String? = nil) {
        self.id = id; self.transcriptionId = transcriptionId; self.kind = kind; self.prompt = prompt; self.content = content; createdAt = Date()
        self.promptId = promptId; self.promptVersionId = promptVersionId; self.promptName = promptName; self.extraInstructions = extraInstructions
    }
}

extension TBDSummary.Kind: DatabaseValueConvertible {}

/// One message of an Ask conversation. `prompt` is what the model saw when it differs from the
/// shown text (quick prompts show their label).
public struct TBDAskMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    public var prompt: String?
    public init(_ role: Role, _ content: String, prompt: String? = nil) { self.role = role; self.content = content; self.prompt = prompt }
    public var modelContent: String { prompt ?? content }
}

/// Questions and answers about one transcript, saved with it.
public struct TBDAskConversation: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "askConversation"
    public var id: String
    public var transcriptionId: String
    public var title: String
    public var messages: [TBDAskMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String = tbdNewID(), transcriptionId: String, title: String, messages: [TBDAskMessage] = []) {
        self.id = id; self.transcriptionId = transcriptionId; self.title = title; self.messages = messages
        createdAt = Date(); updatedAt = createdAt
    }
}
