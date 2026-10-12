import Foundation

/// Speech engines Listening can run. The raw value is stored in preferences and on transcripts
/// (`engine`), so existing values (`parakeetV3`, `parakeetV2`, `whisper`) never change.
public enum TBDSpeechEngineKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case parakeetV3, parakeetV2, parakeetUnified, nemotronMultilingual, nemotronEnglish, cohere, whisper

    public var id: String { rawValue }

    /// Kebab-case id used by `tbd-listen` (`--engine`, `models download`).
    public var cliID: String {
        switch self {
        case .parakeetV3: "parakeet-v3"
        case .parakeetV2: "parakeet-v2"
        case .parakeetUnified: "parakeet-unified"
        case .nemotronMultilingual: "nemotron-multilingual"
        case .nemotronEnglish: "nemotron-english"
        case .cohere: "cohere-transcribe"
        case .whisper: "whisper-large-v3-turbo"
        }
    }

    /// Accepts the raw value, the CLI id and the short aliases people type.
    public init?(identifier: String) {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: TBDSpeechEngineKind] = [
            "parakeet": .parakeetV3, "v3": .parakeetV3, "v2": .parakeetV2, "unified": .parakeetUnified,
            "nemotron": .nemotronMultilingual, "nemotron-multilingual-1120ms": .nemotronMultilingual,
            "nemotron-english-1120ms": .nemotronEnglish, "cohere": .cohere, "cohere-transcribe-03-2026": .cohere,
            "whisper": .whisper, "whisper-large-v3-v20240930-turbo-632mb": .whisper,
        ]
        if let match = Self.allCases.first(where: { $0.rawValue.lowercased() == value || $0.cliID == value }) {
            self = match
        } else if let alias = aliases[value] {
            self = alias
        } else {
            return nil
        }
    }

    public var capabilities: TBDEngineCapabilities { TBDEngineCapabilities.registry[self]! }
    public var displayName: String { capabilities.displayName }
}

/// Former name of `TBDSpeechEngineKind`.
public typealias TBDEngineChoice = TBDSpeechEngineKind

/// What an engine can do. One row per engine in `registry`; settings, routing and the CLI read
/// these flags instead of switching on engine names.
public struct TBDEngineCapabilities: Sendable, Equatable {
    public enum LanguageMode: String, Sendable, Codable {
        /// The model detects the language itself.
        case automatic
        /// One language only.
        case fixed
        /// The person may pick a language (or automatic detection where supported).
        case selectable
    }

    public let kind: TBDSpeechEngineKind
    public let displayName: String
    public let modelName: String
    public let summary: String
    public let languageMode: LanguageMode
    /// Language used when the person picks none (nil: automatic detection).
    public let defaultLanguage: String?
    /// ISO 639-1 codes, or nil when the engine covers too many to list (Whisper, Nemotron).
    public let languages: [String]?
    /// Per-word start/end times (needed for SRT/VTT, speaker detection and meeting preview).
    public let wordTimestamps: Bool
    /// Native streaming: partial text while audio arrives.
    public let streaming: Bool
    /// Fast enough to re-transcribe a short tail window every second for a live preview.
    public let tailPreview: Bool
    public let approximateSize: String
    public let approximateBytes: Int64
    /// Physical memory the engine needs, or nil.
    public let minimumMemoryBytes: UInt64?

    /// Speaker detection labels words, so it needs word timestamps.
    public var diarizationCompatible: Bool { wordTimestamps }
    /// Meeting live preview is placed on the timeline by word timings.
    public var meetingLivePreview: Bool { wordTimestamps }
    /// The engine can show text while someone dictates.
    public var livePreview: Bool { streaming || tailPreview }
    public var englishOnly: Bool { languageMode == .fixed && defaultLanguage == "en" }

    public func satisfiesMemory(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        minimumMemoryBytes.map { physicalMemory >= $0 } ?? true
    }

    /// The language to send to the engine for a stored preference.
    public func effectiveLanguage(_ preferred: String?) -> String? {
        switch languageMode {
        case .automatic: nil
        case .fixed: defaultLanguage
        case .selectable:
            if let preferred, languages.map({ $0.contains(preferred) }) ?? true { preferred } else { defaultLanguage }
        }
    }

