import Foundation

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
        /// Live route (dictation, meeting preview). The original single-engine key, so upgrades keep their choice.
        static let engine = "tbd.listening.engine"
        /// Final route override (files, links, meeting transcript). Absent: follows the live engine.
        static let finalEngine = "tbd.listening.finalEngine"
        static let whisperLanguage = "tbd.listening.whisperLanguage"
        static let nemotronLanguage = "tbd.listening.nemotronLanguage"
        static let cohereLanguage = "tbd.listening.cohereLanguage"
        static let dictationLivePreview = "tbd.listening.dictationLivePreview"
        static let meetingLivePreview = "tbd.listening.meetingLivePreview"
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
        static let practiceCompleted = "tbd.listening.practiceCompleted"
        static let lastRetentionSweep = "tbd.listening.lastRetentionSweep"
        // MARK: transcribe-vocab
        static let processingMode = "tbd.listening.processingMode"
        static let spokenPunctuation = "tbd.listening.spokenPunctuation"
    }

    /// In-memory override of both routes for this process only (argument domain; nothing is written).
    public func overridingEngine(_ engine: TBDSpeechEngineKind) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[Key.engine] = engine.rawValue
        arguments[Key.finalEngine] = engine.rawValue
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Keys `tbd-listen config` may read and write, with their defaults.
    public static let configKeys: [String] = [
        "liveEngine", "finalEngine", "whisperLanguage", "nemotronLanguage", "cohereLanguage", "dictationLivePreview",
        "meetingLivePreview", "keepAudio", "keepHistory", "removeFillers", "dictationCleanup", "diarize",
        "calendarReminders", "calendarAutoStart", "dictationHotkey", "transformHotkey", "microphoneUID",
        "youtubeAudioQuality",
    ]

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    /// The live engine (dictation and meeting preview). Same as `liveEngine`.
    public var engine: TBDSpeechEngineKind {
        get { TBDSpeechEngineKind(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .parakeetV3 }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.engine) }
    }
    public var liveEngine: TBDSpeechEngineKind {
        get { engine }
        nonmutating set { engine = newValue }
    }
    /// Explicit final engine, or nil to follow the live engine. An override equal to the live
    /// engine stays set, so changing the live engine later does not move the final route.
    public var finalEngineOverride: TBDSpeechEngineKind? {
        get { defaults.string(forKey: Key.finalEngine).flatMap(TBDSpeechEngineKind.init(rawValue:)) }
        nonmutating set {
            if let newValue { defaults.set(newValue.rawValue, forKey: Key.finalEngine) } else { defaults.removeObject(forKey: Key.finalEngine) }
        }
    }
    /// The final engine (files, links, meeting transcript).
    public var finalEngine: TBDSpeechEngineKind { finalEngineOverride ?? engine }

    public func engine(for route: TBDSpeechRoute) -> TBDSpeechEngineKind { route == .live ? engine : finalEngine }

    /// Engine and language for a route.
    public func selection(for route: TBDSpeechRoute) -> TBDEngineSelection {
        let kind = engine(for: route)
        return TBDEngineSelection(kind: kind, language: language(for: kind))
    }

    /// Stored language preference for an engine (nil: automatic or engine default).
    public func language(for kind: TBDSpeechEngineKind) -> String? {
        switch kind {
        case .whisper: whisperLanguage
        case .nemotronMultilingual: nemotronLanguage
        case .cohere: cohereLanguage
        default: nil
        }
    }

    public func setLanguage(_ language: String?, for kind: TBDSpeechEngineKind) {
        let value = Self.normalizedLanguage(language)
        switch kind {
        case .whisper: whisperLanguage = value
        case .nemotronMultilingual: nemotronLanguage = value
        case .cohere: cohereLanguage = value.flatMap { TBDEngineCapabilities.cohereLanguages.contains($0) ? $0 : nil }
        default: break
        }
    }

    /// Lower-cased primary subtag ("en-US" → "en"); empty or "auto" → nil.
    public static func normalizedLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty, trimmed != "auto" else { return nil }
        let primary = trimmed.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? trimmed
        guard (2...3).contains(primary.count), primary.allSatisfy(\.isLetter) else { return nil }
        return primary
    }

    /// ISO code, or nil for automatic detection (Whisper only).
    public var whisperLanguage: String? {
        get { defaults.string(forKey: Key.whisperLanguage).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Key.whisperLanguage) }
    }
    /// Language hint for Nemotron Multilingual, or nil for automatic detection.
    public var nemotronLanguage: String? {
        get { defaults.string(forKey: Key.nemotronLanguage).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Key.nemotronLanguage) }
    }
    /// Cohere has no language detection; nil means English.
    public var cohereLanguage: String? {
        get { defaults.string(forKey: Key.cohereLanguage).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue, forKey: Key.cohereLanguage) }
    }
    /// Show text in the dictation pill while speaking (engines with live preview only).
    public var dictationLivePreview: Bool {
        get { bool(Key.dictationLivePreview, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.dictationLivePreview) }
    }
    /// Transcribe meetings live while recording.
    public var meetingLivePreview: Bool {
        get { bool(Key.meetingLivePreview, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.meetingLivePreview) }
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

    /// The first-run practice dictation was finished or skipped.
    public var practiceCompleted: Bool {
        get { bool(Key.practiceCompleted, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.practiceCompleted) }
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

    // MARK: links
    enum LinkKey {
        /// Same name as v1 (`youtubeAudioQuality`), under the Listening prefix.
        static let youtubeAudioQuality = "tbd.listening.youtubeAudioQuality"
        /// Last successful yt-dlp install or weekly refresh (v1 `ytDlp.lastUpdateCheckAt`).
        static let ytDlpLastUpdateCheck = "tbd.listening.ytDlpLastUpdateCheck"
    }
    /// Audio format yt-dlp downloads for video and web links. M4A by default, as in v1.
    public var youtubeAudioQuality: TBDYtDlpAudioQuality {
        get { TBDYtDlpAudioQuality(rawValue: defaults.string(forKey: LinkKey.youtubeAudioQuality) ?? "") ?? .m4a }
        nonmutating set { defaults.set(newValue.rawValue, forKey: LinkKey.youtubeAudioQuality) }
    }

    // MARK: transcribe-vocab

    /// v1's own keys (same defaults domain), read once so an upgrade keeps the person's choice.
    static let v1ProcessingModeKey = "processingMode"
    static let v1SpokenPunctuationKey = "spokenPunctuationEnabled"

    /// Raw: text as spoken, no cleanup. Clean: fillers, vocabulary, snippets, spoken punctuation.
    /// First read decides once and stores the result, so nobody's behaviour changes on upgrade:
    /// a v1 upgrade keeps its v1 mode; an existing opt2 install (which always cleaned) gets Clean;
    /// a fresh install gets Raw, v1's default.
    public var processingMode: TBDProcessingMode {
        get {
            if let stored = defaults.string(forKey: Key.processingMode).flatMap(TBDProcessingMode.init(rawValue:)) { return stored }
            let initial = Self.initialProcessingMode(defaults)
            defaults.set(initial.rawValue, forKey: Key.processingMode)
            return initial
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.processingMode) }
    }

    static func initialProcessingMode(_ defaults: UserDefaults) -> TBDProcessingMode {
        if let v1 = defaults.string(forKey: v1ProcessingModeKey).flatMap(TBDProcessingMode.init(rawValue:)) { return v1 }
        let existingInstall = defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("tbd.listening.") && $0 != Key.processingMode }
        return existingInstall ? .clean : .raw
    }

    /// "question mark" becomes "?" in Clean mode (v1 default: on; a v1 upgrade keeps its v1 choice).
    public var spokenPunctuation: Bool {
        get {
            if let value = defaults.object(forKey: Key.spokenPunctuation) as? Bool { return value }
            return defaults.object(forKey: Self.v1SpokenPunctuationKey) as? Bool ?? true
        }
        nonmutating set { defaults.set(newValue, forKey: Key.spokenPunctuation) }
    }

    // MARK: dictation-autosave

    enum BehaviourKey {
        static let pauseMediaDuringDictation = "tbd.listening.pauseMediaDuringDictation"
        static let playDictationCaptureSounds = "tbd.listening.playDictationCaptureSounds"
        static let escapeCancelsDictation = "tbd.listening.escapeCancelsDictation"
        static let preserveDiscardedDictations = "tbd.listening.preserveDiscardedDictations"
        static let instantDictationEnabled = "tbd.listening.instantDictationEnabled"
        static let keepDictationOnClipboard = "tbd.listening.keepDictationOnClipboard"
        static let dictationStreamingCursorEnabled = "tbd.listening.dictationStreamingCursorEnabled"
        static let dictationPreviewTextSize = "tbd.listening.dictationPreviewTextSize"
        static let showIdlePill = "tbd.listening.showIdlePill"
        static let dictationOverlayPlacement = "tbd.listening.dictationOverlayPlacement"
        static let silenceAutoStop = "tbd.listening.silenceAutoStop"
        static let silenceDelay = "tbd.listening.silenceDelay"
        static let dictationInsertionStyle = "tbd.listening.dictationInsertionStyle"
        static let voiceReturnEnabled = "tbd.listening.voiceReturnEnabled"
        static let voiceReturnTriggers = "tbd.listening.voiceReturnTriggers"
        static let notifyOnTranscriptionComplete = "tbd.listening.notifyOnTranscriptionComplete"
        static let notifyOnMeetingEnd = "tbd.listening.notifyOnMeetingEnd"
        static let meetingArtifactsFolder = "tbd.listening.meetingArtifactsFolder"
    }

    /// Dictation behaviour switches (v1 defaults).
    public var pauseMediaDuringDictation: Bool {
        get { bool(BehaviourKey.pauseMediaDuringDictation, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.pauseMediaDuringDictation) }
    }
    public var playDictationCaptureSounds: Bool {
        get { bool(BehaviourKey.playDictationCaptureSounds, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.playDictationCaptureSounds) }
    }
    public var escapeCancelsDictation: Bool {
        get { bool(BehaviourKey.escapeCancelsDictation, default: true) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.escapeCancelsDictation) }
    }
    /// Keep cancelled or expired dictations in History (needs `keepHistory`). Nothing is pasted.
    public var preserveDiscardedDictations: Bool {
        get { bool(BehaviourKey.preserveDiscardedDictations, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.preserveDiscardedDictations) }
    }
    public var instantDictationEnabled: Bool {
        get { bool(BehaviourKey.instantDictationEnabled, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.instantDictationEnabled) }
    }
    public var keepDictationOnClipboard: Bool {
        get { bool(BehaviourKey.keepDictationOnClipboard, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.keepDictationOnClipboard) }
    }
    public var dictationStreamingCursorEnabled: Bool {
        get { bool(BehaviourKey.dictationStreamingCursorEnabled, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.dictationStreamingCursorEnabled) }
    }
    public var dictationPreviewTextSize: TBDPreviewTextSize {
        get { defaults.string(forKey: BehaviourKey.dictationPreviewTextSize).flatMap(TBDPreviewTextSize.init(rawValue:)) ?? .medium }
        nonmutating set { defaults.set(newValue.rawValue, forKey: BehaviourKey.dictationPreviewTextSize) }
    }
    public var showIdlePill: Bool {
        get { bool(BehaviourKey.showIdlePill, default: true) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.showIdlePill) }
    }
    public var dictationOverlayPlacement: TBDOverlayPlacement {
        get { defaults.string(forKey: BehaviourKey.dictationOverlayPlacement).flatMap(TBDOverlayPlacement.init(rawValue:)) ?? .bottom }
        nonmutating set { defaults.set(newValue.rawValue, forKey: BehaviourKey.dictationOverlayPlacement) }
    }
    public var silenceAutoStop: Bool {
        get { bool(BehaviourKey.silenceAutoStop, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.silenceAutoStop) }
    }
    /// Seconds of quiet before auto-stop; 0 or unset reads as the v1 default of 2.
    public var silenceDelay: Double {
        get { let value = defaults.double(forKey: BehaviourKey.silenceDelay); return value == 0 ? TBDSilenceAutoStop.defaultDelay : value }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.silenceDelay) }
    }
    public var dictationInsertionStyle: TBDInsertionStyle {
        get { defaults.string(forKey: BehaviourKey.dictationInsertionStyle).flatMap(TBDInsertionStyle.init(rawValue:)) ?? .sentence }
        nonmutating set { defaults.set(newValue.rawValue, forKey: BehaviourKey.dictationInsertionStyle) }
    }
    public var voiceReturnEnabled: Bool {
        get { bool(BehaviourKey.voiceReturnEnabled, default: false) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.voiceReturnEnabled) }
    }
    /// Trigger phrases; never empty (the default phrase when none is stored).
    public var voiceReturnTriggers: [String] {
        get { TBDVoiceReturn.normalizedOrDefault(defaults.stringArray(forKey: BehaviourKey.voiceReturnTriggers) ?? []) }
        nonmutating set { defaults.set(TBDVoiceReturn.normalizedOrDefault(newValue), forKey: BehaviourKey.voiceReturnTriggers) }
    }
    /// Chime and banner when a file or link transcription finishes (v1 default on).
    public var notifyOnTranscriptionComplete: Bool {
        get { bool(BehaviourKey.notifyOnTranscriptionComplete, default: true) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.notifyOnTranscriptionComplete) }
    }
    /// Chime and banner when a meeting transcript is ready (v1 default on).
    public var notifyOnMeetingEnd: Bool {
        get { bool(BehaviourKey.notifyOnMeetingEnd, default: true) }
        nonmutating set { defaults.set(newValue, forKey: BehaviourKey.notifyOnMeetingEnd) }
    }
    /// Absolute folder that holds meeting recordings instead of the default; nil follows the default.
    public var meetingArtifactsFolder: String? {
        get { defaults.string(forKey: BehaviourKey.meetingArtifactsFolder).flatMap(Self.normalizedFolder) }
        nonmutating set {
            if let path = newValue.flatMap(Self.normalizedFolder) { defaults.set(path, forKey: BehaviourKey.meetingArtifactsFolder) }
            else { defaults.removeObject(forKey: BehaviourKey.meetingArtifactsFolder) }
        }
    }
    /// Expands "~", requires an absolute path (v1 `normalizedMeetingArtifactsFolder`).
    public static func normalizedFolder(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Auto-save settings per scope (see `TBDAutoSaveConfig`).
    public func autoSave(_ scope: TBDAutoSaveScope) -> TBDAutoSaveConfig { TBDAutoSaveConfig(defaults: defaults, scope: scope) }

    // MARK: hotkeys

    /// v1 hotkey keys (PARITY 3.2), stored as TBDHotkey text; "" means the hotkey is off.
    enum HotkeyKey {
        static let handsFree = "tbd.listening.hotkeyTrigger"
        static let pushToTalk = "tbd.listening.pushToTalkHotkeyTrigger"
        static let meeting = "tbd.listening.meetingHotkeyTrigger"
        static let fileTranscription = "tbd.listening.fileTranscriptionHotkeyTrigger"
        static let urlTranscription = "tbd.listening.youtubeTranscriptionHotkeyTrigger"
        static let dictationAIPolish = "tbd.listening.dictationAIPolishHotkeyTrigger"
        static let dictationClipboard = "tbd.listening.dictationClipboardHotkeyTrigger"

        static func key(for surface: TBDHotkeySurface) -> String? {
            switch surface {
            case .handsFree: handsFree
            case .pushToTalk: pushToTalk
            case .meeting: meeting
            case .fileTranscription: fileTranscription
            case .urlTranscription: urlTranscription
            case .dictationAIPolish: dictationAIPolish
            case .dictationClipboard: dictationClipboard
            case .transform: nil
            }
        }
    }

    /// The hotkey for a surface, or nil when it is off. Unset keys use v1's defaults.
    public func hotkey(for surface: TBDHotkeySurface) -> TBDHotkey? {
        guard let key = HotkeyKey.key(for: surface) else { return TBDHotkey.stored(transformHotkey) }
        guard let text = defaults.string(forKey: key) else { return surface.defaultHotkey }
        return TBDHotkey.stored(text)
    }

    public func setHotkey(_ hotkey: TBDHotkey?, for surface: TBDHotkeySurface) {
        guard let key = HotkeyKey.key(for: surface) else { transformHotkey = hotkey?.serialized ?? ""; return }
        defaults.set(hotkey?.serialized ?? "", forKey: key)
    }

    /// Every Listening hotkey, for conflict checks. The transform hotkey is named after the current prompt.
    public var hotkeySnapshot: TBDHotkeyConflictPolicy.Snapshot {
        let prompt = transformPrompts.first { $0.id == transformPromptID } ?? transformPrompts.first
        return TBDHotkeyConflictPolicy.Snapshot(
            handsFree: hotkey(for: .handsFree), pushToTalk: hotkey(for: .pushToTalk), meeting: hotkey(for: .meeting),
            fileTranscription: hotkey(for: .fileTranscription), urlTranscription: hotkey(for: .urlTranscription),
            dictationAIPolish: hotkey(for: .dictationAIPolish), dictationClipboard: hotkey(for: .dictationClipboard),
            transforms: [.init(name: "Transform \(prompt?.name ?? "")".trimmingCharacters(in: .whitespaces), hotkey: hotkey(for: .transform))])
    }

    /// Short hint for empty states, for example "fn" or "R⌥".
    public var pushToTalkHotkeyLabel: String {
        (hotkey(for: .pushToTalk) ?? hotkey(for: .handsFree))?.shortSymbol ?? "none"
    }

    /// One-time move of the single `dictationHotkey` (hold to talk, tap for hands-free) into v1's two keys.
    /// Both get the same key, which is v1's shared gesture: hold to talk, double-tap for hands-free.
    /// An unparsable old value had disabled dictation, so both stay off. Then v1's stored-value repair runs.
    public func migrateDictationHotkeys() {
        let hasHandsFree = defaults.object(forKey: HotkeyKey.handsFree) != nil
        let hasPushToTalk = defaults.object(forKey: HotkeyKey.pushToTalk) != nil
        if !hasHandsFree, !hasPushToTalk, let legacy = defaults.string(forKey: Key.dictationHotkey) {
            let value = TBDHotkey.stored(legacy)?.serialized ?? ""
            defaults.set(value, forKey: HotkeyKey.handsFree)
            defaults.set(value, forKey: HotkeyKey.pushToTalk)
        }
        func stored(_ key: String) -> TBDHotkey?? {
            defaults.string(forKey: key).map { TBDHotkey.stored($0) }
        }
        let resolved = TBDDictationHotkeyPlan.resolveStored(handsFree: stored(HotkeyKey.handsFree), pushToTalk: stored(HotkeyKey.pushToTalk))
        if resolved.persistHandsFree { setHotkey(resolved.handsFree, for: .handsFree) }
        if resolved.persistPushToTalk { setHotkey(resolved.pushToTalk, for: .pushToTalk) }
    }
}
