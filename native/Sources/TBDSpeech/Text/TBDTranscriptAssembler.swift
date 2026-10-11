import Foundation

/// Builds display segments from timed words and attributes speakers.
public enum TBDTranscriptAssembler {
    /// Splits on speaker change, sentence end after a few words, pauses over 1.2 s, or 40 words.
    public static func segments(words: [TBDWord], fallbackText: String = "", durationMs: Int = 0) -> [TBDSegment] {
        guard !words.isEmpty else {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TBDSegment(start: 0, end: durationMs, text: text)]
        }
        var segments: [TBDSegment] = []
        var current: [TBDWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TBDSegment(start: first.start, end: last.end, text: join(current), speaker: first.speaker))
            current = []
        }
        for word in words {
            if let previous = current.last {
                let speakerChanged = word.speaker != previous.speaker
                let pause = word.start - previous.end > 1_200
                let sentenceEnd = previous.text.last.map { ".?!".contains($0) } == true && current.count >= 4
                if speakerChanged || pause || sentenceEnd || current.count >= 40 { flush() }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Joins words with spaces, without a space before punctuation tokens.
    static func join(_ words: [TBDWord]) -> String {
        var text = ""
        for word in words {
            if !text.isEmpty, let first = word.text.first, !",.?!;:%)".contains(first) { text += " " }
            text += word.text
        }
        return text
    }

    /// Labels each word with the speaker whose turn overlaps it most (nearest turn when none overlap).
    public static func attribute(_ words: [TBDWord], turns: [TBDSpeakerTurn]) -> [TBDWord] {
        guard !turns.isEmpty else { return words }
        return words.map { word in
            var best: (speaker: String, score: Int)?
            for turn in turns {
                let overlap = min(word.end, turn.end) - max(word.start, turn.start)
                let score = overlap > 0 ? overlap : -min(abs(word.start - turn.end), abs(turn.start - word.end))
                if best == nil || score > best!.score { best = (turn.speaker, score) }
            }
            var labelled = word
            labelled.speaker = best?.speaker
            return labelled
        }
    }

    /// Speakers in order of first appearance with "Speaker n" labels.
    public static func speakers(in words: [TBDWord], fixed: [TBDSpeaker] = []) -> [TBDSpeaker] {
        var seen: [TBDSpeaker] = []
        for id in words.compactMap(\.speaker) where !seen.contains(where: { $0.id == id }) {
            seen.append(fixed.first { $0.id == id } ?? TBDSpeaker(id: id, label: "Speaker \(id.dropFirst())"))
        }
        return seen
    }
}
