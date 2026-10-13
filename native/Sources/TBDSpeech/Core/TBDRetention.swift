import Foundation

/// What Listening keeps, per kind of data. Privacy first: audio can go as soon as the text exists,
/// and whole items can expire after a number of days.
public enum TBDRetentionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case dictations, voiceNotes, meetingAudio, meetingTranscripts, fileTranscriptions
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dictations: "Dictations"
        case .voiceNotes: "Voice notes"
        case .meetingAudio: "Meeting audio"
        case .meetingTranscripts: "Meeting transcripts"
        case .fileTranscriptions: "File and link transcriptions"
        }
    }

    public var help: String {
        switch self {
        case .dictations: "Hotkey and chat dictation history with its audio."
        case .voiceNotes: "Voice notes, their transcripts and audio."
        case .meetingAudio: "Recorded meeting tracks. Transcripts, notes and answers stay."
        case .meetingTranscripts: "Whole meetings: transcript, notes, answers and audio."
        case .fileTranscriptions: "Transcripts of files and links, and kept download audio. Your original files are never removed."
        }
    }

    /// Modes offered for this kind.
    public var modes: [TBDRetentionPolicy.Mode] {
        switch self {
        case .meetingTranscripts: [.keepForever, .deleteAfterDays]
        default: [.keepForever, .deleteAfterDays, .deleteAudioAfterTranscription]
        }
    }

    /// Whether `deleteAfterDays` removes audio only (the item stays).
    public var expiresAudioOnly: Bool { self == .meetingAudio }
}

public struct TBDRetentionPolicy: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case keepForever, deleteAfterDays, deleteAudioAfterTranscription

        public func title(for kind: TBDRetentionKind) -> String {
            switch self {
            case .keepForever: "Keep forever"
            case .deleteAfterDays: kind.expiresAudioOnly ? "Remove audio after…" : "Delete after…"
            case .deleteAudioAfterTranscription: "Remove audio after transcription"
            }
        }
    }

    public static let dayRange = 1...365
    public static let defaultDays = 30

    public var mode: Mode
    public var days: Int

    public init(mode: Mode = .keepForever, days: Int = TBDRetentionPolicy.defaultDays) {
        self.mode = mode
        self.days = Self.dayRange.contains(days) ? days : Self.defaultDays
    }

    public static let keepForever = TBDRetentionPolicy()

    /// Whether new captures of this kind keep their audio file.
    public func keepsFreshAudio(_ kind: TBDRetentionKind) -> Bool {
        mode != .deleteAudioAfterTranscription
    }

    /// Items created on or before this instant expire. Only `deleteAfterDays` ever sweeps; removing
    /// audio "after transcription" applies to new captures and never deletes the existing library.
    public func cutoff(now: Date) -> Date? {
        guard mode == .deleteAfterDays else { return nil }
        let days = Self.dayRange.contains(days) ? days : Self.defaultDays
        return now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }

    /// A user-facing sentence for confirmations.
    public func confirmation(for kind: TBDRetentionKind) -> String? {
        switch mode {
        case .keepForever: return nil
        case .deleteAfterDays where kind.expiresAudioOnly:
            return "Meeting audio older than \(days) day\(days == 1 ? "" : "s") is removed now and every day. Transcripts, notes and answers stay. Retranscribing those meetings is no longer possible."
        case .deleteAfterDays:
            return "\(kind.title) older than \(days) day\(days == 1 ? "" : "s") are deleted permanently, now and every day."
        case .deleteAudioAfterTranscription:
            return "New \(kind.title.lowercased()) do not keep audio once the text is saved. Audio you already have is kept."
        }
    }
}

/// The policy for every kind. Stored as JSON in the host's defaults.
public struct TBDRetentionSettings: Codable, Sendable, Equatable {
    public var policies: [TBDRetentionKind: TBDRetentionPolicy]

    public init(policies: [TBDRetentionKind: TBDRetentionPolicy] = [:]) { self.policies = policies }

    public subscript(kind: TBDRetentionKind) -> TBDRetentionPolicy {
        get { policies[kind] ?? .keepForever }
        set { policies[kind] = newValue }
    }

    /// True when the sweep has something to do.
    public var sweeps: Bool { policies.values.contains { $0.mode == .deleteAfterDays } }
}
