import Foundation

/// Transcript export formats.
public enum TBDExportFormat: String, CaseIterable, Sendable {
    case txt, md, srt, vtt, json
    public var fileExtension: String { rawValue }
    public var title: String {
        switch self {
        case .txt: "Plain text"
        case .md: "Markdown"
        case .srt: "SubRip (SRT)"
        case .vtt: "WebVTT"
        case .json: "JSON"
        }
    }
}

public enum TBDExport {
    public static func render(_ item: TBDTranscription, as format: TBDExportFormat, summaries: [TBDSummary] = []) -> String {
        switch format {
        case .txt: text(item)
        case .md: markdown(item, summaries: summaries)
        case .srt: subtitles(item, vtt: false)
        case .vtt: subtitles(item, vtt: true)
        case .json: TBDListenJSON.encode(TBDListenJSON.Detail(item, summaries: summaries))
        }
    }

    static func displaySegments(_ item: TBDTranscription) -> [TBDSegment] {
        item.segments.isEmpty ? TBDTranscriptAssembler.segments(words: item.words, fallbackText: item.text, durationMs: item.durationMs) : item.segments
    }

    static func text(_ item: TBDTranscription) -> String {
        let segments = displaySegments(item)
        guard segments.contains(where: { $0.speaker != nil }) else { return item.text + "\n" }
        return segments.map { "\(item.speakerLabel($0.speaker) ?? "Unknown"): \($0.text)" }.joined(separator: "\n\n") + "\n"
    }

    static func markdown(_ item: TBDTranscription, summaries: [TBDSummary]) -> String {
        var out = "# \(item.title)\n\n"
        let date = ISO8601DateFormatter.string(from: item.createdAt, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate])
        out += "- Source: \(item.sourceKind.label)\(item.sourceURL.map { " (\($0))" } ?? "")\n- Date: \(date)\n- Duration: \(clock(item.durationMs))\n\n"
        for summary in summaries {
            out += summary.kind == .summary ? "## Summary\n\n\(summary.content)\n\n" : "## Q: \(summary.prompt)\n\n\(summary.content)\n\n"
        }
        if let notes = item.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out += "## Notes\n\n\(notes)\n\n"
        }
        out += "## Transcript\n\n"
        for segment in displaySegments(item) {
            let who = item.speakerLabel(segment.speaker).map { "**\($0)** " } ?? ""
            out += "\(who)`\(clock(segment.start))` \(segment.text)\n\n"
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
