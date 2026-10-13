import Foundation

// The export rules of the v1 library: which options a format takes, which of them a transcript can
// honour, how the files are named, and the settings the bulk export remembers. Pure, so every rule has
// an exact-value test. The single export (transcript header) and the bulk export (Library) share them.

extension TBDExportFormat {
    /// Order of the format picker (v1 `TranscriptExportFormat` picker order).
    public static let pickerOrder: [TBDExportFormat] = [.txt, .md, .srt, .vtt, .dapt, .json, .pdf, .docx]

    /// Short name on the picker buttons and in messages (v1 `shortName`).
    public var shortName: String {
        switch self {
        case .txt: "Text"
        case .md: "Markdown"
        case .srt: "SRT"
        case .vtt: "VTT"
        case .dapt: "DAPT"
        case .docx: "DOCX"
        case .pdf: "PDF"
        case .json: "JSON"
        }
    }

    /// Only plain text and Markdown take the three options. The other formats have fixed layouts, so the
    /// export UI hides the options for them (v1 `supportsTranscriptOptions`).
    public var supportsOptions: Bool { self == .txt || self == .md }
}

extension TBDTranscription {
    /// The transcript has word or passage timing to put in front of each passage.
    public var canExportTimestamps: Bool { !words.isEmpty || !segments.isEmpty }

    /// The transcript has speakers, so a label can start each speaker's passages.
    public var canExportSpeakerLabels: Bool { !speakers.isEmpty }
}

extension TBDExportOptions {
    /// A copy with unavailable options forced off, so a file never claims timing or speakers the transcript
    /// lacks. The checkboxes and the written file both go through this one rule (v1 `resolved`). Metadata
    /// has no data dependency and is never forced off.
    public func resolved(canIncludeTimestamps: Bool, canIncludeSpeakerLabels: Bool) -> TBDExportOptions {
        var copy = self
        if !canIncludeTimestamps { copy.includeTimestamps = false }
        if !canIncludeSpeakerLabels { copy.includeSpeakerLabels = false }
        return copy
    }

    /// The options a file of `format` is written with: formats without options get the defaults.
    public func resolved(for item: TBDTranscription, format: TBDExportFormat) -> TBDExportOptions {
        guard format.supportsOptions else { return .default }
        return resolved(canIncludeTimestamps: item.canExportTimestamps, canIncludeSpeakerLabels: item.canExportSpeakerLabels)
    }
}

extension TBDExport {
    /// File contents for the library export (single and bulk). Same as `data` with the options resolved for
    /// this transcript, except plain text, which follows the v1 layout so all three options show: a header,
    /// a speaker line where the speaker changes, and an `[M:SS]` stamp per passage.
    /// Copy, Knowledge and auto-save keep the clean `text` layout.
    public static func libraryData(_ item: TBDTranscription, as format: TBDExportFormat, summaries: [TBDSummary] = [],
                                   options: TBDExportOptions = .default) -> Data {
        let resolved = options.resolved(for: item, format: format)
        if format == .txt { return Data(detailedText(item, options: resolved).utf8) }
        return data(item, as: format, summaries: summaries, options: resolved)
    }

    /// v1 plain-text layout (see `libraryData`). Callers pass resolved options.
    public static func detailedText(_ item: TBDTranscription, options: TBDExportOptions) -> String {
        var lines: [String] = []
        if options.includeMetadata {
            lines.append(item.title)
            if item.durationMs > 0 { lines.append("Duration: \(clock(item.durationMs))") }
            lines.append("")
        }
        let segments = displaySegments(item)
        if (options.includeTimestamps || options.includeSpeakerLabels) && !segments.isEmpty {
            var previous: String?
            for (index, segment) in segments.enumerated() {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                if options.includeSpeakerLabels, let label = speakerLine(item, segment.speaker), index == 0 || segment.speaker != previous {
                    lines.append("\(label):")
                }
                previous = segment.speaker
                lines.append(options.includeTimestamps ? "[\(clock(segment.start))] \(segment.text)" : segment.text)
            }
        } else if !item.text.isEmpty {
            lines.append(item.text)
        } else {
            for segment in segments {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines.append(segment.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The speaker line of a passage: the name, "Unassigned" for a passage without speaker when the
    /// transcript has speakers, nil when it has none (v1 `paragraphSpeakerLabel`).
    private static func speakerLine(_ item: TBDTranscription, _ speaker: String?) -> String? {
        guard !item.speakers.isEmpty else { return nil }
        return speaker == nil ? "Unassigned" : item.speakerLabel(speaker)
    }
}

/// File names of exported transcripts (v1 `TranscriptResultActions.nextAvailableURL`).
public enum TBDExportFiles {
    /// The title with path separators, colons and NUL made spaces; an empty result is "transcript".
    public static func stem(_ item: TBDTranscription) -> String { TBDAutoSaver.sanitizedStem(item.title) }

    /// `Stem.ext`; when taken, `Stem (1).ext`, `Stem (2).ext` and so on. Never overwrites.
    public static func nextAvailableURL(in directory: URL, stem: String, format: TBDExportFormat,
                                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var url = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
        var counter = 1
        while exists(url) {
            url = directory.appendingPathComponent("\(stem) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        return url
    }
}

/// What the Library's bulk export remembers (v1 `libraryBulkExportFormat` and the three
/// `libraryBulkExportInclude…` switches). Defaults: Text, everything on. The single export keeps no state.
public struct TBDLibraryExportSettings: @unchecked Sendable {
    let defaults: UserDefaults

    static let formatKey = "tbd.listening.libraryBulkExportFormat"
    static let timestampsKey = "tbd.listening.libraryBulkExportIncludeTimestamps"
    static let speakerLabelsKey = "tbd.listening.libraryBulkExportIncludeSpeakerLabels"
    static let metadataKey = "tbd.listening.libraryBulkExportIncludeMetadata"

    public var format: TBDExportFormat {
        get { defaults.string(forKey: Self.formatKey).flatMap(TBDExportFormat.init(rawValue:)) ?? .txt }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.formatKey) }
    }

    public var options: TBDExportOptions {
        get {
            func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
            return TBDExportOptions(includeTimestamps: flag(Self.timestampsKey), includeSpeakerLabels: flag(Self.speakerLabelsKey),
                                    includeMetadata: flag(Self.metadataKey))
        }
        nonmutating set {
            defaults.set(newValue.includeTimestamps, forKey: Self.timestampsKey)
            defaults.set(newValue.includeSpeakerLabels, forKey: Self.speakerLabelsKey)
            defaults.set(newValue.includeMetadata, forKey: Self.metadataKey)
        }
    }
}

extension TBDListeningPreferences {
    public var libraryExport: TBDLibraryExportSettings { TBDLibraryExportSettings(defaults: defaults) }
}
