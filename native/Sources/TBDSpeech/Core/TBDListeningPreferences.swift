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
    /// Keep recorded audio after transcription.
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
    public var summaryPrompt: String {
        get { defaults.string(forKey: Key.summaryPrompt) ?? Self.defaultSummaryPrompt }
        nonmutating set { defaults.set(newValue, forKey: Key.summaryPrompt) }
    }
    public var cleanupPrompt: String {
        get { defaults.string(forKey: Key.cleanupPrompt) ?? Self.defaultCleanupPrompt }
        nonmutating set { defaults.set(newValue, forKey: Key.cleanupPrompt) }
    }

    public static let defaultSummaryPrompt = """
    Summarise this transcript. Start with a two-sentence overview, then list key points, decisions and action items \
    (with owners when stated). Use the transcript's language. Do not invent facts.
    """
    public static let defaultCleanupPrompt = """
    Correct punctuation and obvious recognition mistakes. Preserve language, meaning and all factual details. \
    Return only the corrected transcript.
    """
}
