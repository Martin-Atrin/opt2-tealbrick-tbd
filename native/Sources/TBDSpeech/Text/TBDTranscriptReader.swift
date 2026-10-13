import Foundation

// Pure rules for reading a stored transcript (PARITY 2.2 / 3.2, v1 TranscriptResultView, TranscriptFindModel,
// MediaPlayerViewModel). No AppKit and no AVFoundation here, so every rule has an exact-value test. The views and
// the player in TBDListening only wire these to the screen.

/// Playback speeds of the audio player (v1 `PlaybackRate`).
public enum TBDPlaybackRate {
    public static let defaultValue: Float = 1.0
    public static let minimumValue: Float = 0.5
    public static let maximumValue: Float = 2.0
    public static let options: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    /// UserDefaults key (v1 `MediaPlayerViewModel.playbackRate`).
    public static let defaultsKey = "tbd.listening.playbackRate"

    /// A finite rate clamped to the supported range; anything else gives the default.
    public static func normalized(_ rate: Float) -> Float {
        guard rate.isFinite else { return defaultValue }
        return min(max(rate, minimumValue), maximumValue)
    }

    /// "1x", "1.5x", "1.25x".
    public static func label(for rate: Float) -> String {
        let hundredths = Int((Double(rate) * 100).rounded())
        if hundredths % 100 == 0 { return "\(hundredths / 100)x" }
        if hundredths % 10 == 0 { return String(format: "%.1fx", Double(hundredths) / 100) }
        return String(format: "%.2fx", Double(hundredths) / 100)
    }
}

/// Reading size of the transcript (v1 `transcriptFontScale`: A- / A+ buttons, no keyboard shortcuts).
public enum TBDTranscriptFontScale {
    public static let defaultValue: Double = 1.0
    public static let range: ClosedRange<Double> = 0.85...1.4
    public static let step: Double = 0.1
    /// Point size at scale 1. v1 reads at 15 pt in its own type scale; 13 pt is the opt2 body size, so 1.0 looks as before.
    public static let basePointSize: Double = 13
    /// UserDefaults key (v1 `transcriptFontScale`).
    public static let defaultsKey = "tbd.listening.transcriptFontScale"

    /// A stored value clamped to the range, so a stale or hand-written value never renders out of range.
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The scale after one A- (`-step`) or A+ (`+step`) press.
    public static func adjusted(_ value: Double, by delta: Double) -> Double { clamped(clamped(value) + delta) }

    public static func canDecrease(_ value: Double) -> Bool { clamped(value) > range.lowerBound + 0.001 }
    public static func canIncrease(_ value: Double) -> Bool { clamped(value) < range.upperBound - 0.001 }
    public static func pointSize(_ value: Double) -> Double { basePointSize * clamped(value) }
}

/// Find in transcript (v1 `TranscriptFindModel`). A value type: the view keeps it in state.
/// Matches are case- and diacritic-insensitive ("cafe" finds "Café"), are searched with the untrimmed query
/// (" the " does not match "there"), and a whitespace-only query matches nothing. Ranges are UTF-16 `NSRange`s
/// relative to the owning block's text.
public struct TBDTranscriptFind: Equatable, Sendable {
    public struct Match: Equatable, Sendable {
        public let blockIndex: Int
        public let range: NSRange
        public init(blockIndex: Int, range: NSRange) { self.blockIndex = blockIndex; self.range = range }
    }

    public private(set) var query = ""
    public private(set) var matches: [Match] = []
    public private(set) var currentMatchIndex: Int?
    private var blocks: [String] = []

    public init() {}

    /// Sets the query and recomputes; the cursor goes to the first match.
    public mutating func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        recompute()
    }

    /// Replaces the searched blocks and re-runs the query. Keeps the current match when it still exists,
    /// otherwise keeps the same position in the list (clamped).
    public mutating func setBlocks(_ newBlocks: [String]) {
        let previous = current
        let previousIndex = currentMatchIndex
        blocks = newBlocks
        recompute(preserving: previous, preferredIndex: previousIndex)
    }

    public mutating func clear() { setQuery("") }

    /// Next match, wrapping at the end.
    public mutating func next() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = ((currentMatchIndex ?? -1) + 1) % matches.count
    }

    /// Previous match, wrapping at the start.
    public mutating func prev() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = ((currentMatchIndex ?? 0) - 1 + matches.count) % matches.count
    }

    public var hasMatches: Bool { !matches.isEmpty }
    public var current: Match? {
        guard let index = currentMatchIndex, matches.indices.contains(index) else { return nil }
        return matches[index]
    }
    /// 1-based "current of total" for the counter; nil without matches.
    public var displayPosition: (current: Int, total: Int)? {
        guard let index = currentMatchIndex, matches.indices.contains(index) else { return nil }
        return (index + 1, matches.count)
    }
    /// A query was typed and nothing matched.
    public var hasQueryButNoMatches: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && matches.isEmpty }

    public func ranges(inBlock block: Int) -> [NSRange] { matches.filter { $0.blockIndex == block }.map(\.range) }
    public func currentRange(inBlock block: Int) -> NSRange? {
        guard let current, current.blockIndex == block else { return nil }
        return current.range
    }

    private mutating func recompute(preserving previous: Match? = nil, preferredIndex: Int? = nil) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matches = []
            currentMatchIndex = nil
            return
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var found: [Match] = []
        for (blockIndex, text) in blocks.enumerated() where !text.isEmpty {
            var start = text.startIndex
            while start < text.endIndex, let hit = text.range(of: query, options: options, range: start..<text.endIndex) {
                found.append(Match(blockIndex: blockIndex, range: NSRange(hit, in: text)))
                start = hit.upperBound > hit.lowerBound ? hit.upperBound : text.index(after: hit.lowerBound)
            }
        }
        matches = found
        guard !found.isEmpty else { currentMatchIndex = nil; return }
        if let previous, let kept = found.firstIndex(of: previous) {
            currentMatchIndex = kept
        } else if let preferredIndex {
            currentMatchIndex = min(max(preferredIndex, 0), found.count - 1)
        } else {
            currentMatchIndex = 0
        }
    }
}

