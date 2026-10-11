import Foundation

/// Execution lane. Dictation gets its own lane so a long file never blocks push-to-talk.
public enum TBDLane: Hashable, Sendable { case interactive, background }

/// A loaded speech-to-text engine.
public protocol TBDSpeechEngine: AnyObject, Sendable {
    var choice: TBDEngineChoice { get }
    /// Loads the model from disk. Never downloads: throws `modelNotDownloaded` instead.
    func prepare() async throws
    func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript
    func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript
    func unload() async
}

enum TBDWordTiming {
    /// Joins SentencePiece tokens ("▁hel", "lo") into words with averaged confidence.
    static func words(tokens: [(token: String, start: Double, end: Double, confidence: Float)]) -> [TBDWord] {
        var words: [TBDWord] = []
        var text = "", start = 0.0, end = 0.0
        var confidences: [Float] = []
        func flush() {
            guard !text.isEmpty else { return }
            let confidence = confidences.isEmpty ? 0 : Double(confidences.reduce(0, +) / Float(confidences.count))
            words.append(TBDWord(text: text, start: Int((start * 1000).rounded()), end: Int((end * 1000).rounded()), confidence: confidence))
            text = ""; confidences = []
        }
        for token in tokens {
            let normalized = token.token.replacingOccurrences(of: "▁", with: " ")
            let startsWord = normalized.first?.isWhitespace == true
            let piece = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { if startsWord { flush() }; continue }
            if startsWord || text.isEmpty {
                flush(); text = piece; start = token.start
            } else {
                text += piece
            }
            end = token.end
            confidences.append(token.confidence)
        }
        flush()
        return words
    }
}
