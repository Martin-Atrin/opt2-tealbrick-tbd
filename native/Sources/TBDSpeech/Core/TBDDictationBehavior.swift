import CoreGraphics
import Foundation

// Pure logic for the v1 dictation behaviour settings (PARITY 2.2 / 3.2). No AppKit here, so every rule
// has an exact-value test. The controller and overlay in TBDListening only wire these to the screen.

/// Screen edge for the idle pill and the recording pill (v1 `DictationOverlayPlacement`).
public enum TBDOverlayPlacement: String, CaseIterable, Sendable {
    case bottom, top
    public var title: String { self == .bottom ? "Bottom" : "Top" }
    public var anchorsToTop: Bool { self == .top }
}

/// Where a dictation panel sits on a screen (v1 `DictationOverlayLayout`).
public enum TBDDictationOverlayLayout {
    public static let margin: CGFloat = 12

    /// The region a panel may use. `visibleFrame` clears the Dock and a shown menu bar, but it reaches the
    /// top edge when the menu bar auto-hides or an app is full screen; the top then reserves `topInset`.
    public static func usableFrame(screenFrame: CGRect, visibleFrame: CGRect, topInset: CGFloat) -> CGRect {
        let maxY = min(visibleFrame.maxY, screenFrame.maxY - topInset)
        return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width,
                      height: max(0, maxY - visibleFrame.minY))
    }

    /// Bottom-left origin of a panel of `panelSize`, centred on the chosen edge of `usable`.
    public static func origin(in usable: CGRect, panelSize: CGSize, placement: TBDOverlayPlacement,
                              margin: CGFloat = margin) -> CGPoint {
        let x = usable.midX - panelSize.width / 2
        switch placement {
        case .bottom: return CGPoint(x: x, y: usable.minY + margin)
        case .top: return CGPoint(x: x, y: max(usable.minY, usable.maxY - panelSize.height - margin))
        }
    }
}

/// Text size of the live preview above the pill (v1 `DictationPreviewTextSize`, metrics from its overlay view).
public enum TBDPreviewTextSize: String, CaseIterable, Sendable {
    case small, medium, large
    public var title: String { rawValue.capitalized }
    public var fontSize: CGFloat { switch self { case .small: 13; case .medium: 16; case .large: 19 } }
    public var lineSpacing: CGFloat { switch self { case .small: 1; case .medium: 2; case .large: 3 } }
    /// Height of the rolling readout, about three lines.
    public var visibleHeight: CGFloat { switch self { case .small: 50; case .medium: 62; case .large: 76 } }
}

/// How the finished text starts and ends when it is inserted (v1 `DictationInsertionStyle`).
public enum TBDInsertionStyle: String, CaseIterable, Sendable {
    case sentence, inline

    public var title: String { self == .sentence ? "Sentence" : "Inline" }
    public var detail: String {
        self == .sentence ? "Starts like a sentence and keeps ending punctuation." : "Fits replacements, fields, search, and commands."
    }
    public var previewText: String { self == .sentence ? "Hello world." : "hello world" }

    /// Applies the style to finished text. `protectedLeadingTerms` are vocabulary and snippet results whose
    /// capital letter is deliberate ("Teal Brick"), so inline never lowercases them.
    public func apply(to text: String, protectedLeadingTerms: [String] = []) -> String {
        switch self {
        case .sentence:
            guard let first = text.first, first.isLowercase else { return text }
            return first.uppercased() + text.dropFirst()
        case .inline:
            let stripped = Self.removeTerminalPunctuation(text)
            return Self.lowercaseLeading(stripped, protectedLeadingTerms: protectedLeadingTerms)
        }
    }

    /// What is typed or pasted. Sentence style adds a trailing space so the next dictation does not glue on;
    /// inline does not (it is for fields). A voice-return action replaces the space.
    public func insertionText(_ transcript: String, hasAction: Bool) -> String {
        (self == .sentence && !hasAction) ? transcript + " " : transcript
    }

    /// Terms whose first letter must survive inline lowercasing: enabled vocabulary targets and expanded snippets.
    public static func protectedLeadingTerms(customWords: [TBDCustomWord], snippets: [TBDSnippet], expandedSnippetIDs: Set<String>) -> [String] {
        customWords.filter(\.isEnabled).map { $0.replacement?.nilIfEmpty ?? $0.word }
            + snippets.filter { $0.isEnabled && expandedSnippetIDs.contains($0.id) }.map(\.expansion)
    }

    private static let terminal: Set<Character> = [".", "!", "?"]

