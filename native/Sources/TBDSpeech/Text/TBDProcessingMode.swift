import Foundation

/// How dictated and transcribed text is post-processed (v1 `processingMode`).
public enum TBDProcessingMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// Text exactly as the engine produced it. No cleanup.
    case raw
    /// Fillers, custom words, snippets and spoken punctuation.
    case clean

    /// v1 also stored the retired modes "formal", "email" and "code"; they all meant Clean.
    public init?(rawValue: String) {
        switch rawValue {
        case "raw": self = .raw
        case "clean", "formal", "email", "code": self = .clean
        default: return nil
        }
    }

    public var title: String { self == .raw ? "Raw" : "Clean" }
    public var subtitle: String { self == .raw ? "As spoken" : "Polished" }
    public var detail: String {
        self == .raw ? "Exactly as you spoke it. No corrections applied."
                     : "Polishes your text: removes fillers, fixes words, expands snippets."
    }
}

/// The processing choices in force for one run.
public struct TBDProcessingSettings: Sendable, Equatable {
    public var mode: TBDProcessingMode
    public var spokenPunctuation: Bool
    public var removeFillers: Bool

    public init(mode: TBDProcessingMode = .raw, spokenPunctuation: Bool = true, removeFillers: Bool = true) {
        self.mode = mode; self.spokenPunctuation = spokenPunctuation; self.removeFillers = removeFillers
    }

    /// Meetings keep a verbatim record, but v1 still applied custom words to them in every mode.
    /// Files and links get vocabulary only in Clean mode.
    public func appliesVocabulary(to kind: TBDSourceKind) -> Bool { kind == .meeting || mode == .clean }

    /// Only files and links run the full Clean pipeline; meetings stay verbatim apart from custom words.
    public func appliesCleanPipeline(to kind: TBDSourceKind) -> Bool { kind != .meeting && mode == .clean }
}

extension TBDListeningPreferences {
    public var processingSettings: TBDProcessingSettings {
        TBDProcessingSettings(mode: processingMode, spokenPunctuation: spokenPunctuation, removeFillers: removeFillers)
    }
}