    /// Parakeet TDT v3 languages (25 European languages).
    public static let parakeetV3Languages = ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                                             "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"]
    /// Cohere Transcribe languages (FluidAudio `CohereAsrConfig.Language`).
    public static let cohereLanguages = ["en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"]

    public static let cohereMinimumMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    public static let registry: [TBDSpeechEngineKind: TBDEngineCapabilities] = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    public static let all: [TBDEngineCapabilities] = [
        .init(kind: .parakeetV3, displayName: "Parakeet v3", modelName: "Parakeet TDT 0.6B v3",
              summary: "Default. Fast, 25 European languages, word timestamps.",
              languageMode: .automatic, defaultLanguage: nil, languages: parakeetV3Languages,
              wordTimestamps: true, streaming: false, tailPreview: true,
              approximateSize: "~465 MB", approximateBytes: 465_000_000, minimumMemoryBytes: nil),
        .init(kind: .parakeetV2, displayName: "Parakeet v2", modelName: "Parakeet TDT 0.6B v2",
              summary: "English only. Never mistakes English for another language.",
              languageMode: .fixed, defaultLanguage: "en", languages: ["en"],
              wordTimestamps: true, streaming: false, tailPreview: true,
              approximateSize: "~465 MB", approximateBytes: 465_000_000, minimumMemoryBytes: nil),
        .init(kind: .parakeetUnified, displayName: "Parakeet Unified", modelName: "Parakeet Unified EN 0.6B",
              summary: "English with punctuation and capitals. Streams text while you speak.",
              languageMode: .fixed, defaultLanguage: "en", languages: ["en"],
              wordTimestamps: true, streaming: true, tailPreview: false,
              approximateSize: "~565 MB", approximateBytes: 565_000_000, minimumMemoryBytes: nil),
        .init(kind: .nemotronMultilingual, displayName: "Nemotron Multilingual", modelName: "Nemotron 3.5 ASR Streaming 0.6B",
              summary: "Streaming, many languages. Quality varies by language.",
              languageMode: .selectable, defaultLanguage: nil, languages: nil,
              wordTimestamps: true, streaming: true, tailPreview: false,
              approximateSize: "~1.5 GB", approximateBytes: 1_500_000_000, minimumMemoryBytes: nil),
        .init(kind: .nemotronEnglish, displayName: "Nemotron English", modelName: "Nemotron Speech Streaming EN 0.6B",
              summary: "Streaming, English only.",
              languageMode: .fixed, defaultLanguage: "en", languages: ["en"],
              wordTimestamps: true, streaming: true, tailPreview: false,
              approximateSize: "~600 MB", approximateBytes: 600_000_000, minimumMemoryBytes: nil),
        .init(kind: .cohere, displayName: "Cohere Transcribe", modelName: "Cohere Transcribe 03-2026",
              summary: "Accurate plain text in 14 languages. No timestamps: no subtitles or speaker labels. Needs 16 GB of memory.",
              languageMode: .selectable, defaultLanguage: "en", languages: cohereLanguages,
              wordTimestamps: false, streaming: false, tailPreview: false,
              approximateSize: "~2.1 GB", approximateBytes: 2_100_000_000, minimumMemoryBytes: cohereMinimumMemoryBytes),
        // WhisperKit can re-transcribe a tail window, but Large v3 Turbo is too slow for a
        // one-second preview cadence, so (as in the donor) its live preview stays off.
        .init(kind: .whisper, displayName: "Whisper Large v3 Turbo", modelName: "Whisper Large v3 Turbo",
              summary: "99 languages, slower. Pick a language or detect it automatically.",
              languageMode: .selectable, defaultLanguage: nil, languages: nil,
              wordTimestamps: true, streaming: false, tailPreview: false,
              approximateSize: "~632 MB", approximateBytes: 632_000_000, minimumMemoryBytes: nil),
    ]
}

/// Which route a speech job takes. Live: dictation and meeting live preview (latency first).
/// Final: files, links and the meeting transcript after recording stops (accuracy first).
public enum TBDSpeechRoute: String, Sendable, CaseIterable, Codable {
    case live, final
}

extension TBDJobKind {
    public var route: TBDSpeechRoute {
        switch self {
        case .dictation, .meetingLive: .live
        case .meetingFinal, .file: .final
        }
    }
}

/// An engine plus the language to run it with.
public struct TBDEngineSelection: Sendable, Equatable, Hashable, Codable {
    public let kind: TBDSpeechEngineKind
    public let language: String?
    public init(kind: TBDSpeechEngineKind, language: String? = nil) {
        self.kind = kind
        self.language = kind.capabilities.effectiveLanguage(language)
    }
    /// Identity of the loaded model (engines whose language changes the model get one per language).
    var residentKey: String { kind.rawValue + "|" + (language ?? "auto") }
}

/// Engines for a meeting, fixed when it starts. Preview is best effort and nil when the live
/// engine cannot place preview text (no word timestamps) or live preview is off.
public struct TBDMeetingSpeechPlan: Sendable, Equatable {
    public let preview: TBDEngineSelection?
    public let final: TBDEngineSelection

    public static func resolve(live: TBDEngineSelection, final: TBDEngineSelection, previewEnabled: Bool = true) -> TBDMeetingSpeechPlan {
        TBDMeetingSpeechPlan(preview: previewEnabled && live.kind.capabilities.meetingLivePreview ? live : nil, final: final)
    }
}
