import Foundation

/// Speech engines Listening can run. One is resident at a time.
public enum TBDEngineChoice: String, CaseIterable, Codable, Sendable {
    case parakeetV3, parakeetV2, whisper

    public var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet v3 (multilingual)"
        case .parakeetV2: "Parakeet v2 (English)"
        case .whisper: "Whisper Large v3 Turbo"
        }
    }
}

/// A saved prompt for text transforms.
public struct TBDTransformPrompt: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var instruction: String
    public init(id: String = UUID().uuidString, name: String, instruction: String) {
        self.id = id; self.name = name; self.instruction = instruction
    }

    public static let defaults: [TBDTransformPrompt] = [
        .init(id: "fix", name: "Fix grammar", instruction: "Fix spelling, grammar and punctuation. Keep the meaning, tone and language."),
        .init(id: "concise", name: "Make concise", instruction: "Rewrite the text to be shorter and clearer. Keep every fact."),
        .init(id: "formal", name: "Make formal", instruction: "Rewrite the text in a clear, professional tone."),
        .init(id: "english", name: "Translate to English", instruction: "Translate the text to English."),
    ]
}

/// User settings for Listening, stored in the host's UserDefaults under `tbd.listening.*`.
public struct TBDListeningPreferences: @unchecked Sendable {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    enum Key {
        static let engine = "tbd.listening.engine"
        static let whisperLanguage = "tbd.listening.whisperLanguage"
        static let microphoneUID = "tbd.listening.microphoneUID"
        static let keepAudio = "tbd.listening.keepAudio"
        static let keepHistory = "tbd.listening.keepHistory"
        static let removeFillers = "tbd.listening.removeFillers"
        static let dictationCleanup = "tbd.listening.dictationCleanup"
        static let dictationHotkey = "tbd.listening.dictationHotkey"
        static let transformHotkey = "tbd.listening.transformHotkey"
        static let transformPrompts = "tbd.listening.transformPrompts"
        static let transformPromptID = "tbd.listening.transformPromptID"
        static let calendarReminders = "tbd.listening.calendarReminders"
        static let calendarAutoStart = "tbd.listening.calendarAutoStart"
        static let summaryPrompt = "tbd.listening.summaryPrompt"
        static let cleanupPrompt = "tbd.listening.cleanupPrompt"
        static let diarize = "tbd.listening.diarize"
        static let retention = "tbd.listening.retention"
        static let autoSummarizeMeetings = "tbd.listening.autoSummarizeMeetings"
        static let dictationUndoWindow = "tbd.listening.dictationUndoWindow"
        static let calendarSkips = "tbd.listening.calendarSkips"
        static let lastRetentionSweep = "tbd.listening.lastRetentionSweep"
    }

