import Foundation

/// Transcript export formats.
public enum TBDExportFormat: String, CaseIterable, Sendable {
    case txt, md, srt, vtt, json, docx, pdf, dapt
    public var fileExtension: String { self == .dapt ? "dapt.xml" : rawValue }
    public var title: String {
        switch self {
        case .txt: "Plain text"
        case .md: "Markdown"
        case .srt: "SubRip (SRT)"
        case .vtt: "WebVTT"
        case .json: "JSON"
        case .docx: "Word document"
        case .pdf: "PDF"
        case .dapt: "DAPT transcript"
        }
    }
    /// DOCX and PDF are binary: use `TBDExport.data`.
    public var isBinary: Bool { self == .docx || self == .pdf }
}

/// What the text and Markdown exports include (the v1 meeting auto-save checkboxes). Everything on by default.
/// Plain text has no timestamps in TBD, so `includeTimestamps` only affects Markdown.
public struct TBDExportOptions: Sendable, Equatable {
    public var includeTimestamps = true
    public var includeSpeakerLabels = true
    public var includeMetadata = true
    public init(includeTimestamps: Bool = true, includeSpeakerLabels: Bool = true, includeMetadata: Bool = true) {
        self.includeTimestamps = includeTimestamps; self.includeSpeakerLabels = includeSpeakerLabels; self.includeMetadata = includeMetadata
    }
    public static let `default` = TBDExportOptions()
}

public enum TBDExport {
    public static func render(_ item: TBDTranscription, as format: TBDExportFormat, summaries: [TBDSummary] = [],
                              options: TBDExportOptions = .default) -> String {
        switch format {
        case .txt: text(item, options: options)
        case .md: markdown(item, summaries: summaries, options: options)
        case .srt: subtitles(item, vtt: false)
        case .vtt: subtitles(item, vtt: true)
        case .json: TBDListenJSON.encode(TBDListenJSON.Detail(item, summaries: summaries))
        case .dapt: TBDDAPTExport.render(item)
        case .docx, .pdf: text(item)   // Binary formats: see `data(_:as:summaries:)`.
        }
    }

    /// File contents for any format.
    public static func data(_ item: TBDTranscription, as format: TBDExportFormat, summaries: [TBDSummary] = [],
                            options: TBDExportOptions = .default) -> Data {
        switch format {
        case .docx: TBDDocxExport.render(TBDDocumentModel(item, summaries: summaries))
        case .pdf: TBDPDFExport.render(TBDDocumentModel(item, summaries: summaries))
        default: Data(render(item, as: format, summaries: summaries, options: options).utf8)
        }
    }

    static func displaySegments(_ item: TBDTranscription) -> [TBDSegment] {
        item.segments.isEmpty ? TBDTranscriptAssembler.segments(words: item.words, fallbackText: item.text, durationMs: item.durationMs) : item.segments
    }

    static func text(_ item: TBDTranscription, options: TBDExportOptions = .default) -> String {
        let segments = displaySegments(item)
        guard options.includeSpeakerLabels, segments.contains(where: { $0.speaker != nil }) else {
            return (options.includeSpeakerLabels ? item.text : segments.map(\.text).joined(separator: "\n\n")) + "\n"
        }
        return segments.map { "\(item.speakerLabel($0.speaker) ?? "Unknown"): \($0.text)" }.joined(separator: "\n\n") + "\n"
    }

    static func markdown(_ item: TBDTranscription, summaries: [TBDSummary], options: TBDExportOptions = .default) -> String {
        var out = "# \(item.title)\n\n"
        let date = ISO8601DateFormatter.string(from: item.createdAt, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate])
        if options.includeMetadata {
            out += "- Source: \(item.sourceKind.label)\(item.sourceURL.map { " (\($0))" } ?? "")\n- Date: \(date)\n- Duration: \(clock(item.durationMs))\n\n"
        }
        for summary in summaries {
            out += summary.kind == .summary ? "## Summary\n\n\(summary.content)\n\n" : "## Q: \(summary.prompt)\n\n\(summary.content)\n\n"
        }
        if let notes = item.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out += "## Notes\n\n\(notes)\n\n"
        }
        out += "## Transcript\n\n"
        for segment in displaySegments(item) {
            let who = options.includeSpeakerLabels ? item.speakerLabel(segment.speaker).map { "**\($0)** " } ?? "" : ""
            let stamp = options.includeTimestamps ? "`\(clock(segment.start))` " : ""
            out += "\(who)\(stamp)\(segment.text)\n\n"
        }
        return out
    }

    static func subtitles(_ item: TBDTranscription, vtt: Bool) -> String {
        var out = vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues(item).enumerated() {
            if !vtt { out += "\(index + 1)\n" }
            out += "\(timestamp(cue.start, vtt: vtt)) --> \(timestamp(cue.end, vtt: vtt))\n"
            let who = item.speakerLabel(cue.speaker)
            out += vtt ? (who.map { "<v \($0)>" } ?? "") + cue.text : (who.map { "\($0): " } ?? "") + cue.text
            out += "\n\n"
        }
        return out
    }

    /// Subtitle cues of at most ~7 s / 84 characters, with positive duration.
    static func cues(_ item: TBDTranscription) -> [TBDSegment] {
        var cues: [TBDSegment] = []
        for segment in displaySegments(item) {
            let words = item.words.filter { $0.start >= segment.start && $0.end <= segment.end && $0.speaker == segment.speaker }
            if words.isEmpty || (segment.end - segment.start <= 7_000 && segment.text.count <= 84) {
                cues.append(segment)
                continue
            }
            var chunk: [TBDWord] = []
            for word in words {
                if let first = chunk.first, word.end - first.start > 7_000 || TBDTranscriptAssembler.join(chunk + [word]).count > 84 {
                    cues.append(TBDSegment(start: first.start, end: chunk.last!.end, text: TBDTranscriptAssembler.join(chunk), speaker: segment.speaker))
                    chunk = []
                }
                chunk.append(word)
            }
            if let first = chunk.first {
                cues.append(TBDSegment(start: first.start, end: chunk.last!.end, text: TBDTranscriptAssembler.join(chunk), speaker: segment.speaker))
            }
        }
        return cues.map { cue in
            var fixed = cue
            if fixed.end <= fixed.start { fixed.end = fixed.start + 500 }
            return fixed
        }
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (VTT).
    public static func timestamp(_ ms: Int, vtt: Bool) -> String {
        let value = max(0, ms)
        return String(format: "%02d:%02d:%02d%@%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, vtt ? "." : ",", value % 1000)
    }

    /// `M:SS` or `H:MM:SS`.
    public static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