    private static func removeTerminalPunctuation(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, terminal.contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func lowercaseLeading(_ text: String, protectedLeadingTerms: [String]) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        for raw in protectedLeadingTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, text.hasPrefix(term) else { continue }
            let end = text.index(text.startIndex, offsetBy: term.count)
            if end == text.endIndex || text[end].isWhitespace || (!text[end].isLetter && !text[end].isNumber) { return text }
        }
        // "I", "iPhone"-style and acronym first words keep their capitals.
        let token = text.prefix { !$0.isWhitespace }
        if token.first == "I" {
            guard let second = token.dropFirst().first else { return text }
            if !second.isLowercase { return text }
        }
        if token.dropFirst().contains(where: \.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Spoken trigger at the end of a dictation that presses Return after the paste (v1 `VoiceReturnTriggerPhrases`
/// and the trailing-action step of its text pipeline).
public enum TBDVoiceReturn {
    public static let defaultTrigger = "press return"

    /// Trims, drops empty and case-insensitive duplicate phrases, keeps order.
    public static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for phrase in raw {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func normalizedOrDefault(_ raw: [String]) -> [String] {
        let result = normalized(raw)
        return result.isEmpty ? [defaultTrigger] : result
    }

    /// Removes one trigger phrase from the very end of `text` (longest phrase first; punctuation after it and
    /// extra spaces are tolerated; the phrase must stand alone, not end a longer word). A phrase in the middle
    /// of the text is plain text and stays.
    public static func extract(from text: String, triggers: [String]) -> (text: String, trigger: String?) {
        for trigger in normalized(triggers).sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: trigger).replacingOccurrences(of: " ", with: "\\s+")
            guard let regex = try? NSRegularExpression(pattern: "(?<!\\S)\(escaped)\\p{P}*\\s*$", options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let cleaned = (text as NSString).replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned, trigger)
        }
        return (text, nil)
    }
}

/// Stops a dictation after the input has been quiet for `delay` seconds (v1 `runRecordingLevelLoop`).
public struct TBDSilenceAutoStop: Sendable, Equatable {
    /// Level (0...1) at or above which the input counts as speech.
    public static let threshold: Float = 0.03
    public static let delays: [Double] = [1, 1.5, 2, 3, 5]
    public static let defaultDelay: Double = 2

    public var delay: TimeInterval
    private var lastSound: TimeInterval
    private var fired = false

    /// `start` is the clock reading when recording began; the quiet period counts from there.
    public init(delay: TimeInterval, start: TimeInterval) {
        self.delay = delay
        lastSound = start
    }

    /// Feeds one level reading. Returns true once, when the quiet period reaches the delay.
    public mutating func feed(level: Float, at now: TimeInterval) -> Bool {
        if level >= Self.threshold { lastSound = now; return false }
        guard !fired, now - lastSound >= delay else { return false }
        fired = true
        return true
    }
}

/// Which text is typed one character group at a time with a fast caret instead of pasted (v1 `StreamingCursorPolicy`).
public enum TBDStreamingCursor {
    /// `CGEventKeyboardSetUnicodeString` truncates around this many UTF-16 units.
    public static let maxUTF16PerEvent = 20

    /// Single-line text whose every character fits one event. Multi-line text pastes.
    public static func isStreamable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) { return false }
        return !text.contains { String($0).utf16.count > maxUTF16PerEvent }
    }

    /// Typing Unicode events as a character key fails for non-ASCII keyboard layouts and IMEs; unknown fails closed.
    public static func inputSourceAllowsStreaming(asciiCapable: Bool?) -> Bool { asciiCapable ?? false }

    /// The text cut into events of at most `maxUTF16PerEvent` UTF-16 units, never splitting a character.
    public static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let n = String(character).utf16.count
            if !current.isEmpty, units + n > maxUTF16PerEvent {
                result.append(current); current = ""; units = 0
            }
            current.append(character); units += n
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// The last second of microphone input, kept while Instant dictation is on, so the first words are not lost
/// (v1 `DictationPreRollRingBuffer`; 0.45 s is prepended to a new recording).
public struct TBDPreRollBuffer: Sendable, Equatable {
    public static let capacitySamples = 16_000
    public static let prependSamples = 7_200   // 0.45 s at 16 kHz

    private var samples: [Float] = []
    public init() {}

    public var count: Int { samples.count }

    public mutating func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        if samples.count > Self.capacitySamples { samples.removeFirst(samples.count - Self.capacitySamples) }
    }

    /// The newest `count` samples (fewer when less is held).
    public func latest(_ count: Int = prependSamples) -> [Float] { Array(samples.suffix(count)) }

    public mutating func clear() { samples.removeAll(keepingCapacity: true) }
}

/// A dictation the person cancelled or let expire, kept in History when "Preserve discarded dictations" is on
/// (v1: the same row as a finished dictation, status `cancelled`, nothing pasted).
public enum TBDDiscardedDictation {
    /// Whether a discarded take is kept: the switch is on and history is saved (v1 requires both).
    public static func shouldKeep(preserve: Bool, keepHistory: Bool) -> Bool { preserve && keepHistory }

    public static func record(id: String = tbdNewID(), durationMs: Int, rawText: String, cleanText: String?, engine: String?,
                              audioPath: String?, targetApp: String?) -> TBDDictation {
        var row = TBDDictation(id: id, durationMs: durationMs, rawText: rawText, cleanText: cleanText, targetApp: targetApp,
                               audioPath: audioPath, engine: engine)
        row.status = .cancelled
        return row
    }
}