    /// In-memory override of the engine for this process only (argument domain; nothing is written).
    public func overridingEngine(_ engine: TBDEngineChoice) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[Key.engine] = engine.rawValue
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    public var engine: TBDEngineChoice {
        get { TBDEngineChoice(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .parakeetV3 }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.engine) }
    }
    /// ISO code, or nil for automatic detection (Whisper only).
    public var whisperLanguage: String? {
        get { defaults.string(forKey: Key.whisperLanguage).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Key.whisperLanguage) }
    }
    /// Input device UID, or nil to follow the System Default input.
    public var microphoneUID: String? {
        get { defaults.string(forKey: Key.microphoneUID).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Key.microphoneUID) }
    }
    /// Legacy single switch for keeping audio; seeds `retention` until that is saved.
    public var keepAudio: Bool {
        get { bool(Key.keepAudio, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.keepAudio) }
    }
    /// Save dictations to history.
    public var keepHistory: Bool {
        get { bool(Key.keepHistory, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.keepHistory) }
    }
    public var removeFillers: Bool {
        get { bool(Key.removeFillers, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.removeFillers) }
    }
    /// Optional LLM cleanup of hotkey dictation (route "cleanup"). Off by default.
    public var dictationCleanup: Bool {
        get { bool(Key.dictationCleanup, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.dictationCleanup) }
    }
    public var dictationHotkey: String {
        get { defaults.string(forKey: Key.dictationHotkey) ?? "fn" }
        nonmutating set { defaults.set(newValue, forKey: Key.dictationHotkey) }
    }
    /// Empty string disables the transform hotkey.
    public var transformHotkey: String {
        get { defaults.string(forKey: Key.transformHotkey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.transformHotkey) }
    }
    public var transformPrompts: [TBDTransformPrompt] {
        get {
            guard let data = defaults.data(forKey: Key.transformPrompts),
                  let prompts = try? JSONDecoder().decode([TBDTransformPrompt].self, from: data), !prompts.isEmpty else {
                return TBDTransformPrompt.defaults
            }
            return prompts
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.transformPrompts) }
    }
    public var transformPromptID: String {
        get { defaults.string(forKey: Key.transformPromptID) ?? TBDTransformPrompt.defaults[0].id }
        nonmutating set { defaults.set(newValue, forKey: Key.transformPromptID) }
    }
    public var calendarReminders: Bool {
        get { bool(Key.calendarReminders, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.calendarReminders) }
    }
    /// Start recording automatically when a calendar meeting begins. Off by default.
    public var calendarAutoStart: Bool {
        get { bool(Key.calendarAutoStart, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.calendarAutoStart) }
    }
    public var diarize: Bool {
        get { bool(Key.diarize, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.diarize) }
    }
    /// Retention per kind. Until set, derived from the older "keep audio" switch.
    public var retention: TBDRetentionSettings {
        get {
            guard let data = defaults.data(forKey: Key.retention),
                  let settings = try? JSONDecoder().decode(TBDRetentionSettings.self, from: data) else {
                return .migrated(keepAudio: keepAudio)
            }
            return settings
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.retention) }
    }
    /// Whether new captures of `kind` keep their audio after transcription.
    public func keepsAudio(_ kind: TBDRetentionKind) -> Bool { retention[kind].keepsFreshAudio(kind) }
    /// Last successful retention sweep (throttles the daily run).
    public var lastRetentionSweep: Date? {
        get { defaults.object(forKey: Key.lastRetentionSweep) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastRetentionSweep) }
    }

    /// Summarise each meeting when its transcript is saved (needs a model on the "analysis" route).
    public var autoSummarizeMeetings: Bool {
        get { bool(Key.autoSummarizeMeetings, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoSummarizeMeetings) }
    }

    /// How long a cancelled dictation can be brought back with Undo.
    public var dictationUndoWindow: TBDCancelUndo.Window {
        get { defaults.object(forKey: Key.dictationUndoWindow) == nil ? .fiveSeconds
            : TBDCancelUndo.Window(rawValue: defaults.integer(forKey: Key.dictationUndoWindow)) ?? .fiveSeconds }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.dictationUndoWindow) }
    }
    /// Calendar meetings not to auto-record.
    public var calendarSkips: TBDCalendarSkips {
        get { defaults.data(forKey: Key.calendarSkips).flatMap { try? JSONDecoder().decode(TBDCalendarSkips.self, from: $0) } ?? TBDCalendarSkips() }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.calendarSkips) }
    }

    public var summaryPrompt: String {
        get { defaults.string(forKey: Key.summaryPrompt) ?? Self.defaultSummaryPrompt }
        nonmutating set { defaults.set(newValue, forKey: Key.summaryPrompt) }
    }
    public var cleanupPrompt: String {
        get { defaults.string(forKey: Key.cleanupPrompt) ?? Self.defaultCleanupPrompt }
        nonmutating set { defaults.set(newValue, forKey: Key.cleanupPrompt) }
    }

    public static let defaultSummaryPrompt = """
    Analyze this transcript and produce a structured summary.

    Open with a single sentence that captures what this is about and why it matters. Then organize the rest under clear headings:

    **Key Points** — The 3–7 most important ideas, findings, or arguments. Each should be a complete thought, not a fragment. If speakers are identified, attribute claims to them.

    **Decisions & Outcomes** — Anything that was agreed upon, concluded, or resolved. If nothing was decided, omit this section entirely — don't fabricate consensus.

    **Open Questions** — Unresolved threads, disagreements, or topics raised but not settled. Only include these if they're genuinely unresolved in the transcript.

    Be direct. Prefer specifics over generalizations — names, numbers, and concrete details beat vague summaries. If the transcript is short or straightforward, keep the output proportionally brief. Don't pad.
    """
    public static let defaultCleanupPrompt = """
    Correct punctuation and obvious recognition mistakes. Preserve language, meaning and all factual details. \
    Return only the corrected transcript.
    """
}