/// How the transcript is shown: flowing text, or segments with timestamps and speakers (v1 `TranscriptDisplayMode`).
/// v1 opens every transcript in Text and does not remember the choice.
public enum TBDTranscriptViewMode: String, CaseIterable, Sendable {
    case text = "Text", timed = "Timed"
    public static let initial: TBDTranscriptViewMode = .text
}

public enum TBDTranscriptReader {
    /// Playback follows the transcript again this long after a manual scroll (v1).
    public static let followPauseSeconds: Double = 5
    /// A playback time jump larger than this (a seek) re-syncs the transcript at once (v1).
    public static let seekJumpMs = 2000

    /// The Text mode body: the stored text with the person's edits applied. A transcript that has segments but
    /// no flowing text shows its segments as paragraphs.
    public static func bodyText(_ item: TBDTranscription) -> String {
        let text = item.text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return item.segments.map(\.text).joined(separator: "\n\n")
    }

    /// Timed mode is offered when the transcript has timed segments (v1: when word timestamps exist).
    public static func hasTimedView(_ item: TBDTranscription) -> Bool { !item.segments.isEmpty || !item.words.isEmpty }

    /// The blocks the find bar searches: the segment texts in Timed mode, the whole text in Text mode.
    public static func findBlocks(mode: TBDTranscriptViewMode, segments: [TBDSegment], body: String) -> [String] {
        mode == .timed ? segments.map(\.text) : [body]
    }

    /// Index of the segment playing at `ms`: the last one that starts at or before it (segments sorted by start).
    public static func segmentIndex(starts: [Int], atMs ms: Int) -> Int? {
        var low = 0, high = starts.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= ms { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// The segment to highlight while audio is loaded: none at the very start (time 0), as in v1.
    public static func highlightIndex(starts: [Int], atMs ms: Int, hasAudio: Bool) -> Int? {
        guard hasAudio, ms > 0 else { return nil }
        return segmentIndex(starts: starts, atMs: ms)
    }

    /// Whether a change of playback time is a seek that must re-sync the transcript view.
    public static func isSeekJump(from old: Int, to new: Int) -> Bool { abs(new - old) > seekJumpMs }

    /// The kept audio files that still exist, in stored order (a meeting has a microphone and a system track).
    public static func playableAudio(_ paths: [String], exists: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return paths.filter { exists($0) && seen.insert($0).inserted }
    }

    /// The text before a match in a UTF-16 offset, used as the scroll anchor in Text mode.
    public static func prefix(of text: String, utf16Offset: Int) -> String? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count,
              let index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset, limitedBy: text.utf16.endIndex),
              let stringIndex = index.samePosition(in: text) else { return nil }
        return String(text[..<stringIndex])
    }

    /// Clipboard text of one passage: "[12:03] Hello", or the trimmed text when the label is empty (v1).
    public static func clipboardText(timestamp: String, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return trimmed }
        guard !trimmed.isEmpty else { return "[\(label)]" }
        return "[\(label)] \(trimmed)"
    }
}

extension TBDListeningPreferences {
    /// Transcript reading size; the v1 default 1.0 when the key is absent. Always within the supported range.
    public var transcriptFontScale: Double {
        get {
            defaults.object(forKey: TBDTranscriptFontScale.defaultsKey) == nil
                ? TBDTranscriptFontScale.defaultValue
                : TBDTranscriptFontScale.clamped(defaults.double(forKey: TBDTranscriptFontScale.defaultsKey))
        }
        nonmutating set { defaults.set(TBDTranscriptFontScale.clamped(newValue), forKey: TBDTranscriptFontScale.defaultsKey) }
    }

    /// Audio player speed; the v1 default 1x when the key is absent.
    public var playbackRate: Float {
        get {
            (defaults.object(forKey: TBDPlaybackRate.defaultsKey) as? NSNumber).map { TBDPlaybackRate.normalized($0.floatValue) }
                ?? TBDPlaybackRate.defaultValue
        }
        nonmutating set { defaults.set(Double(TBDPlaybackRate.normalized(newValue)), forKey: TBDPlaybackRate.defaultsKey) }
    }
}
